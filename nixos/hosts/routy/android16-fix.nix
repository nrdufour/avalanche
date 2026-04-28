{ pkgs, ... }: {
  # Fix for Android 16 rejecting DSCP marked packets
  # Android 16 has stricter network validation and rejects TCP packets with
  # QoS markings (DSCP). This affects multiple services (fly.dev, CDNs, etc.)
  # all on port 443. Solution: globally clear DSCP to cs0 for all traffic.
  # DSCP is largely ignored by ISPs anyway and has minimal impact on home networks.

  systemd.services.android16-dscp-fix = {
    description = "Clear DSCP markings globally for Android 16 compatibility";
    # The `ip filter` table + FORWARD chain is created by tailscaled via
    # iptables-nft, not by nftables.service. Order after tailscaled and
    # poll for the chain so we don't race the boot.
    after = [ "network.target" "nftables.service" "tailscaled.service" ];
    wants = [ "nftables.service" "tailscaled.service" ];
    wantedBy = [ "multi-user.target" ];

    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      Restart = "on-failure";
      RestartSec = "5s";
    };

    script = ''
      # Wait until the FORWARD chain in `ip filter` exists (created by
      # tailscaled via iptables-nft). Bail after ~30s to surface real failures.
      for i in $(seq 1 30); do
        if ${pkgs.nftables}/bin/nft list chain ip filter FORWARD >/dev/null 2>&1; then
          break
        fi
        sleep 1
      done

      ${pkgs.nftables}/bin/nft insert rule ip filter FORWARD ip dscp != cs0 ip dscp set cs0

      echo "Android 16 DSCP fix applied (global)"
    '';

    preStop = ''
      # Clean up on service stop
      # Find and delete the rule by matching the dscp operation
      HANDLE=$(${pkgs.nftables}/bin/nft -a list chain ip filter FORWARD | ${pkgs.gnugrep}/bin/grep "dscp set cs0" | ${pkgs.gawk}/bin/awk '{print $NF}')
      if [ -n "$HANDLE" ]; then
        ${pkgs.nftables}/bin/nft delete rule ip filter FORWARD handle $HANDLE 2>/dev/null || true
      fi
    '';
  };
}
