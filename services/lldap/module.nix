# lldap <-> tasansga/lldap pairing.
#
# Enables the upstream `services.lldap` module unchanged, and adds a run-once
# reconciler that applies declarative runtime state (users, groups, custom
# attributes and memberships) against lldap's GraphQL API once `lldap.service`
# is up.
#
# The provider logs in as the admin user that lldap itself makes from its
# bootstrap credential (`ldap_user_dn`, with the password in
# `ldap_user_pass_file`), so there is no credential to bootstrap. lldap reads
# each of these settings from its `LLDAP_<NAME>` environment variable first, so
# the defaults here do the same.
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

  cfg = config.services.lldap.runtime;
  lldap = config.services.lldap;
  # what the upstream module makes lldap.service run as, and where.
  lldapUnit = config.systemd.services.lldap.serviceConfig;
  # the value lldap uses for a setting: `LLDAP_<NAME>` has priority over the config file.
  lldapSetting =
    name: lldap.environment."LLDAP_${lib.toUpper name}" or lldap.settings.${name} or null;
  tflib = import ./lib.nix { inherit pkgs nix-tf-schema; };

  tf = tflib.lldapTfConfig cfg;
in
{
  options.services.lldap.runtime = {
    enable = mkEnableOption (
      "declarative lldap configuration, applied via OpenTofu and the lldap "
      + "provider after lldap.service starts"
    );

    baseUrl = mkOption {
      type = types.str;
      default = "http://localhost:${toString lldap.settings.http_port}";
      defaultText = literalExpression ''"http://localhost:''${toString config.services.lldap.settings.http_port}"'';
      description = "Base URL of the local lldap web API the provider targets.";
    };

    ldapUrl = mkOption {
      type = types.str;
      default = "ldap://localhost:${toString lldap.settings.ldap_port}";
      defaultText = literalExpression ''"ldap://localhost:''${toString config.services.lldap.settings.ldap_port}"'';
      description = "URL of the local lldap LDAP server. The provider uses it to set user passwords.";
    };

    adminUser = mkOption {
      type = types.str;
      default = lldapSetting "ldap_user_dn";
      defaultText = literalExpression "config.services.lldap.environment.LLDAP_LDAP_USER_DN or config.services.lldap.settings.ldap_user_dn";
      description = "User name the provider logs in as. The user must be in the `lldap_admin` group.";
    };

    baseDN = mkOption {
      type = types.str;
      default = lldap.settings.ldap_base_dn;
      defaultText = literalExpression "config.services.lldap.settings.ldap_base_dn";
      description = "Base DN of the directory.";
    };

    tokenFile = mkOption {
      type = types.nullOr types.str;
      default = lldapSetting "ldap_user_pass_file";
      defaultText = literalExpression "config.services.lldap.environment.LLDAP_LDAP_USER_PASS_FILE or config.services.lldap.settings.ldap_user_pass_file or null";
      example = "/run/secrets/lldap-admin-password";
      description = ''
        Runtime path to a file containing the password of `adminUser`.

        This is a path resolved on the target host (e.g. provisioned by
        sops-nix or agenix), NOT a store path: it is handed to the reconciler
        via systemd `LoadCredential=` and never copied into the Nix store.

        Defaults to the file lldap itself reads the admin password from.
        lldap reads that file only when it makes the admin user, unless
        `services.lldap.settings.force_ldap_user_pass_reset` is set. Without
        it, a changed file is a password that the provider cannot log in with.
      '';
    };
  }
  // tflib.resourceOptions;

  config = mkIf cfg.enable {
    assertions = [
      {
        assertion = lldap.enable;
        message = "services.lldap.runtime requires services.lldap.enable = true.";
      }
      {
        assertion = cfg.tokenFile != null;
        message = "services.lldap.runtime requires the admin password in a file: set services.lldap.settings.ldap_user_pass_file, services.lldap.environment.LLDAP_LDAP_USER_PASS_FILE, or services.lldap.runtime.tokenFile.";
      }
    ];

    systemd.services.declarative-lldap = tflib.mkReconcileService {
      name = "declarative-lldap";
      tfConfig = tf.config;
      inherit (tf) credentials;
      afterUnits = [ "lldap.service" ];
      # The web UI answers 200 once the server is up.
      healthUrl = cfg.baseUrl;
      inherit (cfg) tokenFile;
      # lldap runs as a dynamic user with `/var/lib/lldap` as its state
      # directory. The reconciler runs as the same dynamic user and declares
      # the same state directory, so its state sits next to lldap's data.
      # It cannot declare a state directory inside lldap's: systemd fails
      # to set that up.
      user = lldapUnit.User;
      group = lldapUnit.Group;
      dynamicUser = true;
      stateDir = "/var/lib/${lldapUnit.StateDirectory}";
      sharedStateDirMode = lldapUnit.StateDirectoryMode;
    };
  };
}
