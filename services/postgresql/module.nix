# PostgreSQL <-> cyrilgdn/postgresql pairing.
#
# Changes nothing in the upstream `services.postgresql` module, and adds a
# run-once reconciler that applies declarative runtime state (roles,
# databases, grants, ...) against the local server once `postgresql.target` is
# up. The reconciler runs as the `postgres` OS user and connects over the Unix
# socket, where peer authentication makes it the `postgres` superuser: there is
# no credential to mint or to keep.
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

  cfg = config.services.postgresql.runtime;
  postgresql = config.services.postgresql;
  tflib = import ./lib.nix { inherit pkgs nix-tf-schema; };

  name = "declarative-postgresql";
  inherit (cfg) stateDir;
  workDir = "${stateDir}/declarative-terraform";
  # The first directory the server makes a socket in.
  socketDir = lib.trim (
    lib.head (lib.splitString "," (postgresql.settings.unix_socket_directories or "/run/postgresql"))
  );

  tf = tflib.postgresqlTfConfig { inherit (postgresql) superUser; } cfg;

in
{
  options.services.postgresql.runtime = {
    enable = mkEnableOption (
      "declarative PostgreSQL configuration, applied via OpenTofu and the "
      + "cyrilgdn/postgresql provider after postgresql.target starts"
    );

    stateDir = mkOption {
      type = types.str;
      default = "/var/lib/postgresql";
      example = "/srv/postgresql";
      description = ''
        Host path whose `declarative-terraform` subdirectory holds the
        reconciler's Terraform state. Not the data directory itself: `initdb`
        needs that empty, and a major upgrade moves to a new one.
      '';
    };

    port = mkOption {
      type = types.port;
      default = postgresql.settings.port;
      defaultText = literalExpression "config.services.postgresql.settings.port";
      description = "Port of the local PostgreSQL server, whose Unix socket the provider connects to.";
    };
  }
  // tflib.resourceOptions;

  config = mkIf cfg.enable {
    assertions = [
      {
        assertion = postgresql.enable;
        message = "services.postgresql.runtime requires services.postgresql.enable = true.";
      }
    ];

    # `stateDir` need not exist, nor be writable by `postgres`.
    systemd.tmpfiles.settings.${name}.${workDir}.d = {
      user = "postgres";
      group = "postgres";
      mode = "0700";
    };

    systemd.services.${name} =
      lib.recursiveUpdate
        (tflib.mkReconcileService {
          inherit name;
          tfConfig = tf.config;
          inherit (tf) credentials;
          afterUnits = [ "postgresql.target" ];
          # `postgresql.target` is only reached once the server accepts
          # connections, so there is nothing more to wait for.
          healthUrl = null;
          # The `postgres` OS user, which peer authentication on the socket maps
          # to the `postgres` superuser (see `services.postgresql.identMap`).
          user = "postgres";
          group = "postgres";
          inherit stateDir;
        })
        {
          # The provider block sets an empty host, so the driver falls back to
          # PGHOST: the provider cannot put a socket path into its connection URL.
          environment.PGHOST = socketDir;
        };
  };
}
