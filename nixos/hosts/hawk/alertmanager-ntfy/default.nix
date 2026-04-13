{ ... }:
{
  services.prometheus.alertmanager-ntfy = {
    enable = true;
    settings = {
      # Listen on all interfaces so the in-cluster Alertmanager can reach
      # us via http://alertmanager-ntfy.internal:8000. Plain HTTP on the
      # home network — no TLS trust complications for the webhook caller.
      http.addr = "0.0.0.0:8000";

      ntfy = {
        # Bypass nginx/TLS entirely and talk to ntfy on its localhost
        # listener — both services live on hawk, so this is a loopback
        # call that avoids the step-ca trust dance for the relay's own
        # HTTP client. External clients still reach ntfy via the nginx
        # vhost at https://ntfy.internal.
        baseurl = "http://127.0.0.1:2586";
        notification = {
          topic = "homelab-alerts";
          priority = ''
            severity == "critical" ? "urgent" :
            severity == "warning"  ? "high"   :
            status   == "firing"   ? "default":
                                     "low"
          '';
          # Default tag set (red_circle on firing, green_circle on resolved)
          # is fine; leave it at the module default.
        };
      };
    };
  };

  # Open the relay's TCP port on hawk. firewall.enable is false in hawk's
  # default.nix so this is technically redundant, but keeping it declarative
  # means the service stays reachable if the firewall is ever turned on.
  networking.firewall.allowedTCPPorts = [ 8000 ];
}
