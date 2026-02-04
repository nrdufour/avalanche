# Declarative DNS static records management via nsupdate
#
# This module manages static DNS records using RFC2136 dynamic updates (nsupdate).
# It uses ownership TXT records (nix.<name>.<zone>) to track which records are
# managed by Nix, allowing safe coexistence with:
# - DHCP-DDNS (Kea) - no ownership markers
# - ExternalDNS (K8s) - uses k8s.* TXT markers
#
# Only records with matching nix.* ownership markers will be modified or deleted.
{ lib, config, pkgs, ... }:

with lib;

let
  cfg = config.mySystem.services.dnsStaticRecords;

  # Record type definitions
  aRecordType = types.submodule {
    options = {
      name = mkOption {
        type = types.str;
        description = "Hostname (without zone suffix)";
        example = "ns0";
      };
      ip = mkOption {
        type = types.str;
        description = "IPv4 address";
        example = "10.0.0.53";
      };
      ttl = mkOption {
        type = types.int;
        default = 300;
        description = "TTL in seconds";
      };
    };
  };

  cnameRecordType = types.submodule {
    options = {
      name = mkOption {
        type = types.str;
        description = "Alias name (without zone suffix)";
        example = "www";
      };
      target = mkOption {
        type = types.str;
        description = "Canonical name (FQDN with trailing dot)";
        example = "web.internal.";
      };
      ttl = mkOption {
        type = types.int;
        default = 300;
        description = "TTL in seconds";
      };
    };
  };

  nsRecordType = types.submodule {
    options = {
      zone = mkOption {
        type = types.str;
        default = "@";
        description = "Zone apex (@) or subdomain";
      };
      nameserver = mkOption {
        type = types.str;
        description = "Nameserver FQDN (with trailing dot)";
        example = "ns0.internal.";
      };
      ttl = mkOption {
        type = types.int;
        default = 300;
        description = "TTL in seconds";
      };
    };
  };

  ptrRecordType = types.submodule {
    options = {
      ip = mkOption {
        type = types.str;
        description = "IP address to create PTR for";
        example = "10.0.0.53";
      };
      hostname = mkOption {
        type = types.str;
        description = "Hostname FQDN (with trailing dot)";
        example = "ns0.internal.";
      };
      ttl = mkOption {
        type = types.int;
        default = 300;
        description = "TTL in seconds";
      };
    };
  };

  zoneConfigType = types.submodule {
    options = {
      aRecords = mkOption {
        type = types.listOf aRecordType;
        default = [ ];
        description = "A records for this zone";
      };
      cnameRecords = mkOption {
        type = types.listOf cnameRecordType;
        default = [ ];
        description = "CNAME records for this zone";
      };
      nsRecords = mkOption {
        type = types.listOf nsRecordType;
        default = [ ];
        description = "NS records for this zone";
      };
      ptrRecords = mkOption {
        type = types.listOf ptrRecordType;
        default = [ ];
        description = "PTR records for this zone";
      };
    };
  };

  # Convert IP to reverse DNS name
  # e.g., "10.0.0.53" -> "53.0.0" (for 10.in-addr.arpa zone)
  ipToReverse = ip:
    let
      parts = lib.splitString "." ip;
    in
    lib.concatStringsSep "." (lib.reverseList (lib.tail parts));

  # Count total records for a zone config
  countRecords = zoneConfig:
    (length zoneConfig.aRecords) +
    (length zoneConfig.cnameRecords) +
    (length zoneConfig.nsRecords) +
    (length zoneConfig.ptrRecords);

  # Generate the sync script for a zone
  mkSyncScript = zoneName: zoneConfig:
    let
      ownerTxt = "heritage=nix,managed-by=dns-static-records";

      # Helper to expand @ to zone apex
      expandName = name: if name == "@" then "${zoneName}." else "${name}.${zoneName}.";

      # Build list of desired records as shell array entries
      # Format: "ownerName recordType recordData"
      desiredRecords = lib.concatStringsSep "\n" (
        # A records
        (map
          (r: ''"${expandName r.name} A ${r.ip}"'')
          zoneConfig.aRecords) ++
        # CNAME records
        (map
          (r: ''"${expandName r.name} CNAME ${r.target}"'')
          zoneConfig.cnameRecords) ++
        # NS records
        (map
          (r:
            let
              name = if r.zone == "@" then "${zoneName}." else "${r.zone}.${zoneName}.";
            in
            ''"${name} NS ${r.nameserver}"'')
          zoneConfig.nsRecords) ++
        # PTR records
        (map
          (r: ''"${ipToReverse r.ip}.${zoneName}. PTR ${r.hostname}"'')
          zoneConfig.ptrRecords)
      );

      # Helper to build ownership TXT name (prepend nix. and handle @ as _apex)
      mkOwnerName = name: if name == "@" then "nix._apex.${zoneName}." else "nix.${name}.${zoneName}.";

      # Build list of ownership TXT record names
      desiredOwnerNames = lib.concatStringsSep "\n" (
        # A records
        (map
          (r: ''"${mkOwnerName r.name}"'')
          zoneConfig.aRecords) ++
        # CNAME records
        (map
          (r: ''"${mkOwnerName r.name}"'')
          zoneConfig.cnameRecords) ++
        # NS records (use special naming for zone apex)
        (map
          (r:
            let
              name = if r.zone == "@" then "nix._ns.${zoneName}." else "nix.${r.zone}._ns.${zoneName}.";
            in
            ''"${name}"'')
          zoneConfig.nsRecords) ++
        # PTR records
        (map
          (r: ''"nix.${ipToReverse r.ip}.${zoneName}."'')
          zoneConfig.ptrRecords)
      );

      dryRunFlag = if cfg.dryRun then "true" else "false";
      metricsEnabled = if cfg.metrics.enable then "true" else "false";
      metricsPath = cfg.metrics.path;
      desiredCount = toString (countRecords zoneConfig);
    in
    pkgs.writeShellScript "dns-sync-${zoneName}" ''
      set -euo pipefail

      DNS_SERVER="${cfg.dnsServer}"
      TSIG_KEY="${cfg.tsigKeyFile}"
      ZONE="${zoneName}"
      OWNER_TXT="${ownerTxt}"
      DRY_RUN="${dryRunFlag}"
      METRICS_ENABLED="${metricsEnabled}"
      METRICS_PATH="${metricsPath}"
      DESIRED_COUNT="${desiredCount}"

      # Desired records (format: "fqdn TYPE data")
      declare -a DESIRED_RECORDS=(
      ${desiredRecords}
      )

      # Desired ownership TXT record names
      declare -a DESIRED_OWNERS=(
      ${desiredOwnerNames}
      )

      echo "Syncing zone: $ZONE"
      echo "DNS Server: $DNS_SERVER"
      echo "Desired records: ''${#DESIRED_RECORDS[@]}"
      if [[ "$DRY_RUN" == "true" ]]; then
        echo "*** DRY RUN MODE - no changes will be applied ***"
      fi

      # Query current nix.* TXT records to find what we currently own
      echo "Querying existing nix.* ownership records..."
      CURRENT_OWNERS=$(${pkgs.dig}/bin/dig @"$DNS_SERVER" AXFR "$ZONE" +short 2>/dev/null | \
        ${pkgs.gnugrep}/bin/grep -E "^nix\." | \
        ${pkgs.gawk}/bin/awk '{print $1}' | \
        sort -u || true)

      # Build nsupdate commands
      NSUPDATE_FILE=$(mktemp)
      trap "rm -f $NSUPDATE_FILE" EXIT

      echo "server $DNS_SERVER" > "$NSUPDATE_FILE"
      echo "zone $ZONE" >> "$NSUPDATE_FILE"

      CHANGES=0
      ERRORS=0

      # Delete records that are no longer desired
      for owner in $CURRENT_OWNERS; do
        # Check if this owner is in our desired list
        found=0
        for desired in "''${DESIRED_OWNERS[@]}"; do
          if [[ "$owner" == "$desired" ]]; then
            found=1
            break
          fi
        done

        if [[ $found -eq 0 ]]; then
          echo "Will delete orphaned record with owner: $owner"
          # Extract the actual record name from owner (remove nix. prefix)
          record_name="''${owner#nix.}"

          # Handle special _ns. naming for NS records
          if [[ "$record_name" == *"._ns."* ]]; then
            # NS record - reconstruct the zone/subdomain name
            record_name="''${record_name/._ns./}"
          fi

          echo "update delete $record_name" >> "$NSUPDATE_FILE"
          echo "update delete $owner TXT" >> "$NSUPDATE_FILE"
          CHANGES=$((CHANGES + 1))
        fi
      done

      # Add/update desired records
      for i in "''${!DESIRED_RECORDS[@]}"; do
        record="''${DESIRED_RECORDS[$i]}"
        owner="''${DESIRED_OWNERS[$i]}"

        # Parse record components
        fqdn=$(echo "$record" | ${pkgs.gawk}/bin/awk '{print $1}')
        rtype=$(echo "$record" | ${pkgs.gawk}/bin/awk '{print $2}')
        rdata=$(echo "$record" | ${pkgs.gawk}/bin/awk '{$1=""; $2=""; print $0}' | sed 's/^ *//')

        # Check if record already exists with correct value
        existing=$(${pkgs.dig}/bin/dig @"$DNS_SERVER" "$fqdn" "$rtype" +short 2>/dev/null || true)

        if [[ "$existing" != "$rdata" ]]; then
          echo "Will update: $fqdn $rtype -> $rdata (was: $existing)"
          # Delete existing record first (if any), then add new
          echo "update delete $fqdn $rtype" >> "$NSUPDATE_FILE"
          echo "update add $fqdn 300 $rtype $rdata" >> "$NSUPDATE_FILE"
          CHANGES=$((CHANGES + 1))
        fi

        # Always ensure ownership TXT exists
        owner_exists=$(${pkgs.dig}/bin/dig @"$DNS_SERVER" "$owner" TXT +short 2>/dev/null || true)
        if [[ -z "$owner_exists" ]] || [[ "$owner_exists" != *"$OWNER_TXT"* ]]; then
          echo "Will add ownership marker: $owner"
          echo "update delete $owner TXT" >> "$NSUPDATE_FILE"
          echo "update add $owner 300 TXT \"$OWNER_TXT\"" >> "$NSUPDATE_FILE"
          CHANGES=$((CHANGES + 1))
        fi
      done

      SYNC_SUCCESS=1
      if [[ $CHANGES -gt 0 ]]; then
        echo "send" >> "$NSUPDATE_FILE"
        echo "" >> "$NSUPDATE_FILE"

        echo "Applying $CHANGES changes..."
        echo "--- nsupdate commands ---"
        cat "$NSUPDATE_FILE"
        echo "--- end ---"

        if [[ "$DRY_RUN" == "true" ]]; then
          echo "DRY RUN: Skipping nsupdate execution"
        else
          if ${pkgs.dig}/bin/nsupdate -k "$TSIG_KEY" "$NSUPDATE_FILE"; then
            echo "Zone $ZONE synced successfully"
          else
            echo "ERROR: nsupdate failed for zone $ZONE"
            SYNC_SUCCESS=0
            ERRORS=$((ERRORS + 1))
          fi
        fi
      else
        echo "No changes needed for zone $ZONE"
      fi

      # Write Prometheus metrics
      if [[ "$METRICS_ENABLED" == "true" ]]; then
        METRICS_DIR=$(dirname "$METRICS_PATH")
        mkdir -p "$METRICS_DIR"
        METRICS_TMP=$(mktemp -p "$METRICS_DIR")

        cat > "$METRICS_TMP" << METRICS_EOF
      # HELP dns_static_records_last_sync_timestamp Unix timestamp of last sync attempt
      # TYPE dns_static_records_last_sync_timestamp gauge
      dns_static_records_last_sync_timestamp{zone="$ZONE"} $(date +%s)
      # HELP dns_static_records_sync_success Whether the last sync was successful (1=success, 0=failure)
      # TYPE dns_static_records_sync_success gauge
      dns_static_records_sync_success{zone="$ZONE"} $SYNC_SUCCESS
      # HELP dns_static_records_managed_count Number of records managed by this module
      # TYPE dns_static_records_managed_count gauge
      dns_static_records_managed_count{zone="$ZONE"} $DESIRED_COUNT
      # HELP dns_static_records_changes_count Number of changes applied in last sync
      # TYPE dns_static_records_changes_count gauge
      dns_static_records_changes_count{zone="$ZONE"} $CHANGES
      # HELP dns_static_records_errors_total Total number of sync errors
      # TYPE dns_static_records_errors_total counter
      dns_static_records_errors_total{zone="$ZONE"} $ERRORS
      # HELP dns_static_records_dry_run Whether dry-run mode is enabled (1=enabled, 0=disabled)
      # TYPE dns_static_records_dry_run gauge
      dns_static_records_dry_run{zone="$ZONE"} $(if [[ "$DRY_RUN" == "true" ]]; then echo 1; else echo 0; fi)
      METRICS_EOF

        # Atomic move
        mv "$METRICS_TMP" "$METRICS_PATH.$ZONE.prom"
        echo "Metrics written to $METRICS_PATH.$ZONE.prom"
      fi

      # Exit with error if sync failed
      if [[ $SYNC_SUCCESS -eq 0 ]]; then
        exit 1
      fi
    '';

in
{
  options.mySystem.services.dnsStaticRecords = {
    enable = mkEnableOption "Declarative DNS static records via nsupdate";

    dnsServer = mkOption {
      type = types.str;
      default = "127.0.0.1";
      description = "DNS server address for nsupdate";
      example = "10.0.0.53";
    };

    tsigKeyFile = mkOption {
      type = types.path;
      description = "Path to TSIG key file in nsupdate format";
      example = "/run/secrets/nsupdate_tsig_key";
    };

    dryRun = mkOption {
      type = types.bool;
      default = false;
      description = ''
        When enabled, the sync service will compute and log all changes
        but will NOT execute nsupdate. Useful for previewing changes
        before deployment.
      '';
    };

    metrics = {
      enable = mkOption {
        type = types.bool;
        default = true;
        description = "Export Prometheus metrics via node exporter textfile collector";
      };

      path = mkOption {
        type = types.str;
        default = "/var/lib/prometheus-node-exporter-text-files/dns_static_records";
        description = ''
          Base path for metrics files. Each zone will create a file
          named <path>.<zone>.prom
        '';
      };
    };

    zones = mkOption {
      type = types.attrsOf zoneConfigType;
      default = { };
      description = "Zone configurations with static records";
      example = literalExpression ''
        {
          "internal" = {
            aRecords = [
              { name = "ns0"; ip = "10.0.0.53"; }
            ];
            nsRecords = [
              { zone = "@"; nameserver = "ns0.internal."; }
            ];
          };
        }
      '';
    };
  };

  config = mkIf cfg.enable {
    # Create a systemd service for each zone
    systemd.services = lib.mapAttrs'
      (zoneName: zoneConfig:
        lib.nameValuePair "dns-static-records-${zoneName}" {
          description = "Sync static DNS records for ${zoneName}";
          after = [ "network-online.target" ];
          wants = [ "network-online.target" ];
          wantedBy = [ "multi-user.target" ];

          serviceConfig = {
            Type = "oneshot";
            ExecStart = mkSyncScript zoneName zoneConfig;
            RemainAfterExit = true;

            # Retry logic for transient failures
            Restart = "on-failure";
            RestartSec = "10s";
            RestartMaxDelaySec = "5min";
          };

          # Re-run on config changes
          restartTriggers = [
            (builtins.hashString "sha256" (builtins.toJSON zoneConfig))
            (builtins.hashString "sha256" (builtins.toJSON cfg.dryRun))
          ];
        })
      cfg.zones;

    # Timer to periodically ensure records are in sync
    systemd.timers = lib.mapAttrs'
      (zoneName: _:
        lib.nameValuePair "dns-static-records-${zoneName}" {
          description = "Periodic sync for ${zoneName} static DNS records";
          wantedBy = [ "timers.target" ];
          timerConfig = {
            OnCalendar = "hourly";
            Persistent = true;
            RandomizedDelaySec = "5min";
          };
        })
      cfg.zones;
  };
}
