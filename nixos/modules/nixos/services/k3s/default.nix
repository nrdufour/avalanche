{ pkgs, lib, config, ... }:
with lib;
let
  cfg = config.mySystem.services.k3s;
  k3sPackage = pkgs.k3s;
in
{
  options.mySystem.services.k3s = {
    enable = mkEnableOption "k3s";

    additionalFlags = mkOption {
      description = "Additional flags added to the k3s service as arguments";
      default = "";
      type = types.str;
    };

    role = mkOption {
      description = ''
        Whether k3s should run as a server or agent.

        If it's a server:

        - By default it also runs workloads as an agent.
        - Starts by default as a standalone server using an embedded sqlite datastore.
        - Configure `clusterInit = true` to switch over to embedded etcd datastore and enable HA mode.
        - Configure `serverAddr` to join an already-initialized HA cluster.

        If it's an agent:

        - `serverAddr` is required.
      '';
      default = "server";
      type = types.enum [
        "server"
        "agent"
      ];
    };

    isClusterInit = mkOption {
      description = "true if this is the first controller";
      default = false;
      type = types.bool;
    };

    serverAddr = mkOption {
      description = "Address of the server node to join (for non-init servers and agents)";
      default = "https://opi01.internal:6443";
      type = types.str;
    };

    tlsSans = mkOption {
      description = "Additional hostnames or IPs to add as Subject Alternative Names on the TLS certificate";
      default = [
        "opi01.internal"
        "opi02.internal"
        "opi03.internal"
        "10.1.0.5"
      ];
      type = types.listOf types.str;
    };

    registryMirrors = mkOption {
      description = "Container registries to mirror via the embedded registry";
      default = [
        "docker.io"
        "registry.k8s.io"
      ];
      type = types.listOf types.str;
    };

    longhornSupport = mkOption {
      description = "Enable NFS and iSCSI support required for Longhorn storage";
      default = true;
      type = types.bool;
    };
  };

  config = mkIf cfg.enable {
    # Token
    sops.secrets.k3s-server-token = { };

    services.k3s = {
      enable = true;
      package = k3sPackage;
      tokenFile = lib.mkDefault config.sops.secrets.k3s-server-token.path;
      serverAddr = if cfg.isClusterInit then "" else cfg.serverAddr;
      inherit (cfg) role;
      clusterInit = cfg.isClusterInit;
      extraFlags =
        let
          # Flags shared between server and agent
          commonFlags = [
            "--kubelet-arg node-status-update-frequency=4s"
          ];
          # Server-only flags
          serverFlags = [
            # Disable unused built-in services
            "--disable=local-storage"
            "--disable=traefik"
            "--disable=metrics-server"
            # Components extra args
            "--kube-apiserver-arg default-not-ready-toleration-seconds=20"
            "--kube-apiserver-arg default-unreachable-toleration-seconds=20"
            "--kube-controller-manager-arg bind-address=0.0.0.0"
            "--kube-controller-manager-arg node-monitor-period=4s"
            "--kube-controller-manager-arg node-monitor-grace-period=16s"
            "--kube-proxy-arg metrics-bind-address=0.0.0.0"
            "--kube-scheduler-arg bind-address=0.0.0.0"
            # Others
            "--etcd-expose-metrics"
            # Embedded Registry Mirror
            ## See https://docs.k3s.io/installation/registry-mirror for details
            "--embedded-registry"
          ]
          ++ map (san: "--tls-san ${san}") cfg.tlsSans;
        in
        toString (
          commonFlags
          ++ (if cfg.role == "server" then serverFlags else [])
        ) + optionalString (cfg.additionalFlags != "") " ${cfg.additionalFlags}";
    };

    environment.etc = {
      # Embedded Registry Mirror
      ## See https://docs.k3s.io/installation/registry-mirror for details
      "rancher/k3s/registries.yaml" = {
        text = ''
          mirrors:
        '' + concatMapStrings (mirror: "    ${mirror}:\n") cfg.registryMirrors;
      };
    };

    environment.systemPackages = [
      k3sPackage
    ] ++ optionals cfg.longhornSupport [
      pkgs.nfs-utils
      pkgs.openiscsi
    ];

    # Longhorn storage support (NFS + iSCSI)
    boot.supportedFilesystems = mkIf cfg.longhornSupport [ "nfs" ];
    services.rpcbind.enable = mkIf cfg.longhornSupport true;
    services.openiscsi = mkIf cfg.longhornSupport {
      enable = true;
      name = "iqn.2005-10.nixos:${config.networking.hostName}";
    };
    ## From https://github.com/longhorn/longhorn/issues/2166#issuecomment-2994323945
    systemd.services.iscsid.serviceConfig = mkIf cfg.longhornSupport {
      PrivateMounts = "yes";
      BindPaths = "/run/current-system/sw/bin:/bin";
    };

    # Adding a service to prune the images used by containerd
    systemd.services.ctr-prune = {
      serviceConfig = {
        Type = "oneshot";
        User = "root";
      };
      path = [ k3sPackage ];
      script = ''
        echo '--- Current images:'
        k3s crictl img
        echo '---'
        echo 'Starting to prune'
        k3s crictl rmi --prune
        echo 'Done pruning'
      '';
    };
    systemd.timers.ctr-prune = {
      wantedBy = [ "timers.target" ];
      partOf = [ "ctr-prune.service" ];
      timerConfig = {
        OnCalendar = "daily";
        Persistent = true;
        Unit = "ctr-prune.service";
      };
    };
  };

}