# Forgejo <-> forgejo-provider pairing.
#
# Enables the upstream `services.forgejo` module unchanged, and adds a run-once
# reconciler that applies declarative runtime state (organizations, ...) against
# the live Forgejo API once `forgejo.service` is up. Unless `tokenFile` is set,
# it also bootstraps the admin API token the reconciler needs via a companion
# oneshot (declarative-forgejo-token.service).
{
  config,
  lib,
  pkgs,
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

  cfg = config.services.forgejo.runtime;
  forgejo = config.services.forgejo;
  tflib = import ./lib.nix { inherit pkgs; };

  defaultBaseUrl = "http://localhost:${toString forgejo.settings.server.HTTP_PORT}";

  # Companion oneshot that mints the reconciler's admin API token. Only wired in
  # when the operator does not supply their own `tokenFile`.
  tokenServiceName = "declarative-forgejo-token";
  bootstrapToken = cfg.tokenFile == null;
  effectiveTokenFile =
    if bootstrapToken then "/var/lib/${tokenServiceName}/api-token" else cfg.tokenFile;

  tf = tflib.forgejoTfConfig cfg;
in
{
  options.services.forgejo.runtime = {
    enable = mkEnableOption (
      "declarative Forgejo configuration, applied via OpenTofu and the forgejo "
      + "provider after forgejo.service starts"
    );

    baseUrl = mkOption {
      type = types.str;
      default = defaultBaseUrl;
      defaultText = literalExpression ''"http://localhost:''${toString config.services.forgejo.settings.server.HTTP_PORT}"'';
      description = "Base URL of the local Forgejo API the provider targets.";
    };

    tokenFile = mkOption {
      type = types.nullOr types.str;
      default = null;
      example = "/run/secrets/forgejo-admin-token";
      description = ''
        Runtime path to a file containing a Forgejo admin API token with scope
        to manage the declared resources.

        This is a path resolved on the target host (e.g. provisioned by
        sops-nix or agenix), NOT a store path: it is handed to the reconciler
        via systemd `LoadCredential=` and never copied into the Nix store.

        When null (the default), the pairing bootstraps its own token: a
        companion oneshot creates the `adminUsername` admin account (if absent)
        and mints a scoped token, persisted under /var/lib and reused across
        reboots.
      '';
    };

    adminUsername = mkOption {
      type = types.str;
      default = "declarative-forgejo";
      description = ''
        Admin account the token-bootstrap oneshot creates and mints its token
        for. Unused when `tokenFile` is set.
      '';
    };
  }
  // tflib.resourceOptions;

  config = mkIf cfg.enable {
    assertions = [
      {
        assertion = forgejo.enable;
        message = "services.forgejo.runtime requires services.forgejo.enable = true.";
      }
    ];

    systemd.services = {
      declarative-forgejo = tflib.mkReconcileService {
        name = "declarative-forgejo";
        tfConfig = tf.config;
        inherit (tf) credentials;
        afterUnits = [ "forgejo.service" ] ++ lib.optional bootstrapToken "${tokenServiceName}.service";
        healthUrl = "${cfg.baseUrl}/api/healthz";
        tokenFile = effectiveTokenFile;
        inherit (forgejo) user group stateDir;
      };
    }
    // lib.optionalAttrs bootstrapToken {
      ${tokenServiceName} = {
        description = "Bootstrap the declarative-forgejo admin API token";
        after = [ "forgejo.service" ];
        requires = [ "forgejo.service" ];
        path = [
          forgejo.package
          pkgs.gnugrep
        ];
        environment = {
          HOME = forgejo.stateDir;
          FORGEJO_WORK_DIR = forgejo.stateDir;
          FORGEJO_CUSTOM = forgejo.customDir;
        };
        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
          User = forgejo.user;
          Group = forgejo.group;
          StateDirectory = tokenServiceName;
          StateDirectoryMode = "0700";
        };
        script = ''
          set -euo pipefail

          token_file="$STATE_DIRECTORY/api-token"

          # Mint one admin token with the maximal "all" scope. Because its scope
          # does not depend on which resources are declared, it never needs
          # re-scoping as the config grows and is minted exactly once: the
          # persisted token is the "already bootstrapped" marker, and /var/lib
          # survives reboots.
          #
          # This deliberately forgoes least privilege. Widening a narrow token in
          # place is impossible on Forgejo < 16 -- token CRUD needs basic auth and
          # there is no admin token API -- so a least-privilege token could only
          # grow by minting a replacement and orphaning the old one. Forgejo >= 16
          # adds DELETE/POST /api/v1/admin/users/{user}/tokens usable by a
          # write:admin token (PR #12323, v16.0.0); once on it, request
          # `tflib.requiredScopes cfg` + write:admin and re-mint cleanly on scope
          # change. requiredScopes is kept in lib.nix for that.
          if [ -s "$token_file" ]; then
            exit 0
          fi

          # Ensure the dedicated admin account exists. Tolerate an account left
          # over from an earlier bootstrap (e.g. the token file removed by hand).
          if ! err="$(forgejo admin user create \
              --admin --username ${lib.escapeShellArg cfg.adminUsername} \
              --email ${lib.escapeShellArg "${cfg.adminUsername}@localhost"} \
              --random-password --random-password-length 32 \
              --must-change-password=false 2>&1)"; then
            printf '%s\n' "$err" | grep -qi 'already exist' || {
              printf '%s\n' "$err" >&2
              exit 1
            }
          fi

          # Mint the token (raw = value only) and persist it 0600. The reconciler
          # reads it via LoadCredential as root, so a forgejo-owned 0600 file is
          # fine.
          umask 077
          forgejo admin user generate-access-token \
            --username ${lib.escapeShellArg cfg.adminUsername} \
            --token-name declarative-forgejo \
            --scopes all \
            --raw > "$token_file"
        '';
      };
    };
  };
}
