# FIXME this only provisions keycloak_realm resources for now
{ pkgs }:
let
  inherit (pkgs) lib;
  genlib = import ../../modules/lib { inherit pkgs; };
  inherit (genlib) tfLabel;

  provider = pkgs.terraform-providers.keycloak_keycloak;
  providerVersion = provider.version;

  # credential names for the (less privileged) keycloak provisioner
  tokenVar = "keycloak_client_secret";
  clientIdVar = "keycloak_client_id";

  executor = pkgs.opentofu.withPlugins (_: [ provider ]);

  ty = lib.types;

  # o* for optional, r* for required
  oStr =
    description:
    lib.mkOption {
      type = ty.nullOr ty.str;
      default = null;
      inherit description;
    };
  oBool =
    description:
    lib.mkOption {
      type = ty.nullOr ty.bool;
      default = null;
      inherit description;
    };
  oInt =
    description:
    lib.mkOption {
      type = ty.nullOr ty.int;
      default = null;
      inherit description;
    };
  oListStr =
    description:
    lib.mkOption {
      type = ty.nullOr (ty.listOf ty.str);
      default = null;
      inherit description;
    };
  oAttrsStr =
    description:
    lib.mkOption {
      type = ty.nullOr (ty.attrsOf ty.str);
      default = null;
      inherit description;
    };
  rStr =
    description:
    lib.mkOption {
      type = ty.str;
      inherit description;
    };
  rBool =
    description:
    lib.mkOption {
      type = ty.bool;
      inherit description;
    };

  # ref spec shared by almost every non-realm resource: realm_id is a numeric
  # id the user can't know, so it must resolve to a managed realm by key.
  realmRef = {
    attr = "realm_id";
    targets = [
      {
        collection = "realms";
        field = "id";
      }
    ];
    managedOnly = true;
    required = true;
    description = "Key of the managed realm (services.keycloak.runtime.realms.<name>) this belongs to.";
  };

  # The full keycloak/keycloak resource surface. Per
  # resource:
  #   type            the `keycloak_*` resource type
  #   prefix          unique Terraform label prefix
  #   nameAttr        attribute defaulted from the collection key (or null)
  #   scope           reserved for future per-resource scoping; null under
  #                   client-credentials auth
  #   refs            parent links resolved to references against managed
  #                   siblings
  #   secrets         secret-valued attributes gaining an `<attr>File` form
  #   requiredSecrets secrets the provider requires (one of `<attr>`/`<attr>File`)
  #   attrs           the settable attributes, each a typed option (no
  #                   freeform)
  resourceTypes = {
    realms = {
      type = "keycloak_realm";
      prefix = "realm";
      nameAttr = "realm";
      scope = null;
      refs = { };
      description = "Keycloak realms, keyed by realm name.";
      attrs = {
        realm = oStr "Realm name. Defaults to the attribute key.";
        enabled = oBool "Is the realm enabled?";
        display_name = oStr "User-facing display name.";
        display_name_html = oStr "HTML-formatted display name.";

        # general
        user_managed_access = oBool "Enable user-managed access.";
        organizations_enabled = oBool "Enable the organizations feature.";
        admin_permissions_enabled = oBool "Enable the v2 admin permissions feature.";
        terraform_deletion_protection = oBool "Refuse to destroy the realm on `tofu destroy`.";
        attributes = oAttrsStr "Free-form realm attribute map.";

        # login config
        registration_allowed = oBool "Allow self-registration.";
        registration_email_as_username = oBool "Use email as username on registration.";
        edit_username_allowed = oBool "Allow users to edit their username.";
        reset_password_allowed = oBool "Allow users to reset their password.";
        remember_me = oBool "Offer the \"Remember Me\" checkbox on login.";
        verify_email = oBool "Require email verification.";
        login_with_email_allowed = oBool "Allow login with email.";
        duplicate_emails_allowed = oBool "Allow duplicate emails across users.";
        ssl_required = oStr "SSL required: 'none', 'external' (default), or 'all'.";

        # themes
        login_theme = oStr "Login theme.";
        account_theme = oStr "Account console theme.";
        admin_theme = oStr "Admin console theme.";
        email_theme = oStr "Email theme.";

        # tokens
        default_signature_algorithm = oStr "Default JWS signing algorithm.";
        revoke_refresh_token = oBool "Revoke refresh tokens on use.";
        refresh_token_max_reuse = oInt "Max number of times a refresh token can be reused.";
        sso_session_idle_timeout = oStr "SSO session idle timeout (duration string, e.g. \"30m\").";
        sso_session_idle_timeout_remember_me = oStr "SSO session idle timeout for \"Remember Me\" sessions.";
        sso_session_max_lifespan = oStr "SSO session max lifespan.";
        sso_session_max_lifespan_remember_me = oStr "SSO session max lifespan for \"Remember Me\" sessions.";
        offline_session_idle_timeout = oStr "Offline session idle timeout.";
        offline_session_max_lifespan = oStr "Offline session max lifespan.";
        offline_session_max_lifespan_enabled = oBool "Cap offline sessions to `offline_session_max_lifespan`.";
        client_session_idle_timeout = oStr "Client session idle timeout (falls back to SSO idle).";
        client_session_max_lifespan = oStr "Client session max lifespan (falls back to SSO max).";
        access_token_lifespan = oStr "Access token lifespan.";
        access_token_lifespan_for_implicit_flow = oStr "Access token lifespan for the implicit flow.";
        access_code_lifespan = oStr "Auth code lifespan.";
        access_code_lifespan_login = oStr "Login-action code lifespan.";
        access_code_lifespan_user_action = oStr "User-action code lifespan.";
        action_token_generated_by_user_lifespan = oStr "Lifespan of user-generated action tokens.";
        action_token_generated_by_admin_lifespan = oStr "Lifespan of admin-generated action tokens.";
        oauth2_device_code_lifespan = oStr "OAuth2 device-code lifespan.";
        oauth2_device_polling_interval = oInt "OAuth2 device-code polling interval (seconds).";

        # authentication
        password_policy = oStr "Password policy string (e.g. \"upperCase(1) and length(8) and notUsername(undefined)\").";

        # authentication flow bindings (alias of a flow defined in the realm)
        browser_flow = oStr "Authentication flow alias bound to the browser flow.";
        registration_flow = oStr "Authentication flow alias bound to the registration flow.";
        direct_grant_flow = oStr "Authentication flow alias bound to the direct-grant flow.";
        reset_credentials_flow = oStr "Authentication flow alias bound to the reset-credentials flow.";
        client_authentication_flow = oStr "Authentication flow alias bound to the client-auth flow.";
        docker_authentication_flow = oStr "Authentication flow alias bound to the docker-auth flow.";
        first_broker_login_flow = oStr "Authentication flow alias bound to the first-broker-login flow.";

        # default client scopes (referenced by name)
        default_default_client_scopes = oListStr "Default client scopes auto-granted to new clients.";
        default_optional_client_scopes = oListStr "Optional client scopes available to new clients.";
      };
    };

    roles = {
      type = "keycloak_role";
      prefix = "role";
      nameAttr = "name";
      scope = null;
      refs.realm = realmRef;
      # client_id ref (-> keycloak_openid_client) lands when openid_clients do.
      description = "Keycloak roles (realm-level by default), keyed by role name.";
      attrs = {
        name = oStr "Role name. Defaults to the attribute key.";
        description = oStr "Role description.";
        # opaque list: users supply role UUIDs or ${keycloak_role.X.id}
        # interpolations directly. Managed list-refs land later.
        composite_roles = oListStr "Role UUIDs (or `\${keycloak_role.X.id}` refs) the composite includes.";
        attributes = oAttrsStr "Free-form role attribute map.";
      };
    };

    default_roles = {
      type = "keycloak_default_roles";
      prefix = "default_roles";
      nameAttr = null;
      scope = null;
      refs.realm = realmRef;
      requiredAttrs = [ "default_roles" ];
      description = "Realm-level default roles auto-granted to new users, keyed by an arbitrary label.";
      attrs = {
        default_roles = oListStr "Role names auto-granted to every new user of the realm.";
      };
    };
  };

  # generate nixos options for resources from resourceTypes
  resourceOptions = lib.mapAttrs (
    _: spec:
    lib.mkOption {
      type = lib.types.attrsOf (
        lib.types.submodule {
          options =
            (spec.attrs or { })
            // lib.mapAttrs (
              _: refSpec:
              if refSpec.required or false then
                lib.mkOption {
                  type = lib.types.str;
                  description = refSpec.description;
                }
              else
                lib.mkOption {
                  type = lib.types.nullOr lib.types.str;
                  default = null;
                  description = refSpec.description;
                }
            ) spec.refs
            // lib.listToAttrs (
              map (
                attr:
                lib.nameValuePair "${attr}File" (
                  lib.mkOption {
                    type = lib.types.nullOr lib.types.str;
                    default = null;
                    description = "Runtime path to a file holding `${attr}` (loaded via systemd LoadCredential=; never copied to the store). Mutually exclusive with a literal `${attr}`.";
                  }
                )
              ) (spec.secrets or [ ])
            );
        }
      );
      default = { };
      description = spec.description;
    }
  ) resourceTypes;

  # remove null-valued and _module attributes
  cleanNulls =
    v:
    if builtins.isAttrs v then
      lib.mapAttrs (_: cleanNulls) (lib.filterAttrs (_: x: x != null) (removeAttrs v [ "_module" ]))
    else if builtins.isList v then
      map cleanNulls v
    else
      v;

  # build JSON config and credential map (id -> host path)
  # secrets are provided at apply time
  keycloakTfConfig =
    cfg:
    let
      # Var-safe id (Terraform variable name + LoadCredential id) for a secret.
      varSafe = lib.stringAsChars (c: if builtins.match "[A-Za-z0-9_]" c != null then c else "_");
      secretId =
        spec: key: attr:
        "secret_${spec.prefix}_${varSafe key}_${attr}";

      resolveRef =
        refSpec: val:
        let
          tryTarget =
            t:
            let
              tspec = resourceTypes.${t.collection};
            in
            if (cfg.${t.collection} or { }) ? ${val} then
              "\${" + tspec.type + "." + tfLabel tspec.prefix val + "." + t.field + "}"
            else
              null;
          hits = builtins.filter (x: x != null) (map tryTarget refSpec.targets);
        in
        if hits != [ ] then
          builtins.head hits
        else if refSpec.managedOnly then
          throw "services.keycloak.runtime: reference '${val}' does not match any managed ${
            lib.concatMapStringsSep " or " (t: t.collection) refSpec.targets
          }"
        else
          val;

      # Host-file-sourced secrets of one item: [{ attr; id; path; }]. Throws if
      # both the literal attribute and its `<attr>File` are set.
      itemSecrets =
        c: spec: key: item:
        lib.concatMap (
          attr:
          let
            file = item.${attr + "File"} or null;
          in
          lib.optionals (file != null) (
            if (item.${attr} or null) != null then
              throw "services.keycloak.runtime.${c}.${key}: set either '${attr}' or '${attr}File', not both"
            else
              [
                {
                  inherit attr;
                  id = secretId spec key attr;
                  path = file;
                }
              ]
          )
        ) (spec.secrets or [ ]);

      renderItem =
        c: spec: key: item:
        let
          secretEntries = itemSecrets c spec key item;
          virtuals = builtins.attrNames spec.refs ++ map (s: "${s}File") (spec.secrets or [ ]);
          base = removeAttrs item ([ "_module" ] ++ virtuals);
          nameInject = lib.optionalAttrs (spec.nameAttr != null && (item.${spec.nameAttr} or null) == null) {
            ${spec.nameAttr} = key;
          };
          refAttrs = lib.concatMapAttrs (
            refName: refSpec:
            lib.optionalAttrs (item.${refName} or null != null) {
              ${refSpec.attr} = resolveRef refSpec item.${refName};
            }
          ) spec.refs;
          secretAttrs = lib.listToAttrs (map (e: lib.nameValuePair e.attr "\${var.${e.id}}") secretEntries);
          # A required secret must be supplied via either the literal or its file.
          reqSecretChecks = map (
            attr:
            if (item.${attr} or null) == null && (item.${attr + "File"} or null) == null then
              throw "services.keycloak.runtime.${c}.${key}: set either '${attr}' or '${attr}File' (required)"
            else
              null
          ) (spec.requiredSecrets or [ ]);
          # Required map/list attributes: the module system gives `attrsOf`/
          # `listOf` an empty-value default ({}/[]) rather than treating a
          # missing value as undefined, so a "required" collection is enforced
          # here.
          reqAttrChecks = map (
            attr:
            let
              v = item.${attr} or null;
            in
            if v == null || v == { } || v == [ ] then
              throw "services.keycloak.runtime.${c}.${key}: '${attr}' is required and must be non-empty"
            else
              null
          ) (spec.requiredAttrs or [ ]);
        in
        # use deepSeq to force evaluation of checks
        # (these are not config.assertions so they can be used outside a nixos system build)
        lib.nameValuePair (tfLabel spec.prefix key) (
          builtins.deepSeq [ reqSecretChecks reqAttrChecks ] (
            cleanNulls (base // nameInject // refAttrs // secretAttrs)
          )
        );

      nonEmpty = lib.filterAttrs (c: _: (cfg.${c} or { }) != { }) resourceTypes;
      resourceBlocks = lib.mapAttrs' (
        c: spec: lib.nameValuePair spec.type (lib.mapAttrs' (renderItem c spec) cfg.${c})
      ) nonEmpty;

      # combine sensitive variables with (id -> host path) credential map
      allSecrets = lib.concatLists (
        lib.mapAttrsToList (
          c: spec: lib.concatLists (lib.mapAttrsToList (key: item: itemSecrets c spec key item) cfg.${c})
        ) nonEmpty
      );
      secretIds = map (e: e.id) allSecrets;

      config = {
        terraform.required_providers.keycloak = {
          source = "keycloak/keycloak";
          version = providerVersion;
        };
        variable = {
          ${tokenVar} = {
            type = "string";
            sensitive = true;
          };
          ${clientIdVar} = {
            type = "string";
            sensitive = true;
          };
        }
        // lib.listToAttrs (
          map (
            e:
            lib.nameValuePair e.id {
              type = "string";
              sensitive = true;
            }
          ) allSecrets
        );
        provider.keycloak = {
          url = cfg.baseUrl;
          realm = "master";
          client_id = "\${var.${clientIdVar}}";
          client_secret = "\${var.${tokenVar}}";
        };
      }
      // lib.optionalAttrs (resourceBlocks != { }) { resource = resourceBlocks; };

      credentials =
        if lib.length secretIds != lib.length (lib.unique secretIds) then
          throw "services.keycloak.runtime: secret credential id collision (${toString secretIds}); rename the colliding resource keys"
        else
          lib.listToAttrs (map (e: lib.nameValuePair e.id e.path) allSecrets);
    in
    {
      inherit config credentials;
    };
in
{
  inherit
    resourceTypes
    resourceOptions
    keycloakTfConfig
    clientIdVar
    ;

  mkReconcileService = args: genlib.mkReconcileService (args // { inherit executor tokenVar; });
}
