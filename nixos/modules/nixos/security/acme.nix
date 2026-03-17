{
  ## Defaulting to the local step-ca server (via ca.internal alias)

  security.acme = {
    acceptTerms = true;
    defaults = {
      webroot = "/var/lib/acme/acme-challenge";
      server = "https://ca.internal:8443/acme/acme/directory";
      email = "nrdufour@gmail.com";
    };
  };
}