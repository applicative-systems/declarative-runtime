# `nixTfSchema` is the schema-conversion library the resource surface is derived
# from; the flake injects it via `_module.args`, since a NixOS module cannot
# reach a flake input by path.
{
  config,
  lib,
  pkgs,
  nixTfSchema,
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
  tflib = import ./lib.nix { inherit pkgs nixTfSchema; };

  defaultBaseUrl = "http://localhost:${toString keycloak.settings.http-port}";

  # one-shot that creates the reconciler's service-account oauth2 client
  # on first boot. skipped when the operator supplies their own
  # (clientIdFile, clientSecretFile).
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
    enable = mkEnableOption "declarative keycloak runtime config, applied via OpenTofu after keycloak.service starts";

    baseUrl = mkOption {
      type = types.str;
      default = defaultBaseUrl;
      defaultText = literalExpression ''"http://localhost:''${toString config.services.keycloak.settings.http-port}"'';
      description = "Base URL of the local keycloak admin API.";
    };

    adminRealm = mkOption {
      type = types.str;
      default = "master";
      description = ''
        Realm the reconciler's service-account client lives in. The
        provider block authenticates against this realm. Defaults to
        `master`; the self-bootstrap flow only supports `master`, so
        when overriding this you must also supply `clientIdFile` /
        `clientSecretFile` for a client you've provisioned yourself.
      '';
    };

    bootstrapAdminPasswordFile = mkOption {
      type = types.nullOr types.str;
      default = null;
      example = "/run/secrets/keycloak-admin-password";
      description = ''
        Host path to a file with the master-realm admin password (the
        user `admin` by default). Read via systemd `LoadCredential=`;
        never copied into the nix store.

        Required when `clientIdFile` / `clientSecretFile` are unset --
        the bootstrap uses this admin to mint the service-account client.
        Ignored otherwise.
      '';
    };

    clientName = mkOption {
      type = types.str;
      default = "declarative-keycloak";
      description = ''
        clientId of the service-account client the bootstrap creates in
        the `master` realm. Its service-account user gets the realm-level
        `admin` role so the reconciler can manage every realm. Unused
        when `clientIdFile` / `clientSecretFile` are set directly.
      '';
    };

    clientIdFile = mkOption {
      type = types.nullOr types.str;
      default = null;
      example = "/run/secrets/keycloak-tf-client-id";
      description = ''
        Host path to a file with the oauth2 `client_id` the reconciler
        uses. Set together with `clientSecretFile` to skip the bootstrap
        and supply your own service-account client.
      '';
    };

    clientSecretFile = mkOption {
      type = types.nullOr types.str;
      default = null;
      example = "/run/secrets/keycloak-tf-client-secret";
      description = ''
        Host path to a file with the oauth2 `client_secret` paired with
        `clientIdFile`. Read via systemd `LoadCredential=`; never copied
        into the store.
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
      {
        assertion = cfg.adminRealm == "master" || cfg.clientIdFile != null;
        message = "services.keycloak.runtime: adminRealm != \"master\" requires operator-supplied clientIdFile/clientSecretFile (the self-bootstrap flow assumes master).";
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
        healthUrl = "${cfg.baseUrl}/realms/${cfg.adminRealm}";
        tokenFile = effectiveClientSecretFile;
        user = "keycloak";
        group = "keycloak";
        # upstream keycloak uses DynamicUser=true and has no state dir.
        # mkReconcileService will create /var/lib/keycloak via
        # StateDirectory= and reuse the same hashed UID as keycloak.service.
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
          # kcadm.sh writes its token cache under $HOME/.keycloak;
          # DynamicUser has no real home, so point HOME at our state dir.
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

          # wait up to 3 minutes for keycloak to come up.
          for _ in $(seq 1 90); do
            if curl -fsS -o /dev/null "${cfg.baseUrl}/realms/master"; then
              break
            fi
            sleep 2
          done

          # saved credential pair exists -- probe it against the token
          # endpoint. valid means already-bootstrapped; otherwise the
          # secret has been rotated server-side and we fall through to
          # re-fetch the current one (same client, same id).
          if [ -s "$client_id_file" ] && [ -s "$client_secret_file" ]; then
            saved_id="$(cat "$client_id_file")"
            saved_secret="$(cat "$client_secret_file")"
            if curl -fsS -o /dev/null -X POST \
                 ${lib.escapeShellArg "${cfg.baseUrl}/realms/master/protocol/openid-connect/token"} \
                 --data-urlencode 'grant_type=client_credentials' \
                 --data-urlencode "client_id=$saved_id" \
                 --data-urlencode "client_secret=$saved_secret"; then
              exit 0
            fi
            echo "saved service-account credentials no longer accepted; refreshing from keycloak admin." >&2
          fi

          kcadm.sh config credentials \
            --server ${lib.escapeShellArg cfg.baseUrl} \
            --realm master \
            --user admin \
            --password "$(cat "$CREDENTIALS_DIRECTORY/admin-password")"

          # reuse a client left over from a partial earlier bootstrap.
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

          # the master-realm `admin` role grants global admin across every
          # realm. kcadm tolerates re-grant.
          kcadm.sh add-roles -r master \
            --uid "$sa_uid" \
            --rolename admin

          client_secret="$(kcadm.sh get clients/$client_uuid/client-secret -r master \
            | jq -r .value)"

          # write tempfiles first, then rename, so the "already
          # bootstrapped" check above never sees a half-written pair.
          printf '%s' ${lib.escapeShellArg cfg.clientName} > "$client_id_file.tmp"
          printf '%s' "$client_secret"                   > "$client_secret_file.tmp"
          mv "$client_id_file.tmp"     "$client_id_file"
          mv "$client_secret_file.tmp" "$client_secret_file"
        '';
      };
    };
  };
}
