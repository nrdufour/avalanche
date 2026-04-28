{
  # For now ...
  networking.firewall = {
    enable = false;
  };

  sops.defaultSopsFile = ../../secrets/k3s-worker/secrets.sops.yaml;

  # Spread the 03:00 fleet upgrade burst across a 30-minute window. The
  # early-tier hosts (hawk 01:30, routy 02:00, cardinal/possum 02:30) keep
  # deterministic slots in their own host configs; only the bulk fleet
  # (k3s workers + controllers + muninn) jitters here. Goal is to avoid a
  # repeat of the 2026-04-22 thundering-herd DNS failure where every host
  # hit github.com simultaneously while routy was still rebooting.
  system.autoUpgrade.randomizedDelaySec = "30min";

  mySystem = {
    services.k3s = {
      enable = true;
      role = "agent";
      linstorSupport = true;
    };
    services.monitoring.nodeExporter.enable = false;
  };

  # Network sysctl tuning for K3s worker nodes
  # See: docs/architecture/network/k3s-sysctl-tuning.md for full rationale
  boot.kernel.sysctl = {
    # IP forwarding (required for flannel VXLAN decap → cni0 → pods).
    # NixOS's tasks/network-interfaces.nix sets forwarding=false by default
    # (mkDefault, gated on proxyARP). The k3s NixOS module relies on
    # kube-proxy/flannel to set this at runtime, but a switch-to-configuration
    # that reloads systemd-sysctl.service will clobber it back to 0,
    # silently breaking cross-node pod traffic. 2026-04-28 outage.
    "net.ipv4.ip_forward" = 1;
    "net.ipv4.conf.all.forwarding" = 1;

    # Connection tracking (prevent table exhaustion)
    # Reference: https://wiki.nftables.org/wiki-nftables/index.php/Connection_Tracking_System
    # Impact: Prevents "nf_conntrack: table full" errors from Nginx Ingress, Gluetun NAT, service mesh
    "net.netfilter.nf_conntrack_max" = 262144;

    # Network buffers (ARM SBC optimization)
    # Reference: https://fasterdata.es.net/network-tuning/linux/
    # Impact: Prevents "broken pipe" errors on media streaming, model transfers, container pulls
    # Evidence: Same tuning applied to eagle host (nixos/hosts/eagle/default.nix:45-50)
    "net.core.rmem_max" = 16777216;      # 16MB receive buffer max
    "net.core.wmem_max" = 16777216;      # 16MB send buffer max
    "net.core.rmem_default" = 262144;    # 256KB receive buffer default
    "net.core.wmem_default" = 262144;    # 256KB send buffer default
    "net.ipv4.tcp_rmem" = "4096 87380 16777216";   # TCP receive buffer (min, default, max)
    "net.ipv4.tcp_wmem" = "4096 65536 16777216";   # TCP send buffer (min, default, max)
  };
}