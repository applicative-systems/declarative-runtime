# Keycloak <-> keycloak/keycloak provider pairing.
#
# Enables the upstream `services.keycloak` module unchanged, and adds a
# run-once reconciler that applies declarative runtime state (realms, ...)
# against the live Keycloak admin API once `keycloak.service` is up. Unless
# `clientIdFile` and `clientSecretFile` are both supplied, a companion
# oneshot (`declarative-keycloak-bootstrap.service`) mints a dedicated
# service-account OIDC client in the `master` realm and grants it
# `realm-admin` on the `realm-management` client; the reconciler then
# authenticates via OAuth2 client-credentials grant. The bootstrap relies
# on the operator providing the master-realm admin's password via
# `bootstrapAdminPasswordFile` (read with systemd `LoadCredential=`,
# never copied into the world-readable Nix store).
#
# Upstream Keycloak uses `DynamicUser=true` with no persistent state dir;
# the reconciler enables the corresponding mode of mkReconcileService so it
# is allocated the same hashed `keycloak` UID as `keycloak.service` and
# writes Terraform state into `/var/lib/keycloak/declarative-terraform`
# via systemd `StateDirectory=`.
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

  cfg = config.services.keycloak.runtime;
  keycloak = config.services.keycloak;
  tflib = import ./lib.nix { inherit pkgs; };

  defaultBaseUrl = "http://localhost:${toString keycloak.settings.http-port}";

  # Companion oneshot that mints the reconciler's service-account OIDC
  # client. Only wired in when the operator does not supply their own
  # (clientIdFile, clientSecretFile) pair.
  bootstrapServiceName = "declarative-keycloak-bootstrap";
  bootstrapClient = cfg.clientIdFile == null;
  effectiveClientIdFile =
    if bootstrapClient then "/var/lib/${bootstrapServiceName}/client_id" else cfg.clientIdFile;
  effectiveClientSecretFile =
    if bootstrapClient then "/var/lib/${bootstrapServiceName}/client_secret" else cfg.clientSecretFile;

  tf = tflib.keycloakTfConfig cfg;
in
{
  options.services.keycloak.runtime = {
    enable = mkEnableOption (
      "declarative Keycloak configuration, applied via OpenTofu and the keycloak/keycloak "
      + "provider after keycloak.service starts"
    );

    baseUrl = mkOption {
      type = types.str;
      default = defaultBaseUrl;
      defaultText = literalExpression ''"http://localhost:''${toString config.services.keycloak.settings.http-port}"'';
      description = "Base URL of the local Keycloak admin API the provider targets.";
    };

    bootstrapAdminPasswordFile = mkOption {
      type = types.nullOr types.str;
      default = null;
      example = "/run/secrets/keycloak-admin-password";
      description = ''
        Host path to a file containing the password of an existing
        realm-admin user (default `admin`) in the `master` realm. The
        path is resolved on the target host (e.g. provisioned by sops-nix
        or agenix), NOT a store path: it is handed to the bootstrap
        oneshot via systemd `LoadCredential=` and never copied into the
        Nix store.

        Required when `clientIdFile`/`clientSecretFile` are unset (the
        default), since the bootstrap uses this admin to mint a dedicated
        service-account client. Ignored when both are supplied.
      '';
    };

    clientName = mkOption {
      type = types.str;
      default = "declarative-keycloak";
      description = ''
        Service-account client `clientId` the bootstrap oneshot creates
        in the `master` realm. The matching service-account user is
        granted the `realm-admin` role of the `realm-management` client
        so the reconciler can manage every realm. Unused when
        `clientIdFile`/`clientSecretFile` are set directly.
      '';
    };

    clientIdFile = mkOption {
      type = types.nullOr types.str;
      default = null;
      example = "/run/secrets/keycloak-tf-client-id";
      description = ''
        Host path to a file containing the OIDC `client_id` the
        reconciler authenticates as. Set together with `clientSecretFile`
        to bypass the bootstrap and supply your own service-account
        client.
      '';
    };

    clientSecretFile = mkOption {
      type = types.nullOr types.str;
      default = null;
      example = "/run/secrets/keycloak-tf-client-secret";
      description = ''
        Host path to a file containing the OIDC `client_secret` paired
        with `clientIdFile`. Read via systemd `LoadCredential=`, never
        copied into the store.
      '';
    };
  }
  // tflib.resourceOptions;

  config = mkIf cfg.enable {
    assertions = [
      {
        assertion = keycloak.enable;
        message = "services.keycloak.runtime requires services.keycloak.enable = true.";
      }
      {
        assertion = (cfg.clientIdFile == null) == (cfg.clientSecretFile == null);
        message = "services.keycloak.runtime: set both clientIdFile and clientSecretFile, or neither (self-bootstrap).";
      }
      {
        assertion = (cfg.clientIdFile != null) || (cfg.bootstrapAdminPasswordFile != null);
        message = "services.keycloak.runtime: when no client credentials are supplied, bootstrapAdminPasswordFile is required to mint them.";
      }
    ];

    systemd.services = {
      declarative-keycloak = tflib.mkReconcileService {
        name = "declarative-keycloak";
        tfConfig = tf.config;
        credentials = tf.credentials // {
          ${tflib.clientIdVar} = effectiveClientIdFile;
        };
        afterUnits = [
          "keycloak.service"
        ]
        ++ lib.optional bootstrapClient "${bootstrapServiceName}.service";
        healthUrl = "${cfg.baseUrl}/realms/master";
        tokenFile = effectiveClientSecretFile;
        user = "keycloak";
        group = "keycloak";
        # Upstream keycloak runs as DynamicUser=true with no persistent
        # state dir; allocate a dedicated one owned by the same hashed UID
        # via systemd StateDirectory= (derived by mkReconcileService from
        # stateDir, which must live under /var/lib for that derivation).
        stateDir = "/var/lib/keycloak";
        dynamicUser = true;
      };
    }
    // lib.optionalAttrs bootstrapClient {
      ${bootstrapServiceName} = {
        description = "Bootstrap the declarative-keycloak service-account OIDC client";
        after = [ "keycloak.service" ];
        requires = [ "keycloak.service" ];
        wantedBy = [ "multi-user.target" ];
        path = [
          keycloak.package
          pkgs.curl
          pkgs.jq
          pkgs.coreutils
        ];
        environment = {
          # kcadm.sh stashes its token cache under $HOME/.keycloak; under
          # DynamicUser there is no real home, so direct it into the
          # StateDirectory (writable and owned by the same hashed UID).
          HOME = "/var/lib/${bootstrapServiceName}";
        };
        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
          DynamicUser = true;
          User = "keycloak";
          Group = "keycloak";
          StateDirectory = bootstrapServiceName;
          StateDirectoryMode = "0700";
          LoadCredential = [ "admin-password:${cfg.bootstrapAdminPasswordFile}" ];
        };
        script = ''
          set -euo pipefail
          umask 077

          client_id_file="$STATE_DIRECTORY/client_id"
          client_secret_file="$STATE_DIRECTORY/client_secret"

          # Mint-once: the persisted credential pair is the "already
          # bootstrapped" marker. /var/lib survives reboots, so this oneshot
          # is no-op on every boot after the first successful run.
          if [ -s "$client_id_file" ] && [ -s "$client_secret_file" ]; then
            exit 0
          fi

          # `After=keycloak.service` waits for the Type=notify ready flag,
          # but Quarkus keeps initialising for tens of seconds past that;
          # poll the admin endpoint explicitly before talking to kcadm.
          for _ in $(seq 1 90); do
            if curl -fsS -o /dev/null "${cfg.baseUrl}/realms/master"; then
              break
            fi
            sleep 2
          done

          kcadm.sh config credentials \
            --server ${lib.escapeShellArg cfg.baseUrl} \
            --realm master \
            --user admin \
            --password "$(cat "$CREDENTIALS_DIRECTORY/admin-password")"

          # Tolerate a client left over from a partial earlier bootstrap.
          existing_uuid="$(kcadm.sh get clients -r master \
            -q clientId=${lib.escapeShellArg cfg.clientName} \
            | jq -r '.[0].id // empty')"
          if [ -n "$existing_uuid" ]; then
            client_uuid="$existing_uuid"
          else
            client_uuid="$(kcadm.sh create clients -r master \
              -s clientId=${lib.escapeShellArg cfg.clientName} \
              -s protocol=openid-connect \
              -s serviceAccountsEnabled=true \
              -s publicClient=false \
              -s standardFlowEnabled=false \
              -s directAccessGrantsEnabled=false \
              -s implicitFlowEnabled=false \
              -s enabled=true \
              -i)"
          fi

          sa_uid="$(kcadm.sh get clients/$client_uuid/service-account-user -r master \
            | jq -r .id)"

          # The master realm's realm-level `admin` is a composite role that
          # grants global admin across every realm; assigning it to the
          # service-account user gives the reconciler full reach.
          # Idempotent: kcadm tolerates re-grant.
          kcadm.sh add-roles -r master \
            --uid "$sa_uid" \
            --rolename admin

          client_secret="$(kcadm.sh get clients/$client_uuid/client-secret -r master \
            | jq -r .value)"

          # Atomic write: rename only succeeds once both tempfiles exist, so
          # the idempotency check above never observes a half-written pair.
          printf '%s' ${lib.escapeShellArg cfg.clientName} > "$client_id_file.tmp"
          printf '%s' "$client_secret"                   > "$client_secret_file.tmp"
          mv "$client_id_file.tmp"     "$client_id_file"
          mv "$client_secret_file.tmp" "$client_secret_file"
        '';
      };
    };
  };
}
