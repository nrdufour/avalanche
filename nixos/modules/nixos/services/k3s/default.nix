{ pkgs, lib, config, self, ... }:
with lib;
let
  cfg = config.mySystem.services.k3s;
  defaultServerAddr = "https://opi01.internal:6443";
  ## Kubernetes versions in stable (25.11):
  ## k3s: 1.34
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
  };

  config = mkIf cfg.enable {
    # Token
    sops.secrets.k3s-server-token = { };

    services.k3s = {
      enable = true;
      package = k3sPackage;
      tokenFile = lib.mkDefault config.sops.secrets.k3s-server-token.path;
      serverAddr = if cfg.isClusterInit then "" else defaultServerAddr;
      inherit (cfg) role;
      clusterInit = cfg.isClusterInit;
      extraFlags = (if cfg.role == "agent"
        then ""
        else toString [
          # Disable useless services
          ## TODO: probably need to add service-lb soon
          "--disable=local-storage"
          "--disable=traefik"
          "--disable=metrics-server"
          # virtual IP and its name
          "--tls-san opi01.internal"
          "--tls-san opi02.internal"
          "--tls-san opi03.internal"
          "--tls-san 10.1.0.5"
          # Components extra args
          "--kube-apiserver-arg default-not-ready-toleration-seconds=20"
          "--kube-apiserver-arg default-unreachable-toleration-seconds=20"
          "--kube-controller-manager-arg bind-address=0.0.0.0"
          "--kube-controller-manager-arg node-monitor-period=4s"
          "--kube-controller-manager-arg node-monitor-grace-period=16s"
          "--kube-proxy-arg metrics-bind-address=0.0.0.0"
          "--kube-scheduler-arg bind-address=0.0.0.0"
          "--kubelet-arg node-status-update-frequency=4s"
          # Others
          "--etcd-expose-metrics"
          "--disable-cloud-controller"
          # Embedded Registry Mirror
          ## See https://docs.k3s.io/installation/registry-mirror for details
          ## New feature since January 2024
          "--embedded-registry"
        ]) + cfg.additionalFlags;
    };

    environment.etc = {
      # Embedded Registry Mirror
      ## See https://docs.k3s.io/installation/registry-mirror for details
      "rancher/k3s/registries.yaml" = {
        text = ''
          mirrors:
            docker.io:
            registry.k8s.io:
        '';
      };
    };

    environment.systemPackages = [
      k3sPackage

      # For NFS
      pkgs.nfs-utils
      # For open-iscsi
      pkgs.openiscsi
    ];

    # For NFS
    boot.supportedFilesystems = [ "nfs" ];
    services.rpcbind.enable = true;

    # For open-iscsi
    services.openiscsi = {
      enable = true;
      name = "iqn.2005-10.nixos:${config.networking.hostName}";
    };
    ## From https://github.com/longhorn/longhorn/issues/2166#issuecomment-2994323945
    systemd.services.iscsid.serviceConfig = {
      PrivateMounts = "yes";
      BindPaths = "/run/current-system/sw/bin:/bin";
    };

    # ==========================================================================
    # WORKAROUND: Flannel subnet.env not created on k3s server nodes after reboot
    # ==========================================================================
    #
    # Date discovered: 2026-02-02
    # Nixpkgs revision: 41e216c0ca66c83b12ab7a98cc326b5db01db646
    # k3s version: 1.34.3+k3s1
    #
    # Problem:
    #   After a reboot, k3s server nodes (especially cluster-init nodes) may fail
    #   to initialize the flannel networking backend. The embedded flannel never
    #   writes /run/flannel/subnet.env, causing all pod sandbox creation to fail
    #   with: "plugin type=\"flannel\" failed (add): loadFlannelSubnetEnv failed:
    #   open /run/flannel/subnet.env: no such file or directory"
    #
    # Root cause:
    #   On k3s server nodes with embedded etcd (clusterInit=true), the startup
    #   sequence includes an etcd reconciliation phase ("Starting temporary etcd
    #   to reconcile with datastore"). During this special startup path, flannel
    #   initialization appears to be silently skipped - the expected log messages
    #   "Starting flannel with backend vxlan" and "Running flannel backend" never
    #   appear. The kubelet receives its Pod CIDR assignment, but flannel never
    #   writes the subnet.env file that the CNI plugin needs.
    #
    # Impact:
    #   - No pods can start on the affected node (including kured)
    #   - If kured cordoned the node for reboot, it cannot uncordon it
    #   - The kured lock remains held, blocking reboots on other nodes
    #
    # Workaround:
    #   This service creates a minimal /run/flannel/subnet.env before k3s starts.
    #   The values are derived from the node's expected Pod CIDR based on its
    #   position in the cluster. The CNI plugin can then configure pod networking
    #   even if flannel's backend initialization is skipped.
    #
    # Related issues:
    #   - https://github.com/k3s-io/k3s/issues/8179
    #   - https://github.com/k3s-io/k3s/issues/11619
    #   - https://github.com/k3s-io/k3s/issues/2599
    #
    # TODO: Remove this workaround once the upstream k3s bug is fixed.
    # ==========================================================================
    systemd.services.k3s-flannel-workaround = mkIf (cfg.role == "server") {
      description = "Ensure flannel subnet.env exists for k3s";
      before = [ "k3s.service" ];
      wantedBy = [ "multi-user.target" ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
      };
      script = ''
        mkdir -p /run/flannel
        if [ ! -f /run/flannel/subnet.env ]; then
          echo "Creating /run/flannel/subnet.env (k3s flannel workaround)"
          # Use node-specific subnet based on hostname
          # These match the Pod CIDRs assigned by the cluster:
          #   opi01: 10.42.0.0/24, opi02: 10.42.1.0/24, opi03: 10.42.2.0/24
          case "$(hostname)" in
            opi01) SUBNET="10.42.0.1/24" ;;
            opi02) SUBNET="10.42.1.1/24" ;;
            opi03) SUBNET="10.42.2.1/24" ;;
            *)     SUBNET="10.42.255.1/24" ;; # Fallback, should not happen
          esac
          cat > /run/flannel/subnet.env <<EOF
FLANNEL_NETWORK=10.42.0.0/16
FLANNEL_SUBNET=$SUBNET
FLANNEL_MTU=1450
FLANNEL_IPMASQ=true
EOF
          echo "Created /run/flannel/subnet.env with FLANNEL_SUBNET=$SUBNET"
        else
          echo "/run/flannel/subnet.env already exists, skipping"
        fi
      '';
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
        Unit = "ctr-prune.service";
      };
    };
  };

}