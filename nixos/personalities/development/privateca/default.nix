{
    # security.pki.certificateFiles = [
    #     /etc/nixos/private_ca.crt
    # ];

    security.pki.certificates = [
        (builtins.readFile ./private-ca.crt)
        (builtins.readFile ./root_ca.crt)
    ];

    # Make Python requests and curl use the system CA bundle
    # (includes our private CA certificates)
    environment.sessionVariables = {
        REQUESTS_CA_BUNDLE = "/etc/ssl/certs/ca-bundle.crt";
        CURL_CA_BUNDLE = "/etc/ssl/certs/ca-bundle.crt";
        SSL_CERT_FILE = "/etc/ssl/certs/ca-bundle.crt";
    };
}
