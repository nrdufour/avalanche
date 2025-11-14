{ pkgs, ... }: {
  # Fix for Android 16 rejecting DSCP CS5 marked packets from fly.dev
  # Android 16 has stricter network validation and rejects TCP packets with
  # QoS markings (DSCP CS5 / ToS 0x28) that fly.dev uses on their SYN-ACK packets

  systemd.services.android16-dscp-fix = {
    description = "Clear DSCP markings from fly.dev for Android 16 compatibility";
    after = [ "network.target" "nftables.service" ];
    wants = [ "nftables.service" ];
    wantedBy = [ "multi-user.target" ];

    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
    };

    script = ''
      # Wait for nftables to be ready
      sleep 2

      # Create set for fly.dev IP ranges in filter table
      ${pkgs.nftables}/bin/nft add set ip filter flydev_ips '{ type ipv4_addr; flags interval; }' 2>/dev/null || true

      # Add fly.dev IP ranges
      ${pkgs.nftables}/bin/nft add element ip filter flydev_ips '{ 66.241.124.0/24 }' 2>/dev/null || true
      ${pkgs.nftables}/bin/nft add element ip filter flydev_ips '{ 199.38.181.0/24 }' 2>/dev/null || true
      ${pkgs.nftables}/bin/nft add element ip filter flydev_ips '{ 209.177.145.0/24 }' 2>/dev/null || true

      # Add rule to clear DSCP on packets from fly.dev in FORWARD chain
      ${pkgs.nftables}/bin/nft insert rule ip filter FORWARD ip saddr @flydev_ips ip dscp set cs0

      echo "Android 16 DSCP fix applied"
    '';

    preStop = ''
      # Clean up on service stop
      # Find and delete the rule
      HANDLE=$(${pkgs.nftables}/bin/nft -a list chain ip filter FORWARD | ${pkgs.gnugrep}/bin/grep flydev_ips | ${pkgs.gawk}/bin/awk '{print $NF}')
      if [ -n "$HANDLE" ]; then
        ${pkgs.nftables}/bin/nft delete rule ip filter FORWARD handle $HANDLE 2>/dev/null || true
      fi
      ${pkgs.nftables}/bin/nft delete set ip filter flydev_ips 2>/dev/null || true
    '';
  };
}
