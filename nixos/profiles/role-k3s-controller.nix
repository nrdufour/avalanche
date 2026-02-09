{
  # For now ...
  networking.firewall = {
    enable = false;
  };

  sops.defaultSopsFile = ../../secrets/k3s-worker/secrets.sops.yaml;

  mySystem = {
    services.k3s = {
      enable = true;
      role = "server";
    };
    services.monitoring.nodeExporter.enable = false;
  };

  # Network sysctl tuning for K3s controller nodes
  # See: docs/architecture/network/k3s-sysctl-tuning.md for full rationale
  boot.kernel.sysctl = {
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