{ pkgs, config, ... }:
let
  forgejoUrl = "https://forge.internal";
  owner = "nemo";
  keepVersions = 10;

  cleanupScript = pkgs.writeShellScript "forgejo-container-cleanup" ''
    set -euo pipefail

    TOKEN=$(cat "$CREDENTIALS_DIRECTORY/api-token")
    API="${forgejoUrl}/api/v1"
    AUTH="Authorization: token $TOKEN"
    KEEP=${toString keepVersions}

    echo "Fetching container packages for ${owner}..."

    # Fetch all container package versions (paginated)
    all_versions=$(${pkgs.coreutils}/bin/mktemp)
    page=1
    while true; do
      batch=$(${pkgs.curl}/bin/curl -sf -H "$AUTH" \
        "$API/packages/${owner}?type=container&limit=50&page=$page")
      count=$(echo "$batch" | ${pkgs.jq}/bin/jq 'length')
      if [ "$count" = "0" ]; then break; fi
      echo "$batch" | ${pkgs.jq}/bin/jq -c '.[]' >> "$all_versions"
      page=$((page + 1))
    done

    total=$(${pkgs.coreutils}/bin/wc -l < "$all_versions")
    echo "Found $total total package versions"

    # Group by package name, sort by created_at descending, delete old ones
    ${pkgs.jq}/bin/jq -r '.name' "$all_versions" | ${pkgs.coreutils}/bin/sort -u | while read -r pkg_name; do
      echo "Processing package: $pkg_name"

      # Get versions for this package, sorted newest first
      versions=$(${pkgs.jq}/bin/jq -c "select(.name == \"$pkg_name\")" "$all_versions" \
        | ${pkgs.jq}/bin/jq -sc 'sort_by(.created_at) | reverse')

      version_count=$(echo "$versions" | ${pkgs.jq}/bin/jq 'length')
      echo "  $version_count versions found, keeping newest $KEEP"

      if [ "$version_count" -le "$KEEP" ]; then
        echo "  Nothing to delete"
        continue
      fi

      # Delete versions beyond the keep count
      echo "$versions" | ${pkgs.jq}/bin/jq -r ".[$KEEP:][].version" | while read -r version; do
        echo "  Deleting $pkg_name:$version"
        http_code=$(${pkgs.curl}/bin/curl -sf -o /dev/null -w '%{http_code}' \
          -X DELETE -H "$AUTH" \
          "$API/packages/${owner}/container/$pkg_name/$version")
        if [ "$http_code" = "204" ]; then
          echo "    Deleted"
        else
          echo "    Failed (HTTP $http_code)"
        fi
      done
    done

    ${pkgs.coreutils}/bin/rm -f "$all_versions"
    echo "Cleanup complete"
  '';
in
{
  sops.secrets.forgejo_api_token = { };

  systemd.services.forgejo-container-cleanup = {
    description = "Clean up old Forgejo container image versions";
    script = "${cleanupScript}";
    serviceConfig = {
      Type = "oneshot";
      LoadCredential = "api-token:${config.sops.secrets.forgejo_api_token.path}";
    };
  };

  systemd.timers.forgejo-container-cleanup = {
    description = "Weekly Forgejo container image cleanup";
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnCalendar = "Sun 03:00";
      Persistent = true;
    };
  };
}
