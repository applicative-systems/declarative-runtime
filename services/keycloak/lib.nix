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

  # optional refs to a managed openid_client / openid_client_scope, used by
  # all openid protocol mappers (mutually exclusive at the provider).
  openidClientOptionalRef = {
    attr = "client_id";
    targets = [
      {
        collection = "openid_clients";
        field = "id";
      }
    ];
    managedOnly = true;
    required = false;
    description = "Optional managed OpenID client this mapper attaches to.";
  };
  openidClientScopeOptionalRef = {
    attr = "client_scope_id";
    targets = [
      {
        collection = "openid_client_scopes";
        field = "id";
      }
    ];
    managedOnly = true;
    required = false;
    description = "Optional managed OpenID client scope this mapper attaches to.";
  };
  # the four common openid-mapper attrs (every mapper has at least the first 3)
  openidMapperCommonAttrs = {
    name = oStr "Mapper name. Defaults to the attribute key.";
    add_to_id_token = oBool "Include in ID token?";
    add_to_access_token = oBool "Include in access token?";
    add_to_userinfo = oBool "Include in UserInfo?";
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

    groups = {
      type = "keycloak_group";
      prefix = "group";
      nameAttr = "name";
      scope = null;
      refs = {
        realm = realmRef;
        parent = {
          attr = "parent_id";
          targets = [
            {
              collection = "groups";
              field = "id";
            }
          ];
          managedOnly = true;
          required = false;
          description = "Optional parent group (key of another managed group) for nested groups.";
        };
      };
      description = "Keycloak groups, keyed by group name.";
      attrs = {
        name = oStr "Group name. Defaults to the attribute key.";
        description = oStr "Group description.";
        attributes = oAttrsStr "Free-form group attribute map.";
      };
    };

    default_groups = {
      type = "keycloak_default_groups";
      prefix = "default_groups";
      nameAttr = null;
      scope = null;
      refs.realm = realmRef;
      requiredAttrs = [ "group_ids" ];
      description = "Realm-level default groups auto-joined by new users, keyed by an arbitrary label.";
      attrs = {
        # opaque list: users supply group UUIDs or ${keycloak_group.X.id}
        # interpolations directly. Managed list-refs land later.
        group_ids = oListStr "Group UUIDs (or `\${keycloak_group.X.id}` refs) new users auto-join.";
      };
    };

    group_memberships = {
      type = "keycloak_group_memberships";
      prefix = "group_membership";
      nameAttr = null;
      scope = null;
      refs = {
        realm = realmRef;
        group = {
          attr = "group_id";
          targets = [
            {
              collection = "groups";
              field = "id";
            }
          ];
          managedOnly = true;
          required = true;
          description = "Key of the managed group (services.keycloak.runtime.groups.<name>) the members are added to.";
        };
      };
      requiredAttrs = [ "members" ];
      description = "Keycloak group memberships, keyed by an arbitrary label.";
      attrs = {
        members = oListStr "Usernames of users to add to the group.";
      };
    };

    group_roles = {
      type = "keycloak_group_roles";
      prefix = "group_roles";
      nameAttr = null;
      scope = null;
      refs = {
        realm = realmRef;
        group = {
          attr = "group_id";
          targets = [
            {
              collection = "groups";
              field = "id";
            }
          ];
          managedOnly = true;
          required = true;
          description = "Key of the managed group (services.keycloak.runtime.groups.<name>) to assign roles to.";
        };
      };
      requiredAttrs = [ "role_ids" ];
      description = "Role assignments for a group, keyed by an arbitrary label.";
      attrs = {
        role_ids = oListStr "Role UUIDs (or `\${keycloak_role.X.id}` refs) granted to the group.";
        exhaustive = oBool "If true, only the listed roles remain assigned; if false, listed roles are added without removing others.";
      };
    };

    users = {
      type = "keycloak_user";
      prefix = "user";
      nameAttr = "username";
      scope = null;
      refs.realm = realmRef;
      requiredAttrs = [ "username" ];
      # initial_password / federated_identity are nested blocks with a Sensitive
      # `value`; they need <attr>File support for nested attrs and land later.
      description = "Keycloak users, keyed by username (must be lowercase).";
      attrs = {
        username = oStr "Username (lowercase). Defaults to the attribute key.";
        email = oStr "Email address.";
        email_verified = oBool "Has the user verified their email?";
        first_name = oStr "First name.";
        last_name = oStr "Last name.";
        enabled = oBool "Is the user enabled?";
        attributes = oAttrsStr "Free-form user attribute map.";
        required_actions = oListStr "Required actions on next login (e.g. \"VERIFY_EMAIL\", \"UPDATE_PASSWORD\").";
      };
    };

    user_roles = {
      type = "keycloak_user_roles";
      prefix = "user_roles";
      nameAttr = null;
      scope = null;
      refs = {
        realm = realmRef;
        user = {
          attr = "user_id";
          targets = [
            {
              collection = "users";
              field = "id";
            }
          ];
          managedOnly = true;
          required = true;
          description = "Key of the managed user (services.keycloak.runtime.users.<name>) to assign roles to.";
        };
      };
      requiredAttrs = [ "role_ids" ];
      description = "Role assignments for a user, keyed by an arbitrary label.";
      attrs = {
        role_ids = oListStr "Role UUIDs (or `\${keycloak_role.X.id}` refs) granted to the user.";
        exhaustive = oBool "If true, only the listed roles remain assigned; otherwise the listed roles are added without removing others.";
      };
    };

    user_groups = {
      type = "keycloak_user_groups";
      prefix = "user_groups";
      nameAttr = null;
      scope = null;
      refs = {
        realm = realmRef;
        user = {
          attr = "user_id";
          targets = [
            {
              collection = "users";
              field = "id";
            }
          ];
          managedOnly = true;
          required = true;
          description = "Key of the managed user (services.keycloak.runtime.users.<name>) to add to groups.";
        };
      };
      requiredAttrs = [ "group_ids" ];
      description = "Group memberships for a user, keyed by an arbitrary label.";
      attrs = {
        group_ids = oListStr "Group UUIDs (or `\${keycloak_group.X.id}` refs) the user joins.";
        exhaustive = oBool "If true, only the listed groups remain joined; otherwise the listed groups are added without removing others.";
      };
    };

    openid_client_scopes = {
      type = "keycloak_openid_client_scope";
      prefix = "openid_client_scope";
      nameAttr = "name";
      scope = null;
      refs.realm = realmRef;
      description = "OpenID client scopes (per-realm), keyed by scope name.";
      attrs = {
        name = oStr "Scope name. Defaults to the attribute key.";
        description = oStr "Scope description.";
        consent_screen_text = oStr "Text shown on the consent screen.";
        include_in_token_scope = oBool "Include the scope name in the issued token's `scope` claim?";
        gui_order = oInt "Display order in the admin UI.";
        extra_config = oAttrsStr "Free-form extra config entries the upstream attribute set does not cover.";
      };
    };

    saml_client_scopes = {
      type = "keycloak_saml_client_scope";
      prefix = "saml_client_scope";
      nameAttr = "name";
      scope = null;
      refs.realm = realmRef;
      description = "SAML client scopes (per-realm), keyed by scope name.";
      attrs = {
        name = oStr "Scope name. Defaults to the attribute key.";
        description = oStr "Scope description.";
        consent_screen_text = oStr "Text shown on the consent screen.";
        gui_order = oInt "Display order in the admin UI.";
        extra_config = oAttrsStr "Free-form extra config entries the upstream attribute set does not cover.";
      };
    };

    openid_clients = {
      type = "keycloak_openid_client";
      prefix = "openid_client";
      nameAttr = "client_id";
      scope = null;
      refs.realm = realmRef;
      secrets = [ "client_secret" ];
      # Skips nested blocks (authorization, authentication_flow_binding_overrides)
      # and write-only secret variants (client_secret_wo) -- those need
      # nested-block / write-only renderer extensions and land separately.
      description = "OpenID Connect clients (per-realm), keyed by clientId.";
      attrs = {
        client_id = oStr "OAuth2 clientId. Defaults to the attribute key.";
        name = oStr "Display name.";
        description = oStr "Client description.";
        enabled = oBool "Is the client enabled?";
        access_type = oStr "Access type: 'CONFIDENTIAL', 'PUBLIC', or 'BEARER-ONLY'.";

        client_secret = oStr "Client secret. Prefer `client_secretFile` to keep it out of the world-readable store.";
        client_authenticator_type = oStr "Client authenticator type (default 'client-secret').";

        standard_flow_enabled = oBool "Enable the standard (authorization code) flow.";
        implicit_flow_enabled = oBool "Enable the implicit flow.";
        direct_access_grants_enabled = oBool "Enable direct-access (password) grants.";
        service_accounts_enabled = oBool "Enable a service account for client-credentials grants.";
        frontchannel_logout_enabled = oBool "Enable front-channel logout.";

        valid_redirect_uris = oListStr "Valid redirect URIs (sets/wildcards allowed).";
        valid_post_logout_redirect_uris = oListStr "Valid post-logout redirect URIs.";
        web_origins = oListStr "Allowed CORS origins.";

        root_url = oStr "Root URL.";
        admin_url = oStr "Admin URL.";
        base_url = oStr "Base URL.";
        login_theme = oStr "Per-client login theme.";

        pkce_code_challenge_method = oStr "PKCE code-challenge method (e.g. 'S256').";
        require_dpop_bound_tokens = oBool "Require DPoP-bound tokens.";

        access_token_lifespan = oStr "Override realm-level access token lifespan.";
        client_offline_session_idle_timeout = oStr "Override realm-level offline-session idle timeout.";
        client_offline_session_max_lifespan = oStr "Override realm-level offline-session max lifespan.";
        client_session_idle_timeout = oStr "Override realm-level client-session idle timeout.";
        client_session_max_lifespan = oStr "Override realm-level client-session max lifespan.";

        exclude_session_state_from_auth_response = oBool "Exclude session_state from auth responses.";
        exclude_issuer_from_auth_response = oBool "Exclude issuer from auth responses.";

        full_scope_allowed = oBool "Grant the full scope by default.";
        consent_required = oBool "Require consent on first use.";
        display_on_consent_screen = oBool "Display the client on the consent screen.";
        consent_screen_text = oStr "Text shown on the consent screen.";

        use_refresh_tokens = oBool "Issue refresh tokens.";
        use_refresh_tokens_client_credentials = oBool "Issue refresh tokens for client-credentials grants.";
        standard_token_exchange_enabled = oBool "Enable standard token exchange.";
        allow_refresh_token_in_standard_token_exchange = oStr "Refresh-token policy for standard token exchange ('NO', 'SAME_SESSION', 'YES').";

        frontchannel_logout_url = oStr "Front-channel logout URL.";
        backchannel_logout_url = oStr "Back-channel logout URL.";
        backchannel_logout_session_required = oBool "Include session_id in back-channel logout requests.";
        backchannel_logout_revoke_offline_sessions = oBool "Revoke offline sessions on back-channel logout.";

        oauth2_device_authorization_grant_enabled = oBool "Enable the OAuth2 device authorization grant.";
        oauth2_device_code_lifespan = oStr "Device code lifespan.";
        oauth2_device_polling_interval = oStr "Device polling interval.";

        always_display_in_console = oBool "Always display the client in the user account console.";
        extra_config = oAttrsStr "Free-form extra config entries the upstream attribute set does not cover.";
      };
    };

    openid_client_default_scopes = {
      type = "keycloak_openid_client_default_scopes";
      prefix = "openid_client_default_scopes";
      nameAttr = null;
      scope = null;
      refs = {
        realm = realmRef;
        client = {
          attr = "client_id";
          targets = [
            {
              collection = "openid_clients";
              field = "id";
            }
          ];
          managedOnly = true;
          required = true;
          description = "Key of the managed OpenID client (services.keycloak.runtime.openid_clients.<name>) the scope binding applies to.";
        };
      };
      requiredAttrs = [ "default_scopes" ];
      description = "Default OAuth2 scopes auto-attached to a client, keyed by an arbitrary label.";
      attrs = {
        default_scopes = oListStr "Names of scopes attached by default.";
      };
    };

    openid_client_optional_scopes = {
      type = "keycloak_openid_client_optional_scopes";
      prefix = "openid_client_optional_scopes";
      nameAttr = null;
      scope = null;
      refs = {
        realm = realmRef;
        client = {
          attr = "client_id";
          targets = [
            {
              collection = "openid_clients";
              field = "id";
            }
          ];
          managedOnly = true;
          required = true;
          description = "Key of the managed OpenID client (services.keycloak.runtime.openid_clients.<name>) the scope binding applies to.";
        };
      };
      requiredAttrs = [ "optional_scopes" ];
      description = "Optional OAuth2 scopes available to a client, keyed by an arbitrary label.";
      attrs = {
        optional_scopes = oListStr "Names of optionally-attached scopes.";
      };
    };

    openid_client_service_account_roles = {
      type = "keycloak_openid_client_service_account_role";
      prefix = "openid_client_sa_role";
      nameAttr = null;
      scope = null;
      refs = {
        realm = realmRef;
        client = {
          attr = "client_id";
          targets = [
            {
              collection = "openid_clients";
              field = "id";
            }
          ];
          managedOnly = true;
          required = true;
          description = "Key of the managed target client whose role is granted.";
        };
      };
      requiredAttrs = [
        "service_account_user_id"
        "role"
      ];
      description = "Grant a per-client role to a service-account user, keyed by an arbitrary label.";
      attrs = {
        # Computed from the source client (`${keycloak_openid_client.X.service_account_user_id}`).
        service_account_user_id = oStr "Service-account user id (typically `\${keycloak_openid_client.X.service_account_user_id}`).";
        role = oStr "Name of the role granted (must exist on the target client).";
      };
    };

    openid_client_service_account_realm_roles = {
      type = "keycloak_openid_client_service_account_realm_role";
      prefix = "openid_client_sa_realm_role";
      nameAttr = null;
      scope = null;
      refs.realm = realmRef;
      requiredAttrs = [
        "service_account_user_id"
        "role"
      ];
      description = "Grant a realm-level role to a service-account user, keyed by an arbitrary label.";
      attrs = {
        service_account_user_id = oStr "Service-account user id (typically `\${keycloak_openid_client.X.service_account_user_id}`).";
        role = oStr "Name of the realm-level role granted.";
      };
    };

    saml_clients = {
      type = "keycloak_saml_client";
      prefix = "saml_client";
      nameAttr = "client_id";
      scope = null;
      refs.realm = realmRef;
      # signing_private_key isn't marked Sensitive by the provider but is a
      # private key in practice; expose <attr>File so operators can keep it
      # out of the world-readable store.
      secrets = [ "signing_private_key" ];
      description = "SAML clients (per-realm), keyed by clientId.";
      attrs = {
        client_id = oStr "SAML clientId. Defaults to the attribute key.";
        name = oStr "Display name.";
        description = oStr "Client description.";
        enabled = oBool "Is the client enabled?";

        include_authn_statement = oBool "Include the AuthnStatement in assertions.";
        sign_documents = oBool "Sign SAML documents.";
        sign_assertions = oBool "Sign SAML assertions.";
        encrypt_assertions = oBool "Encrypt assertions.";
        encryption_algorithm = oStr "Assertion encryption algorithm.";
        encryption_key_algorithm = oStr "Assertion encryption key algorithm.";
        encryption_digest_method = oStr "Assertion encryption digest method.";
        encryption_mask_generation_function = oStr "Assertion encryption MGF.";
        client_signature_required = oBool "Require the client to sign requests.";
        force_post_binding = oBool "Force POST binding.";
        consent_required = oBool "Require consent on first use.";
        front_channel_logout = oBool "Use front-channel logout.";
        force_name_id_format = oBool "Force the configured name_id_format.";
        signature_algorithm = oStr "SAML signature algorithm.";
        signature_key_name = oStr "SAML signature key name.";
        canonicalization_method = oStr "SAML canonicalization method URI.";
        name_id_format = oStr "SAML NameID format.";
        full_scope_allowed = oBool "Grant the full scope by default.";

        root_url = oStr "Root URL.";
        valid_redirect_uris = oListStr "Valid redirect URIs.";
        base_url = oStr "Base URL.";
        login_theme = oStr "Per-client login theme.";
        master_saml_processing_url = oStr "Master SAML processing URL.";

        encryption_certificate = oStr "Encryption certificate (PEM).";
        signing_certificate = oStr "Signing certificate (PEM).";
        signing_private_key = oStr "Signing private key (PEM). Prefer `signing_private_keyFile`.";

        idp_initiated_sso_url_name = oStr "IdP-initiated SSO URL name.";
        idp_initiated_sso_relay_state = oStr "IdP-initiated SSO RelayState.";
        assertion_consumer_post_url = oStr "Assertion consumer service POST URL.";
        assertion_consumer_redirect_url = oStr "Assertion consumer service Redirect URL.";
        logout_service_post_binding_url = oStr "SAML logout service POST binding URL.";
        logout_service_redirect_binding_url = oStr "SAML logout service Redirect binding URL.";

        always_display_in_console = oBool "Always display the client in the user account console.";
        extra_config = oAttrsStr "Free-form extra config entries.";
      };
    };

    saml_client_default_scopes = {
      type = "keycloak_saml_client_default_scopes";
      prefix = "saml_client_default_scopes";
      nameAttr = null;
      scope = null;
      refs = {
        realm = realmRef;
        client = {
          attr = "client_id";
          targets = [
            {
              collection = "saml_clients";
              field = "id";
            }
          ];
          managedOnly = true;
          required = true;
          description = "Key of the managed SAML client (services.keycloak.runtime.saml_clients.<name>) the scope binding applies to.";
        };
      };
      requiredAttrs = [ "default_scopes" ];
      description = "Default SAML scopes auto-attached to a SAML client, keyed by an arbitrary label.";
      attrs = {
        default_scopes = oListStr "Names of SAML scopes attached by default.";
      };
    };

    # OpenID protocol mappers: each is its own resource type, keyed by the
    # mapper name; all share the same realm + (client | client_scope) refs.
    openid_user_attribute_protocol_mappers = {
      type = "keycloak_openid_user_attribute_protocol_mapper";
      prefix = "openid_user_attribute_mapper";
      nameAttr = "name";
      scope = null;
      refs = {
        realm = realmRef;
        client = openidClientOptionalRef;
        client_scope = openidClientScopeOptionalRef;
      };
      requiredAttrs = [
        "user_attribute"
        "claim_name"
      ];
      description = "OpenID protocol mapper that maps a user attribute to a claim.";
      attrs = openidMapperCommonAttrs // {
        multivalued = oBool "Treat the attribute as multivalued?";
        user_attribute = oStr "Name of the user attribute to map.";
        claim_name = oStr "Name of the resulting JWT claim.";
        claim_value_type = oStr "Claim value type ('String', 'long', 'int', 'boolean', 'JSON').";
        aggregate_attributes = oBool "Aggregate multiple values into one claim?";
      };
    };

    openid_user_property_protocol_mappers = {
      type = "keycloak_openid_user_property_protocol_mapper";
      prefix = "openid_user_property_mapper";
      nameAttr = "name";
      scope = null;
      refs = {
        realm = realmRef;
        client = openidClientOptionalRef;
        client_scope = openidClientScopeOptionalRef;
      };
      requiredAttrs = [
        "user_property"
        "claim_name"
      ];
      description = "OpenID protocol mapper that maps a built-in user property (e.g. `email`, `username`) to a claim.";
      attrs = openidMapperCommonAttrs // {
        user_property = oStr "Built-in user property to map (e.g. 'email', 'username').";
        claim_name = oStr "Name of the resulting JWT claim.";
        claim_value_type = oStr "Claim value type.";
      };
    };

    openid_group_membership_protocol_mappers = {
      type = "keycloak_openid_group_membership_protocol_mapper";
      prefix = "openid_group_membership_mapper";
      nameAttr = "name";
      scope = null;
      refs = {
        realm = realmRef;
        client = openidClientOptionalRef;
        client_scope = openidClientScopeOptionalRef;
      };
      requiredAttrs = [ "claim_name" ];
      description = "OpenID protocol mapper that maps group memberships to a claim.";
      attrs = openidMapperCommonAttrs // {
        claim_name = oStr "Name of the resulting JWT claim.";
        full_path = oBool "Emit full group path (/parent/child) rather than just the leaf name?";
      };
    };

    openid_full_name_protocol_mappers = {
      type = "keycloak_openid_full_name_protocol_mapper";
      prefix = "openid_full_name_mapper";
      nameAttr = "name";
      scope = null;
      refs = {
        realm = realmRef;
        client = openidClientOptionalRef;
        client_scope = openidClientScopeOptionalRef;
      };
      description = "OpenID protocol mapper that emits the user's full name as a single claim.";
      attrs = openidMapperCommonAttrs;
    };

    openid_sub_protocol_mappers = {
      type = "keycloak_openid_sub_protocol_mapper";
      prefix = "openid_sub_mapper";
      nameAttr = "name";
      scope = null;
      refs = {
        realm = realmRef;
        client = openidClientOptionalRef;
        client_scope = openidClientScopeOptionalRef;
      };
      description = "OpenID protocol mapper for the `sub` claim.";
      attrs = {
        name = oStr "Mapper name. Defaults to the attribute key.";
        add_to_access_token = oBool "Include in access token?";
        add_to_token_introspection = oBool "Include in token introspection?";
      };
    };

    openid_hardcoded_claim_protocol_mappers = {
      type = "keycloak_openid_hardcoded_claim_protocol_mapper";
      prefix = "openid_hardcoded_claim_mapper";
      nameAttr = "name";
      scope = null;
      refs = {
        realm = realmRef;
        client = openidClientOptionalRef;
        client_scope = openidClientScopeOptionalRef;
      };
      requiredAttrs = [
        "claim_name"
        "claim_value"
      ];
      description = "OpenID protocol mapper that adds a hardcoded claim with a fixed value.";
      attrs = openidMapperCommonAttrs // {
        claim_name = oStr "Name of the resulting JWT claim.";
        claim_value = oStr "Hardcoded claim value.";
        claim_value_type = oStr "Claim value type.";
      };
    };

    openid_audience_protocol_mappers = {
      type = "keycloak_openid_audience_protocol_mapper";
      prefix = "openid_audience_mapper";
      nameAttr = "name";
      scope = null;
      refs = {
        realm = realmRef;
        client = openidClientOptionalRef;
        client_scope = openidClientScopeOptionalRef;
      };
      description = "OpenID protocol mapper that adds an audience to issued tokens (exactly one of `included_client_audience` / `included_custom_audience`).";
      attrs = {
        name = oStr "Mapper name. Defaults to the attribute key.";
        included_client_audience = oStr "ClientId of a client to include as audience.";
        included_custom_audience = oStr "Custom audience string to include.";
        add_to_id_token = oBool "Include in ID token?";
        add_to_access_token = oBool "Include in access token?";
      };
    };

    openid_audience_resolve_protocol_mappers = {
      type = "keycloak_openid_audience_resolve_protocol_mapper";
      prefix = "openid_audience_resolve_mapper";
      nameAttr = "name";
      scope = null;
      refs = {
        realm = realmRef;
        client = openidClientOptionalRef;
        client_scope = openidClientScopeOptionalRef;
      };
      description = "OpenID audience-resolve mapper (derives audience from client roles).";
      attrs = {
        name = oStr "Mapper name. Defaults to the attribute key.";
      };
    };

    openid_hardcoded_role_protocol_mappers = {
      type = "keycloak_openid_hardcoded_role_protocol_mapper";
      prefix = "openid_hardcoded_role_mapper";
      nameAttr = "name";
      scope = null;
      refs = {
        realm = realmRef;
        client = openidClientOptionalRef;
        client_scope = openidClientScopeOptionalRef;
      };
      requiredAttrs = [ "role_id" ];
      description = "OpenID protocol mapper that adds a hardcoded role to issued tokens.";
      attrs = {
        name = oStr "Mapper name. Defaults to the attribute key.";
        role_id = oStr "Role UUID (or `\${keycloak_role.X.id}` reference) to hardcode.";
      };
    };

    openid_user_realm_role_protocol_mappers = {
      type = "keycloak_openid_user_realm_role_protocol_mapper";
      prefix = "openid_user_realm_role_mapper";
      nameAttr = "name";
      scope = null;
      refs = {
        realm = realmRef;
        client = openidClientOptionalRef;
        client_scope = openidClientScopeOptionalRef;
      };
      requiredAttrs = [ "claim_name" ];
      description = "OpenID protocol mapper that maps the user's realm roles to a claim.";
      attrs = openidMapperCommonAttrs // {
        add_to_token_introspection = oBool "Include in token introspection?";
        claim_name = oStr "Name of the resulting JWT claim.";
        claim_value_type = oStr "Claim value type.";
        multivalued = oBool "Treat as multivalued?";
        realm_role_prefix = oStr "Optional prefix prepended to each role name in the claim.";
      };
    };

    openid_user_client_role_protocol_mappers = {
      type = "keycloak_openid_user_client_role_protocol_mapper";
      prefix = "openid_user_client_role_mapper";
      nameAttr = "name";
      scope = null;
      refs = {
        realm = realmRef;
        client = openidClientOptionalRef;
        client_scope = openidClientScopeOptionalRef;
      };
      requiredAttrs = [ "claim_name" ];
      description = "OpenID protocol mapper that maps the user's roles on a specific client to a claim.";
      attrs = openidMapperCommonAttrs // {
        claim_name = oStr "Name of the resulting JWT claim.";
        claim_value_type = oStr "Claim value type.";
        multivalued = oBool "Treat as multivalued?";
        client_id_for_role_mappings = oStr "Source clientId whose role mappings are emitted.";
        client_role_prefix = oStr "Optional prefix prepended to each role name in the claim.";
      };
    };

    openid_user_session_note_protocol_mappers = {
      type = "keycloak_openid_user_session_note_protocol_mapper";
      prefix = "openid_user_session_note_mapper";
      nameAttr = "name";
      scope = null;
      refs = {
        realm = realmRef;
        client = openidClientOptionalRef;
        client_scope = openidClientScopeOptionalRef;
      };
      requiredAttrs = [
        "claim_name"
        "session_note"
      ];
      description = "OpenID protocol mapper that maps a user session note to a claim.";
      attrs = {
        name = oStr "Mapper name. Defaults to the attribute key.";
        add_to_id_token = oBool "Include in ID token?";
        add_to_access_token = oBool "Include in access token?";
        claim_name = oStr "Name of the resulting JWT claim.";
        claim_value_type = oStr "Claim value type.";
        session_note = oStr "Name of the user session note to read.";
      };
    };

    openid_script_protocol_mappers = {
      type = "keycloak_openid_script_protocol_mapper";
      prefix = "openid_script_mapper";
      nameAttr = "name";
      scope = null;
      refs = {
        realm = realmRef;
        client = openidClientOptionalRef;
        client_scope = openidClientScopeOptionalRef;
      };
      requiredAttrs = [
        "script"
        "claim_name"
      ];
      description = "OpenID protocol mapper that produces a claim from a JavaScript expression (requires the scripts feature).";
      attrs = openidMapperCommonAttrs // {
        multivalued = oBool "Treat as multivalued?";
        script = oStr "JavaScript expression evaluated to produce the claim value.";
        claim_name = oStr "Name of the resulting JWT claim.";
        claim_value_type = oStr "Claim value type.";
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
