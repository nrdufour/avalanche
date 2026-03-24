{ config, pkgs, lib, ... }: {

  # Using a yubikey to store the keypairs
  environment.systemPackages = with pkgs; [
    yubikey-manager
    step-ca
    step-cli
  ];
  services.pcscd.enable = true;

  sops.secrets = {
    stepca_intermediate_password = { };
    stepca_yubikey_pin = { };
  };

  environment.etc = {
    "smallstep/root_ca.crt" = {
      text = lib.readFile ./resources/root_ca.crt;
      user = "step-ca";
    };

    "smallstep/intermediate_ca.crt" = {
      text = lib.readFile ./resources/intermediate_ca.crt;
      user = "step-ca";
    };

    # Override upstream-generated ca.json with sops template (contains YubiKey PIN)
    "smallstep/ca.json".source = lib.mkForce config.sops.templates."smallstep-config.json".path;
  };

  sops.templates."smallstep-config.json" = {
    owner = "step-ca";
    content = ''
      {
        "root": "/etc/smallstep/root_ca.crt",
        "crt": "/etc/smallstep/intermediate_ca.crt",
        "key": "yubikey:slot-id=9c",
        "kms": {
          "type": "yubikey",
          "pin": "${config.sops.placeholder.stepca_yubikey_pin}"
        },
        "address": "${config.services.step-ca.address}:${toString config.services.step-ca.port}",
        "insecureAddress": "",
        "dnsNames": [
          "ca.internal",
          "hawk.internal"
        ],
        "logger": {
          "format": "text"
        },
        "db": {
          "type": "badgerv2",
          "dataSource": "/var/lib/step-ca",
          "badgerFileLoadingMode": ""
        },
        "authority": {
          "enableAdmin": true,
          "provisioners": [
            {
              "name": "acme",
              "type": "ACME"
            }
          ],
          "claims": {
            "minTLSCertDuration": "24h",
            "maxTLSCertDuration": "168h",
            "defaultTLSCertDuration": "168h"
          }
        },
        "tls": {
          "cipherSuites": [
            "TLS_ECDHE_ECDSA_WITH_CHACHA20_POLY1305_SHA256",
            "TLS_ECDHE_ECDSA_WITH_AES_128_GCM_SHA256"
          ],
          "minVersion": 1.2,
          "maxVersion": 1.3,
          "renegotiation": false
        }
      }
    '';
  };

  services.step-ca = {
    enable = true;
    intermediatePasswordFile = config.sops.secrets.stepca_intermediate_password.path;
    address = "0.0.0.0";
    port = 8443;
    openFirewall = true;
    settings = { }; # overridden by sops template via environment.etc
  };

  # Use knot DNS directly for ACME DNS-01 challenge validation
  systemd.services.step-ca.serviceConfig.ExecStart = lib.mkForce [
    "" # override upstream
    "${pkgs.step-ca}/bin/step-ca /etc/smallstep/ca.json --password-file \${CREDENTIALS_DIRECTORY}/intermediate_password --resolver 10.0.0.53:53"
  ];

}
