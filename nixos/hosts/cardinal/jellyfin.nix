{
  pkgs,
  ...
}:
{

  systemd.services.jellyfin.environment.LIBVA_DRIVER_NAME = "iHD"; # Or "i965" if using older driver
  environment.sessionVariables = { LIBVA_DRIVER_NAME = "iHD"; };      # Same here
  hardware.graphics = {
    enable = true;
    extraPackages = with pkgs; [
      intel-media-driver # For Broadwell (2014) or newer processors. LIBVA_DRIVER_NAME=iHD
      # intel-vaapi-driver # For older processors. LIBVA_DRIVER_NAME=i965
      # libva-vdpau-driver # Previously vaapiVdpau
      intel-compute-runtime # OpenCL filter support (hardware tonemapping and subtitle burn-in)
      # OpenCL support for intel CPUs before 12th gen
      # see: https://github.com/NixOS/nixpkgs/issues/356535
      # intel-compute-runtime-legacy1 
      vpl-gpu-rt # QSV on 11th gen or newer
      # intel-media-sdk # QSV up to 11th gen
      intel-ocl # OpenCL support
    ];
  };

  services.jellyfin = {
    enable = true;
    openFirewall = true;
  };

  environment.systemPackages = [
    pkgs.jellyfin
    pkgs.jellyfin-web
    pkgs.jellyfin-ffmpeg
  ];

  security.acme.certs = {
    "jellyfin.internal" = { };
  };

  services.nginx = {
    enable = true;
    recommendedGzipSettings = true;
    recommendedOptimisation = true;
    recommendedProxySettings = true;
    recommendedTlsSettings = true;

    virtualHosts."jellyfin.internal" = {
      forceSSL = true;
      enableACME = true;
      extraConfig = ''
        client_max_body_size 20M;

        # Disable gzip for media streaming
        gzip off;
      '';
      locations."/" = {
        proxyPass = "http://localhost:8096";
        proxyWebsockets = true; # Enable WebSocket support
        extraConfig = ''
          # Disable buffering for real-time and streaming content
          proxy_buffering off;

          # Increase timeouts for long-running streams
          proxy_read_timeout 3600s;
          proxy_send_timeout 3600s;

          # HLS/streaming optimizations - range request support
          proxy_set_header Range $http_range;
          proxy_set_header If-Range $http_if_range;

          # Cache control for static assets
          proxy_cache_bypass $http_range $http_if_range;
        '';
      };
    };

    virtualHosts."jellyfin-tv.internal" = {
      # HTTP-only for Samsung TV compatibility
      forceSSL = false;
      enableACME = false;
      extraConfig = ''
        client_max_body_size 20M;

        # Disable gzip for media streaming
        gzip off;
      '';
      locations."/" = {
        proxyPass = "http://localhost:8096";
        proxyWebsockets = true; # Enable WebSocket support
        extraConfig = ''
          # Disable buffering for real-time and streaming content
          proxy_buffering off;

          # Increase timeouts for long-running streams
          proxy_read_timeout 3600s;
          proxy_send_timeout 3600s;

          # HLS/streaming optimizations - range request support
          proxy_set_header Range $http_range;
          proxy_set_header If-Range $http_if_range;

          # Cache control for static assets
          proxy_cache_bypass $http_range $http_if_range;
        '';
      };
    };
  };
}