# PostgreSQL <-> cyrilgdn/postgresql pairing.
#
# Enables nothing in the upstream `services.postgresql` module beyond one role,
# and adds a run-once reconciler that applies declarative runtime state (roles,
# databases, grants, ...) against the local server once `postgresql.target` is
# up. A companion oneshot (declarative-postgresql-password.service) gives the
# reconciler's role a generated password, which the provider logs in with.
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
    mkBefore
    mkEnableOption
    mkIf
    mkOption
    types
    ;

  cfg = config.services.postgresql.runtime;
  postgresql = config.services.postgresql;
  tflib = import ./lib.nix { inherit pkgs nix-tf-schema; };
  inherit (tflib) adminUser;

  name = "declarative-postgresql";
  passwordServiceName = "${name}-password";
  stateDir = "/var/lib/${name}";
  passwordFile = "${stateDir}/admin-password";

  tf = tflib.postgresqlTfConfig cfg;

  # the names of the declared roles, with a key standing in for a null name.
  declaredRoles = lib.mapAttrsToList (
    key: role: if role.name or null == null then key else role.name
  ) (cfg.roles or { });
in
{
  options.services.postgresql.runtime = {
    enable = mkEnableOption (
      "declarative PostgreSQL configuration, applied via OpenTofu and the "
      + "cyrilgdn/postgresql provider after postgresql.target starts"
    );

    port = mkOption {
      type = types.port;
      default = postgresql.settings.port;
      defaultText = literalExpression "config.services.postgresql.settings.port";
      description = "Port of the local PostgreSQL server the provider connects to on `127.0.0.1`.";
    };
  }
  // tflib.resourceOptions;

  config = mkIf cfg.enable {
    assertions = [
      {
        assertion = postgresql.enable;
        message = "services.postgresql.runtime requires services.postgresql.enable = true.";
      }
      {
        assertion = !(lib.elem adminUser declaredRoles);
        message = "services.postgresql.runtime.roles: the role `${adminUser}` is the reconciler's own role; do not declare it.";
      }
    ];

    services.postgresql = {
      # The reconciler logs in as this role. It is a superuser, because a
      # declared resource can be any object in the cluster.
      ensureUsers = [
        {
          name = adminUser;
          ensureClauses = {
            superuser = true;
            login = true;
          };
        }
      ];
      # Let the role log in with its password over the loopback interface,
      # before any other rule can match it.
      authentication = mkBefore ''
        host all ${adminUser} 127.0.0.1/32 scram-sha-256
        host all ${adminUser} ::1/128 scram-sha-256
      '';
    };

    systemd.services = {
      ${name} = lib.recursiveUpdate (tflib.mkReconcileService {
        inherit name;
        tfConfig = tf.config;
        inherit (tf) credentials;
        afterUnits = [
          "postgresql.target"
          "${passwordServiceName}.service"
        ];
        # `postgresql.target` is only reached once the server accepts
        # connections, so there is nothing more to wait for. The password file
        # exists at this point, which makes the probe pass immediately.
        healthUrl = "file://${passwordFile}";
        tokenFile = passwordFile;
        user = "postgres";
        group = "postgres";
        inherit stateDir;
      }) { serviceConfig.StateDirectory = name; };

      ${passwordServiceName} = {
        description = "Set the password of the ${name} role";
        after = [ "postgresql-setup.service" ];
        requires = [ "postgresql-setup.service" ];
        path = [ postgresql.finalPackage ];
        environment.PGPORT = toString postgresql.settings.port;
        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
          User = "postgres";
          Group = "postgres";
          StateDirectory = name;
          StateDirectoryMode = "0700";
        };
        script = ''
          set -euo pipefail
          umask 077

          # Generate the password once; /var/lib survives reboots.
          if [ ! -s ${passwordFile} ]; then
            od -An -tx1 -N32 /dev/urandom | tr -d ' \n' > ${passwordFile}.tmp
            mv ${passwordFile}.tmp ${passwordFile}
          fi

          # Set it on every start, so the role and the file cannot drift apart.
          psql -d postgres -v ON_ERROR_STOP=1 <<'EOF'
          \set password `cat ${passwordFile}`
          ALTER ROLE ${adminUser} WITH PASSWORD :'password';
          EOF
        '';
      };
    };
  };
}
