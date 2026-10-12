# Garage <-> jkossis/garage pairing.
#
# Enables the upstream `services.garage` module unchanged, and adds a run-once
# reconciler that applies declarative runtime state (buckets, access keys and
# the grants between them) against Garage's v2 admin API once `garage.service`
# is up.
#
# The admin token is the one Garage itself reads at startup
# (`settings.admin.admin_token_file`), so there is no token to bootstrap: Garage
# has no admin token until its config has one, and a token minted at runtime
# (`garage admin-token create`) is stored in the cluster, which needs a layout
# first.
#
# `nix-tf-schema` is the schema-conversion library the resource surface is derived
# from; the flake injects it via `_module.args`, since a NixOS module cannot
# reach a flake input by path.
{
  config,
  lib,
  pkgs,
  nix-tf-schema,
  ...
}:
let
  inherit (lib)
    literalExpression
    mkEnableOption
    mkIf
    mkOption
    types
    ;

  cfg = config.services.garage.runtime;
  garage = config.services.garage;
  tflib = import ./lib.nix { inherit pkgs nix-tf-schema; };

  # `api_bind_addr` is `<host>:<port>` (the host possibly a bracketed IPv6
  # address); the port is what follows the last colon.
  adminBind = garage.settings.admin.api_bind_addr or null;
  defaultBaseUrl =
    if adminBind == null then null else "http://localhost:${lib.last (lib.splitString ":" adminBind)}";

  tf = tflib.garageTfConfig cfg;
in
{
  options.services.garage.runtime = {
    enable = mkEnableOption (
      "declarative Garage configuration, applied via OpenTofu and the garage "
      + "provider after garage.service starts"
    );

    baseUrl = mkOption {
      type = types.nullOr types.str;
      default = defaultBaseUrl;
      defaultText = literalExpression ''"http://localhost:<port of services.garage.settings.admin.api_bind_addr>"'';
      description = "Base URL of the local Garage admin API the provider targets.";
    };

    tokenFile = mkOption {
      type = types.nullOr types.str;
      default = garage.settings.admin.admin_token_file or null;
      defaultText = literalExpression "config.services.garage.settings.admin.admin_token_file";
      example = "/run/secrets/garage-admin-token";
      description = ''
        Runtime path to a file containing a Garage admin API token.

        This is a path resolved on the target host (e.g. provisioned by
        sops-nix or agenix), NOT a store path: it is handed to the reconciler
        via systemd `LoadCredential=` and never copied into the Nix store.

        Defaults to the file Garage itself reads its admin token from.
      '';
    };
  }
  // tflib.resourceOptions;

  config = mkIf cfg.enable {
    assertions = [
      {
        assertion = garage.enable;
        message = "services.garage.runtime requires services.garage.enable = true.";
      }
      {
        # The provider speaks the v2 admin API, which Garage serves from 2.0.
        assertion = lib.versionAtLeast garage.package.version "2";
        message = "services.garage.runtime requires Garage 2.0 or later (services.garage.package = pkgs.garage_2).";
      }
      {
        assertion = cfg.baseUrl != null;
        message = "services.garage.runtime requires the admin API: set services.garage.settings.admin.api_bind_addr, or services.garage.runtime.baseUrl.";
      }
      {
        assertion = cfg.tokenFile != null;
        message = "services.garage.runtime requires an admin token: set services.garage.settings.admin.admin_token_file, or services.garage.runtime.tokenFile.";
      }
    ];

    systemd.services.declarative-garage = tflib.mkReconcileService {
      name = "declarative-garage";
      tfConfig = tf.config;
      inherit (tf) credentials;
      afterUnits = [ "garage.service" ];
      # 200 only once the cluster has a layout, which no bucket or key can be
      # made without.
      healthUrl = "${cfg.baseUrl}/health";
      inherit (cfg) tokenFile;
      # The reconciler only uses the admin API, so it runs as a dynamic user of
      # its own. Its state cannot go below `/var/lib/garage`: that is the
      # state directory of Garage's dynamic user, and systemd cannot make a
      # state directory of a different unit in it.
      user = "declarative-garage";
      group = "declarative-garage";
      dynamicUser = true;
      stateDir = "/var/lib/declarative-garage";
    };
  };
}
