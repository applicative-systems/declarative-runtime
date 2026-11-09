# incus <-> lxc/incus pairing.
#
# Leaves the upstream `virtualisation.incus` module unchanged, and adds a
# run-once reconciler that applies declarative runtime state (networks,
# storage pools, profiles, projects, server configuration, trusted
# certificates and more) against the local incus daemon once `incus.service`
# is up.
#
# The reconciler runs as root and talks to incus over its local unix socket,
# so there is no credential to bootstrap.
#
# incus's own preseed (`virtualisation.incus.preseed`) and this reconciler can
# both set up the same objects. A preseed applies on each start of incus, can
# only create and update, and has no state. The reconciler also removes what
# it no longer declares, but it runs after incus is up and can fail. A host
# can split the two (see ./README.md): the preseed makes what other services
# need even when the reconciler fails, and the reconciler takes the objects
# over with `adopt` and manages the rest.
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
    mkEnableOption
    mkIf
    mkOption
    types
    ;

  cfg = config.virtualisation.incus.runtime;
  incus = config.virtualisation.incus;
  tflib = import ./lib.nix { inherit pkgs nix-tf-schema; };

  tf = tflib.incusTfConfig cfg;

  stateDir = "/var/lib/declarative-incus";
in
{
  options.virtualisation.incus.runtime = {
    enable = mkEnableOption (
      "declarative incus configuration, applied via OpenTofu and the incus "
      + "provider after incus.service starts"
    );

    configDir = mkOption {
      type = types.str;
      default = "${stateDir}/client";
      description = ''
        Directory the provider reads its client configuration (`config.yml`)
        from. When the file does not exist, the provider uses its default
        configuration: the local daemon over its unix socket.

        The default is a directory that nothing writes to, so that the remotes
        of an admin (in `/root/.config/incus`) do not change what the
        reconciler manages.
      '';
    };
  }
  // tflib.resourceOptions;

  config = mkIf cfg.enable {
    assertions = [
      {
        assertion = incus.enable;
        message = "virtualisation.incus.runtime requires virtualisation.incus.enable = true.";
      }
      {
        assertion = lib.length (lib.attrNames cfg.server) <= 1;
        message = "virtualisation.incus.runtime.server: set one entry at most. Two entries manage the same server configuration.";
      }
    ];

    systemd.services.declarative-incus = tflib.mkReconcileService {
      name = "declarative-incus";
      tfConfig = tf.config;
      inherit (tf) credentials;
      # `incus.service` returns only when the daemon is ready (`incusd
      # waitready`), so no health check is necessary. After the preseed, so
      # that the objects it makes exist when the reconciler adopts them. A
      # restart of incus also restarts the preseed and then the reconciler.
      afterUnits = [ "incus.service" ] ++ lib.optional (incus.preseed != null) "incus-preseed.service";
      # Access to the incus unix socket is root access, so the reconciler
      # runs as root.
      user = "root";
      group = "root";
      inherit stateDir;
    };
  };
}
