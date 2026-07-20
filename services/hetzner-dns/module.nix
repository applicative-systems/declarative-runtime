# Hetzner DNS <-> hetznercloud/hcloud pairing.
#
# Hetzner DNS is a *remote* managed service, not a local NixOS service: there
# is no upstream `services.hetzner-dns` module to enable.
#
# Authentication is a Hetzner Cloud API token, which cannot be
# self-bootstrapped.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  inherit (lib)
    mkEnableOption
    mkIf
    mkOption
    types
    ;
  cfg = config.services.hetzner-dns.runtime;
  tflib = import ./lib.nix { inherit pkgs; };
  serviceUser = "declarative-hetzner-dns";
  stateDir = "/var/lib/declarative-hetzner-dns";
  tf = tflib.hetznerDnsTfConfig cfg;
in
{
  options.services.hetzner-dns.runtime = {
    enable = mkEnableOption (
      "declarative Hetzner DNS configuration, applied via OpenTofu and the "
      + "hetznercloud/hcloud provider against the Hetzner DNS API"
    );

    tokenFile = mkOption {
      type = types.nullOr types.str;
      default = null;
      example = "/run/secrets/hcloud-dns-token";
      description = ''
        Runtime path to a file containing a Hetzner Cloud API token with
        permission to manage DNS zones (created under "Security > API tokens"
        in the Hetzner Cloud console).
      '';
    };

    endpoint = mkOption {
      type = types.str;
      default = "https://api.hetzner.cloud/v1";
      description = ''
        Base URL of the Hetzner Cloud API the provider targets. Override only to
        point at a self-hosted API proxy or a test double; the default is the
        public Hetzner Cloud API (which serves the DNS zone/RRSet endpoints).
      '';
    };
  }
  // tflib.resourceOptions;

  config = mkIf cfg.enable {
    assertions = [
      {
        assertion = cfg.tokenFile != null;
        message = "services.hetzner-dns.runtime.tokenFile is required: set it to a host path holding a Hetzner Cloud API token (DNS scope).";
      }
    ];

    users.users.${serviceUser} = {
      isSystemUser = true;
      group = serviceUser;
      home = stateDir;
      description = "declarative Hetzner DNS reconciler";
    };
    users.groups.${serviceUser} = { };
    systemd.tmpfiles.rules = [ "d ${stateDir} 0700 ${serviceUser} ${serviceUser} -" ];

    systemd.services.declarative-hetzner-dns =
      tflib.mkReconcileService {
        name = "declarative-hetzner-dns";
        tfConfig = tf.config;
        inherit (tf) credentials importEntries;
        afterUnits = [ ];
        inherit (cfg) tokenFile;
        user = serviceUser;
        group = serviceUser;
        inherit stateDir;
      }
      // {
        after = [ "network-online.target" ];
        wants = [ "network-online.target" ];
      };
  };
}
