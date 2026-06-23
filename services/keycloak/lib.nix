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
  oListSub =
    options: description:
    lib.mkOption {
      type = ty.nullOr (ty.listOf (ty.submodule { inherit options; }));
      default = null;
      inherit description;
    };
  oSub =
    options: description:
    lib.mkOption {
      type = ty.nullOr (ty.submodule { inherit options; });
      default = null;
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

  # SAML mapper attachment refs (analogous to the openid pair above).
  samlClientOptionalRef = {
    attr = "client_id";
    targets = [
      {
        collection = "saml_clients";
        field = "id";
      }
    ];
    managedOnly = true;
    required = false;
    description = "Optional managed SAML client this mapper attaches to.";
  };
  samlClientScopeOptionalRef = {
    attr = "client_scope_id";
    targets = [
      {
        collection = "saml_client_scopes";
        field = "id";
      }
    ];
    managedOnly = true;
    required = false;
    description = "Optional managed SAML client scope this mapper attaches to.";
  };

  # identity providers reference the realm by its alias (name), not by id;
  # `realm = "<alias>"` is how the provider wires them.
  realmAliasRef = {
    attr = "realm";
    targets = [
      {
        collection = "realms";
        field = "realm";
      }
    ];
    managedOnly = true;
    required = true;
    description = "Key of the managed realm (services.keycloak.runtime.realms.<name>) the IdP lives in.";
  };

  # LDAP mappers reference their parent federation by managed key (numeric
  # id). Used by every keycloak_ldap_*_mapper resource.
  ldapFederationIdRef = {
    attr = "ldap_user_federation_id";
    targets = [
      {
        collection = "ldap_user_federations";
        field = "id";
      }
    ];
    managedOnly = true;
    required = true;
    description = "Key of the managed LDAP user federation (services.keycloak.runtime.ldap_user_federations.<name>) this mapper attaches to.";
  };

  # identity provider mappers reference an IdP by alias; the alias may
  # belong to any of the six IdP variants we model.
  idpAliasRequiredRef = {
    attr = "identity_provider_alias";
    targets = [
      {
        collection = "oidc_identity_providers";
        field = "alias";
      }
      {
        collection = "saml_identity_providers";
        field = "alias";
      }
      {
        collection = "oidc_google_identity_providers";
        field = "alias";
      }
      {
        collection = "oidc_facebook_identity_providers";
        field = "alias";
      }
      {
        collection = "oidc_github_identity_providers";
        field = "alias";
      }
      {
        collection = "kubernetes_identity_providers";
        field = "alias";
      }
    ];
    managedOnly = false;
    required = true;
    description = "Alias of the managed identity provider (in any IdP collection) this mapper attaches to, or a literal alias.";
  };

  # common attrs every IdP mapper carries.
  commonIdpMapperAttrs = {
    name = oStr "Mapper name. Defaults to the attribute key.";
    extra_config = oAttrsStr "Free-form extra mapper config entries.";
  };

  # shared attrs every keycloak identity provider exposes (alias is the IdP
  # key, display_name is human-readable, enabled toggles, etc.).
  commonIdpAttrs = {
    alias = oStr "Provider alias. Defaults to the attribute key.";
    display_name = oStr "Human-readable name shown on the login page.";
    enabled = oBool "Is the identity provider enabled?";
    store_token = oBool "Persist tokens obtained from the IdP.";
    add_read_token_role_on_create = oBool "Grant the read-token role to newly federated users.";
    authenticate_by_default = oBool "Use this IdP as the default authenticator.";
    link_only = oBool "Don't allow new login -- only link existing accounts.";
    trust_email = oBool "Trust the email returned by the IdP (skip verification).";
    first_broker_login_flow_alias = oStr "Alias of the first-broker-login flow used.";
    post_broker_login_flow_alias = oStr "Alias of the post-broker-login flow used.";
    organization_id = oStr "Optional organization id this IdP belongs to.";
    extra_config = oAttrsStr "Free-form extra IdP config entries.";
    gui_order = oStr "Display order in the admin UI (string).";
    sync_mode = oStr "Sync mode: 'IMPORT', 'LEGACY', or 'FORCE'.";
    org_redirect_mode_email_matches = oBool "Redirect users whose email matches an organization's domain to this IdP.";
    org_domain = oStr "Organization domain matched against the user's email.";
  };

  # generic mappers / role mappers attach to either an openid or a SAML
  # client/scope; multi-target so a managed key from either collection
  # resolves, and a literal id string falls through.
  anyClientOptionalRef = {
    attr = "client_id";
    targets = [
      {
        collection = "openid_clients";
        field = "id";
      }
      {
        collection = "saml_clients";
        field = "id";
      }
    ];
    managedOnly = false;
    required = false;
    description = "Optional managed client (openid or saml) this mapper attaches to.";
  };
  anyClientScopeOptionalRef = {
    attr = "client_scope_id";
    targets = [
      {
        collection = "openid_client_scopes";
        field = "id";
      }
      {
        collection = "saml_client_scopes";
        field = "id";
      }
    ];
    managedOnly = false;
    required = false;
    description = "Optional managed client scope (openid or saml) this mapper attaches to.";
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

    saml_user_attribute_protocol_mappers = {
      type = "keycloak_saml_user_attribute_protocol_mapper";
      prefix = "saml_user_attribute_mapper";
      nameAttr = "name";
      scope = null;
      refs = {
        realm = realmRef;
        client = samlClientOptionalRef;
        client_scope = samlClientScopeOptionalRef;
      };
      requiredAttrs = [
        "user_attribute"
        "saml_attribute_name"
      ];
      description = "SAML mapper that exposes a user attribute as a SAML attribute.";
      attrs = {
        name = oStr "Mapper name. Defaults to the attribute key.";
        user_attribute = oStr "Source user attribute.";
        friendly_name = oStr "Optional SAML friendlyName.";
        saml_attribute_name = oStr "SAML attribute name.";
        saml_attribute_name_format = oStr "SAML attribute name format ('Basic', 'URI Reference', 'Unspecified').";
        aggregate_attributes = oBool "Aggregate multivalued attributes into one SAML attribute?";
      };
    };

    saml_user_property_protocol_mappers = {
      type = "keycloak_saml_user_property_protocol_mapper";
      prefix = "saml_user_property_mapper";
      nameAttr = "name";
      scope = null;
      refs = {
        realm = realmRef;
        client = samlClientOptionalRef;
        client_scope = samlClientScopeOptionalRef;
      };
      requiredAttrs = [
        "user_property"
        "saml_attribute_name"
      ];
      description = "SAML mapper that exposes a built-in user property as a SAML attribute.";
      attrs = {
        name = oStr "Mapper name. Defaults to the attribute key.";
        user_property = oStr "Built-in user property (e.g. 'email', 'username').";
        friendly_name = oStr "Optional SAML friendlyName.";
        saml_attribute_name = oStr "SAML attribute name.";
        saml_attribute_name_format = oStr "SAML attribute name format.";
      };
    };

    saml_script_protocol_mappers = {
      type = "keycloak_saml_script_protocol_mapper";
      prefix = "saml_script_mapper";
      nameAttr = "name";
      scope = null;
      refs = {
        realm = realmRef;
        client = samlClientOptionalRef;
        client_scope = samlClientScopeOptionalRef;
      };
      requiredAttrs = [
        "script"
        "saml_attribute_name"
      ];
      description = "SAML mapper that produces a SAML attribute from a JavaScript expression.";
      attrs = {
        name = oStr "Mapper name. Defaults to the attribute key.";
        single_value_attribute = oBool "Emit as a single-value attribute?";
        script = oStr "JavaScript expression evaluated to produce the SAML attribute value.";
        friendly_name = oStr "Optional SAML friendlyName.";
        saml_attribute_name = oStr "SAML attribute name.";
        saml_attribute_name_format = oStr "SAML attribute name format.";
      };
    };

    generic_protocol_mappers = {
      type = "keycloak_generic_protocol_mapper";
      prefix = "generic_protocol_mapper";
      nameAttr = "name";
      scope = null;
      refs = {
        realm = realmRef;
        client = anyClientOptionalRef;
        client_scope = anyClientScopeOptionalRef;
      };
      requiredAttrs = [
        "protocol"
        "protocol_mapper"
        "config"
      ];
      description = "Generic protocol mapper escape hatch (for mappers without a dedicated typed resource).";
      attrs = {
        name = oStr "Mapper name. Defaults to the attribute key.";
        protocol = oStr "Protocol ('openid-connect' or 'saml').";
        protocol_mapper = oStr "Provider-id of the mapper implementation (e.g. 'oidc-usermodel-attribute-mapper').";
        config = oAttrsStr "Mapper configuration (provider-specific key/value pairs).";
      };
    };

    generic_client_protocol_mappers = {
      type = "keycloak_generic_client_protocol_mapper";
      prefix = "generic_client_protocol_mapper";
      nameAttr = "name";
      scope = null;
      refs = {
        realm = realmRef;
        client = anyClientOptionalRef;
        client_scope = anyClientScopeOptionalRef;
      };
      requiredAttrs = [
        "protocol"
        "protocol_mapper"
        "config"
      ];
      description = "Generic protocol mapper attached to a specific client (without a dedicated typed resource).";
      attrs = {
        name = oStr "Mapper name. Defaults to the attribute key.";
        protocol = oStr "Protocol ('openid-connect' or 'saml').";
        protocol_mapper = oStr "Provider-id of the mapper implementation.";
        config = oAttrsStr "Mapper configuration (provider-specific key/value pairs).";
      };
    };

    generic_role_mappers = {
      type = "keycloak_generic_role_mapper";
      prefix = "generic_role_mapper";
      nameAttr = null;
      scope = null;
      refs = {
        realm = realmRef;
        client = anyClientOptionalRef;
        client_scope = anyClientScopeOptionalRef;
      };
      requiredAttrs = [ "role_id" ];
      description = "Generic role-scope mapper that attaches a role to a client / client scope, keyed by an arbitrary label.";
      attrs = {
        role_id = oStr "Role UUID (or `\${keycloak_role.X.id}` reference) to attach.";
      };
    };

    generic_client_role_mappers = {
      type = "keycloak_generic_client_role_mapper";
      prefix = "generic_client_role_mapper";
      nameAttr = null;
      scope = null;
      refs = {
        realm = realmRef;
        client = anyClientOptionalRef;
        client_scope = anyClientScopeOptionalRef;
      };
      requiredAttrs = [ "role_id" ];
      description = "Generic role-scope mapper attached to a specific client (deprecated alias kept for completeness).";
      attrs = {
        role_id = oStr "Role UUID (or `\${keycloak_role.X.id}` reference) to attach.";
      };
    };

    oidc_identity_providers = {
      type = "keycloak_oidc_identity_provider";
      prefix = "oidc_idp";
      nameAttr = "alias";
      scope = null;
      refs.realm = realmAliasRef;
      secrets = [ "client_secret" ];
      requiredAttrs = [
        "authorization_url"
        "client_id"
        "token_url"
      ];
      description = "Generic OIDC identity providers (per-realm), keyed by alias.";
      attrs = commonIdpAttrs // {
        provider_id = oStr "Provider id (defaults to 'oidc').";
        backchannel_supported = oBool "Does the IdP support back-channel logout?";
        validate_signature = oBool "Validate the IdP's token signature.";
        authorization_url = oStr "OIDC authorization endpoint.";
        client_id = oStr "OIDC client id.";
        client_secret = oStr "OIDC client secret. Prefer `client_secretFile`.";
        user_info_url = oStr "OIDC userinfo endpoint.";
        jwks_url = oStr "OIDC JWKS endpoint.";
        hide_on_login_page = oBool "Hide this IdP on the login page.";
        token_url = oStr "OIDC token endpoint.";
        logout_url = oStr "OIDC logout endpoint.";
        login_hint = oBool "Pass `login_hint` query parameter to the IdP.";
        ui_locales = oBool "Pass `ui_locales` query parameter to the IdP.";
        default_scopes = oStr "Space-separated default scopes to request.";
        accepts_prompt_none_forward_from_client = oBool "Forward `prompt=none` requests to this IdP.";
        disable_user_info = oBool "Don't call the userinfo endpoint.";
        issuer = oStr "Expected `iss` claim value.";
        disable_type_claim_check = oBool "Skip the typ-claim check on returned tokens.";
      };
    };

    saml_identity_providers = {
      type = "keycloak_saml_identity_provider";
      prefix = "saml_idp";
      nameAttr = "alias";
      scope = null;
      refs.realm = realmAliasRef;
      requiredAttrs = [
        "entity_id"
        "single_sign_on_service_url"
      ];
      description = "SAML identity providers (per-realm), keyed by alias.";
      attrs = commonIdpAttrs // {
        provider_id = oStr "Provider id (defaults to 'saml').";
        backchannel_supported = oBool "Does the IdP support back-channel logout?";
        validate_signature = oBool "Validate SAML signatures.";
        hide_on_login_page = oBool "Hide this IdP on the login page.";
        name_id_policy_format = oStr "Default name_id_policy_format URN.";
        single_logout_service_url = oStr "SAML SLO endpoint URL.";
        entity_id = oStr "Entity ID expected from the IdP.";
        single_sign_on_service_url = oStr "SAML SSO endpoint URL.";
        signing_certificate = oStr "IdP signing certificate (PEM).";
        signature_algorithm = oStr "Signature algorithm.";
        xml_sign_key_info_key_name_transformer = oStr "KeyInfo KeyName transformer.";
        post_binding_authn_request = oBool "Use POST binding for AuthnRequests.";
        post_binding_response = oBool "Use POST binding for Responses.";
        post_binding_logout = oBool "Use POST binding for Logout.";
        force_authn = oBool "Force re-authentication on every login.";
        login_hint = oBool "Pass login_hint to the IdP.";
        want_assertions_signed = oBool "Require signed assertions.";
        want_assertions_encrypted = oBool "Require encrypted assertions.";
        want_authn_requests_signed = oBool "Require signed AuthnRequests.";
        principal_type = oStr "How to derive the user principal ('SUBJECT', 'ATTRIBUTE', 'FRIENDLY_ATTRIBUTE').";
        principal_attribute = oStr "Attribute name when principal_type is ATTRIBUTE or FRIENDLY_ATTRIBUTE.";
        authn_context_class_refs = oListStr "AuthnContext class refs requested in AuthnRequests.";
        authn_context_decl_refs = oListStr "AuthnContext declaration refs requested in AuthnRequests.";
        authn_context_comparison_type = oStr "AuthnContext comparison type ('exact', 'minimum', 'maximum', 'better').";
      };
    };

    oidc_google_identity_providers = {
      type = "keycloak_oidc_google_identity_provider";
      prefix = "oidc_google_idp";
      nameAttr = "alias";
      scope = null;
      refs.realm = realmAliasRef;
      secrets = [ "client_secret" ];
      requiredSecrets = [ "client_secret" ];
      requiredAttrs = [ "client_id" ];
      description = "Google OIDC identity providers (per-realm), keyed by alias (defaults to 'google').";
      attrs = commonIdpAttrs // {
        provider_id = oStr "Provider id (defaults to 'google').";
        client_id = oStr "Google OAuth2 client id.";
        client_secret = oStr "Google OAuth2 client secret. Prefer `client_secretFile`.";
        hosted_domain = oStr "Restrict to a Google Workspace hosted domain (or `*`).";
        use_user_ip_param = oBool "Forward the user's IP to Google's UserInfo service.";
        request_refresh_token = oBool "Request a refresh token (`access_type=offline`).";
        default_scopes = oStr "Space-separated default scopes (default 'openid profile email').";
        accepts_prompt_none_forward_from_client = oBool "Forward `prompt=none` requests.";
        disable_user_info = oBool "Don't call the UserInfo service.";
        hide_on_login_page = oBool "Hide this IdP on the login page.";
      };
    };

    oidc_facebook_identity_providers = {
      type = "keycloak_oidc_facebook_identity_provider";
      prefix = "oidc_facebook_idp";
      nameAttr = "alias";
      scope = null;
      refs.realm = realmAliasRef;
      secrets = [ "client_secret" ];
      requiredSecrets = [ "client_secret" ];
      requiredAttrs = [ "client_id" ];
      description = "Facebook OIDC identity providers (per-realm), keyed by alias (defaults to 'facebook').";
      attrs = commonIdpAttrs // {
        provider_id = oStr "Provider id (defaults to 'facebook').";
        client_id = oStr "Facebook app id.";
        client_secret = oStr "Facebook app secret. Prefer `client_secretFile`.";
        hide_on_login_page = oBool "Hide this IdP on the login page.";
      };
    };

    oidc_github_identity_providers = {
      type = "keycloak_oidc_github_identity_provider";
      prefix = "oidc_github_idp";
      nameAttr = "alias";
      scope = null;
      refs.realm = realmAliasRef;
      secrets = [ "client_secret" ];
      requiredSecrets = [ "client_secret" ];
      requiredAttrs = [ "client_id" ];
      description = "GitHub OIDC identity providers (per-realm), keyed by alias (defaults to 'github').";
      attrs = commonIdpAttrs // {
        provider_id = oStr "Provider id (defaults to 'github').";
        client_id = oStr "GitHub OAuth app client id.";
        client_secret = oStr "GitHub OAuth app client secret. Prefer `client_secretFile`.";
        base_url = oStr "Override the GitHub Enterprise base URL.";
        api_url = oStr "Override the GitHub Enterprise API URL.";
        github_json_format = oBool "Use GitHub's JSON content type.";
        hide_on_login_page = oBool "Hide this IdP on the login page.";
      };
    };

    kubernetes_identity_providers = {
      type = "keycloak_kubernetes_identity_provider";
      prefix = "kubernetes_idp";
      nameAttr = "alias";
      scope = null;
      refs.realm = realmAliasRef;
      requiredAttrs = [ "issuer" ];
      description = "Kubernetes OIDC identity providers (per-realm), keyed by alias.";
      attrs = commonIdpAttrs // {
        provider_id = oStr "Provider id (defaults to 'kubernetes').";
        issuer = oStr "Kubernetes API server issuer URL.";
        hide_on_login_page = oBool "Hide this IdP on the login page.";
      };
    };

    hardcoded_attribute_identity_provider_mappers = {
      type = "keycloak_hardcoded_attribute_identity_provider_mapper";
      prefix = "hardcoded_attribute_idp_mapper";
      nameAttr = "name";
      scope = null;
      refs = {
        realm = realmAliasRef;
        identity_provider = idpAliasRequiredRef;
      };
      requiredAttrs = [ "user_session" ];
      description = "Sets a hardcoded user (or session-note) attribute on every federated user.";
      attrs = commonIdpMapperAttrs // {
        attribute_name = oStr "Name of the attribute / session note to set.";
        attribute_value = oStr "Value of the attribute / session note.";
        user_session = oBool "If true, set as a session note; if false, as a user attribute.";
      };
    };

    hardcoded_group_identity_provider_mappers = {
      type = "keycloak_hardcoded_group_identity_provider_mapper";
      prefix = "hardcoded_group_idp_mapper";
      nameAttr = "name";
      scope = null;
      refs = {
        realm = realmAliasRef;
        identity_provider = idpAliasRequiredRef;
      };
      description = "Adds every federated user to a hardcoded group.";
      attrs = commonIdpMapperAttrs // {
        group = oStr "Group path (e.g. `/engineering/backend`) every federated user joins.";
      };
    };

    hardcoded_role_identity_provider_mappers = {
      type = "keycloak_hardcoded_role_identity_provider_mapper";
      prefix = "hardcoded_role_idp_mapper";
      nameAttr = "name";
      scope = null;
      refs = {
        realm = realmAliasRef;
        identity_provider = idpAliasRequiredRef;
      };
      description = "Grants a hardcoded role to every federated user.";
      attrs = commonIdpMapperAttrs // {
        role = oStr "Realm or `client.role` name granted to every federated user.";
      };
    };

    attribute_importer_identity_provider_mappers = {
      type = "keycloak_attribute_importer_identity_provider_mapper";
      prefix = "attribute_importer_idp_mapper";
      nameAttr = "name";
      scope = null;
      refs = {
        realm = realmAliasRef;
        identity_provider = idpAliasRequiredRef;
      };
      requiredAttrs = [ "user_attribute" ];
      description = "Imports an attribute / claim from the IdP onto the federated user.";
      attrs = commonIdpMapperAttrs // {
        user_attribute = oStr "Destination user attribute on the keycloak side.";
        attribute_name = oStr "Source SAML attribute name (SAML IdPs; conflicts with attribute_friendly_name).";
        attribute_friendly_name = oStr "Source SAML attribute friendly name (SAML IdPs; conflicts with attribute_name).";
        claim_name = oStr "Source OIDC claim name (OIDC IdPs).";
      };
    };

    attribute_to_role_identity_provider_mappers = {
      type = "keycloak_attribute_to_role_identity_provider_mapper";
      prefix = "attribute_to_role_idp_mapper";
      nameAttr = "name";
      scope = null;
      refs = {
        realm = realmAliasRef;
        identity_provider = idpAliasRequiredRef;
      };
      requiredAttrs = [ "role" ];
      description = "Grants a role to federated users whose IdP attribute / claim matches a value.";
      attrs = commonIdpMapperAttrs // {
        attribute_name = oStr "SAML attribute name to match (conflicts with attribute_friendly_name).";
        attribute_value = oStr "Value the SAML attribute must equal.";
        attribute_friendly_name = oStr "SAML friendly name to match (conflicts with attribute_name).";
        claim_name = oStr "OIDC claim name to match.";
        claim_value = oStr "Value the OIDC claim must equal.";
        role = oStr "Realm or `client.role` name granted on match.";
      };
    };

    user_template_importer_identity_provider_mappers = {
      type = "keycloak_user_template_importer_identity_provider_mapper";
      prefix = "user_template_importer_idp_mapper";
      nameAttr = "name";
      scope = null;
      refs = {
        realm = realmAliasRef;
        identity_provider = idpAliasRequiredRef;
      };
      description = "Derives the federated user's username from a Mustache-style template over IdP claims.";
      attrs = commonIdpMapperAttrs // {
        template = oStr "Username template (e.g. `\${CLAIM.preferred_username}@example`).";
      };
    };

    custom_identity_provider_mappers = {
      type = "keycloak_custom_identity_provider_mapper";
      prefix = "custom_idp_mapper";
      nameAttr = "name";
      scope = null;
      refs = {
        realm = realmAliasRef;
        identity_provider = idpAliasRequiredRef;
      };
      requiredAttrs = [ "identity_provider_mapper" ];
      description = "Escape hatch for an IdP mapper implementation without a dedicated typed resource.";
      attrs = commonIdpMapperAttrs // {
        identity_provider_mapper = oStr "Provider-id of the mapper implementation.";
      };
    };

    authentication_flows = {
      type = "keycloak_authentication_flow";
      prefix = "authentication_flow";
      nameAttr = "alias";
      scope = null;
      refs.realm = realmRef;
      description = "Top-level authentication flows (per-realm), keyed by alias.";
      attrs = {
        alias = oStr "Flow alias. Defaults to the attribute key.";
        provider_id = oStr "Flow implementation: 'basic-flow' (default) or 'client-flow'.";
        description = oStr "Flow description.";
      };
    };

    authentication_subflows = {
      type = "keycloak_authentication_subflow";
      prefix = "authentication_subflow";
      nameAttr = "alias";
      scope = null;
      refs = {
        realm = realmRef;
        parent_flow = {
          attr = "parent_flow_alias";
          targets = [
            {
              collection = "authentication_flows";
              field = "alias";
            }
            {
              collection = "authentication_subflows";
              field = "alias";
            }
          ];
          managedOnly = false;
          required = true;
          description = "Alias of the parent flow (managed key or literal alias).";
        };
      };
      description = "Authentication subflows nested under a parent flow, keyed by alias.";
      attrs = {
        alias = oStr "Subflow alias. Defaults to the attribute key.";
        provider_id = oStr "Subflow implementation: 'basic-flow' (default), 'form-flow', or 'client-flow'.";
        description = oStr "Subflow description.";
        authenticator = oStr "Authenticator id (for form / conditional subflows).";
        requirement = oStr "Execution requirement ('REQUIRED', 'ALTERNATIVE', 'OPTIONAL', 'CONDITIONAL', 'DISABLED').";
        priority = oInt "Display / evaluation order within the parent flow.";
      };
    };

    authentication_executions = {
      type = "keycloak_authentication_execution";
      prefix = "authentication_execution";
      nameAttr = null;
      scope = null;
      refs = {
        realm = realmRef;
        parent_flow = {
          attr = "parent_flow_alias";
          targets = [
            {
              collection = "authentication_flows";
              field = "alias";
            }
            {
              collection = "authentication_subflows";
              field = "alias";
            }
          ];
          managedOnly = false;
          required = true;
          description = "Alias of the parent flow / subflow (managed key or literal alias).";
        };
      };
      requiredAttrs = [ "authenticator" ];
      description = "Authentication executions inside a flow / subflow, keyed by an arbitrary label.";
      attrs = {
        authenticator = oStr "Authenticator provider id (e.g. 'auth-username-password-form').";
        requirement = oStr "Execution requirement ('REQUIRED', 'ALTERNATIVE', 'OPTIONAL', 'CONDITIONAL', 'DISABLED').";
        priority = oInt "Display / evaluation order within the parent flow.";
      };
    };

    authentication_execution_configs = {
      type = "keycloak_authentication_execution_config";
      prefix = "authentication_execution_config";
      nameAttr = "alias";
      scope = null;
      refs = {
        realm = realmRef;
        execution = {
          attr = "execution_id";
          targets = [
            {
              collection = "authentication_executions";
              field = "id";
            }
          ];
          managedOnly = true;
          required = true;
          description = "Key of the managed authentication_execution (services.keycloak.runtime.authentication_executions.<name>) this config attaches to.";
        };
      };
      requiredAttrs = [ "config" ];
      description = "Per-execution configuration map, keyed by config alias.";
      attrs = {
        alias = oStr "Config alias. Defaults to the attribute key.";
        config = oAttrsStr "Execution config key/value pairs.";
      };
    };

    authentication_bindings = {
      type = "keycloak_authentication_bindings";
      prefix = "authentication_bindings";
      nameAttr = null;
      scope = null;
      refs.realm = realmRef;
      description = "Realm-level authentication flow bindings (browser / registration / direct grant / etc.), keyed by an arbitrary label.";
      attrs = {
        browser_flow = oStr "Alias of the flow bound to the browser flow.";
        registration_flow = oStr "Alias of the flow bound to the registration flow.";
        direct_grant_flow = oStr "Alias of the flow bound to the direct-grant flow.";
        reset_credentials_flow = oStr "Alias of the flow bound to the reset-credentials flow.";
        client_authentication_flow = oStr "Alias of the flow bound to the client-auth flow.";
        docker_authentication_flow = oStr "Alias of the flow bound to the docker-auth flow.";
        first_broker_login_flow = oStr "Alias of the flow bound to the first-broker-login flow.";
      };
    };

    openid_client_authorization_resources = {
      type = "keycloak_openid_client_authorization_resource";
      prefix = "openid_client_authz_resource";
      nameAttr = "name";
      scope = null;
      refs = {
        realm = realmRef;
        resource_server = {
          attr = "resource_server_id";
          targets = [
            {
              collection = "openid_clients";
              field = "resource_server_id";
            }
          ];
          managedOnly = true;
          required = true;
          description = "Key of the managed openid_client (with authorization enabled) hosting this resource.";
        };
      };
      description = "Authorization resources hosted on an openid_client's resource server.";
      attrs = {
        name = oStr "Resource name. Defaults to the attribute key.";
        display_name = oStr "Human-friendly display name.";
        uris = oListStr "URIs the resource represents.";
        icon_uri = oStr "Optional icon URI.";
        owner_managed_access = oBool "Allow the owner to manage access to this resource.";
        scopes = oListStr "Names of authorization scopes available on the resource.";
        type = oStr "Optional resource type discriminator.";
        attributes = oAttrsStr "Free-form attribute map.";
      };
    };

    openid_client_authorization_scopes = {
      type = "keycloak_openid_client_authorization_scope";
      prefix = "openid_client_authz_scope";
      nameAttr = "name";
      scope = null;
      refs = {
        realm = realmRef;
        resource_server = {
          attr = "resource_server_id";
          targets = [
            {
              collection = "openid_clients";
              field = "resource_server_id";
            }
          ];
          managedOnly = true;
          required = true;
          description = "Key of the managed openid_client (with authorization enabled) hosting this scope.";
        };
      };
      description = "Authorization scopes on an openid_client's resource server.";
      attrs = {
        name = oStr "Scope name. Defaults to the attribute key.";
        display_name = oStr "Human-friendly display name.";
        icon_uri = oStr "Optional icon URI.";
      };
    };

    openid_client_authorization_permissions = {
      type = "keycloak_openid_client_authorization_permission";
      prefix = "openid_client_authz_permission";
      nameAttr = "name";
      scope = null;
      refs = {
        realm = realmRef;
        resource_server = {
          attr = "resource_server_id";
          targets = [
            {
              collection = "openid_clients";
              field = "resource_server_id";
            }
          ];
          managedOnly = true;
          required = true;
          description = "Key of the managed openid_client (with authorization enabled) hosting this permission.";
        };
      };
      description = "Authorization permissions tying resources/scopes to policies.";
      attrs = {
        name = oStr "Permission name. Defaults to the attribute key.";
        description = oStr "Permission description.";
        decision_strategy = oStr "Decision strategy ('UNANIMOUS', 'AFFIRMATIVE', 'CONSENSUS'; default 'UNANIMOUS').";
        policies = oListStr "Names / ids of policies that apply.";
        resources = oListStr "Resource names this permission covers (conflicts with resource_type).";
        resource_type = oStr "Single resource type this permission covers (conflicts with resources).";
        scopes = oListStr "Scope names this permission covers.";
        type = oStr "Permission type ('resource' [default] or 'scope').";
      };
    };

    openid_client_authorization_aggregate_policies = {
      type = "keycloak_openid_client_authorization_aggregate_policy";
      prefix = "openid_client_authz_aggregate_policy";
      nameAttr = "name";
      scope = null;
      refs = {
        realm = realmRef;
        resource_server = {
          attr = "resource_server_id";
          targets = [
            {
              collection = "openid_clients";
              field = "resource_server_id";
            }
          ];
          managedOnly = true;
          required = true;
          description = "Key of the managed openid_client hosting this aggregate policy.";
        };
      };
      requiredAttrs = [
        "decision_strategy"
        "policies"
      ];
      description = "Aggregate policy combining other policies under a decision strategy.";
      attrs = {
        name = oStr "Policy name. Defaults to the attribute key.";
        description = oStr "Policy description.";
        decision_strategy = oStr "Decision strategy ('UNANIMOUS', 'AFFIRMATIVE', 'CONSENSUS').";
        logic = oStr "Policy logic ('POSITIVE' or 'NEGATIVE').";
        policies = oListStr "Names / ids of policies aggregated by this policy.";
      };
    };

    openid_client_authorization_client_policies = {
      type = "keycloak_openid_client_authorization_client_policy";
      prefix = "openid_client_authz_client_policy";
      nameAttr = "name";
      scope = null;
      refs = {
        realm = realmRef;
        resource_server = {
          attr = "resource_server_id";
          targets = [
            {
              collection = "openid_clients";
              field = "resource_server_id";
            }
          ];
          managedOnly = true;
          required = true;
          description = "Key of the managed openid_client hosting this policy.";
        };
      };
      requiredAttrs = [
        "decision_strategy"
        "clients"
      ];
      description = "Policy granting access to a specific set of clients.";
      attrs = {
        name = oStr "Policy name. Defaults to the attribute key.";
        description = oStr "Policy description.";
        decision_strategy = oStr "Decision strategy.";
        logic = oStr "Policy logic ('POSITIVE' or 'NEGATIVE').";
        clients = oListStr "ClientIds of clients the policy applies to.";
      };
    };

    openid_client_authorization_client_scope_policies = {
      type = "keycloak_openid_client_authorization_client_scope_policy";
      prefix = "openid_client_authz_client_scope_policy";
      nameAttr = "name";
      scope = null;
      refs = {
        realm = realmRef;
        resource_server = {
          attr = "resource_server_id";
          targets = [
            {
              collection = "openid_clients";
              field = "resource_server_id";
            }
          ];
          managedOnly = true;
          required = true;
          description = "Key of the managed openid_client hosting this policy.";
        };
      };
      requiredAttrs = [
        "decision_strategy"
        "scope"
      ];
      description = "Policy granting access by client scope membership; each scope block is `{ id; required = false; }`.";
      attrs = {
        name = oStr "Policy name. Defaults to the attribute key.";
        description = oStr "Policy description.";
        decision_strategy = oStr "Decision strategy.";
        logic = oStr "Policy logic ('POSITIVE' or 'NEGATIVE').";
        scope = oListSub {
          id = rStr "Client scope id.";
          required = oBool "Treat the scope as required (vs optional).";
        } "List of `{ id; required; }` blocks naming client scopes the policy applies to.";
      };
    };

    openid_client_authorization_group_policies = {
      type = "keycloak_openid_client_authorization_group_policy";
      prefix = "openid_client_authz_group_policy";
      nameAttr = "name";
      scope = null;
      refs = {
        realm = realmRef;
        resource_server = {
          attr = "resource_server_id";
          targets = [
            {
              collection = "openid_clients";
              field = "resource_server_id";
            }
          ];
          managedOnly = true;
          required = true;
          description = "Key of the managed openid_client hosting this policy.";
        };
      };
      requiredAttrs = [
        "decision_strategy"
        "groups"
      ];
      description = "Policy granting access by group membership; each group block is `{ id; path; extend_children; }`.";
      attrs = {
        name = oStr "Policy name. Defaults to the attribute key.";
        description = oStr "Policy description.";
        decision_strategy = oStr "Decision strategy.";
        logic = oStr "Policy logic ('POSITIVE' or 'NEGATIVE').";
        groups_claim = oStr "Optional JWT claim whose value carries the group path.";
        groups = oListSub {
          id = rStr "Group id.";
          path = oStr "Group path (read from the API).";
          extend_children = oBool "Match descendants of the group as well.";
        } "List of `{ id; path; extend_children; }` blocks naming groups the policy applies to.";
      };
    };

    openid_client_authorization_js_policies = {
      type = "keycloak_openid_client_authorization_js_policy";
      prefix = "openid_client_authz_js_policy";
      nameAttr = "name";
      scope = null;
      refs = {
        realm = realmRef;
        resource_server = {
          attr = "resource_server_id";
          targets = [
            {
              collection = "openid_clients";
              field = "resource_server_id";
            }
          ];
          managedOnly = true;
          required = true;
          description = "Key of the managed openid_client hosting this policy.";
        };
      };
      requiredAttrs = [
        "decision_strategy"
        "code"
      ];
      description = "Policy implemented in JavaScript (requires the scripts feature).";
      attrs = {
        name = oStr "Policy name. Defaults to the attribute key.";
        description = oStr "Policy description.";
        decision_strategy = oStr "Decision strategy.";
        logic = oStr "Policy logic ('POSITIVE' or 'NEGATIVE').";
        type = oStr "Policy type discriminator ('js').";
        code = oStr "JavaScript source.";
      };
    };

    openid_client_authorization_role_policies = {
      type = "keycloak_openid_client_authorization_role_policy";
      prefix = "openid_client_authz_role_policy";
      nameAttr = "name";
      scope = null;
      refs = {
        realm = realmRef;
        resource_server = {
          attr = "resource_server_id";
          targets = [
            {
              collection = "openid_clients";
              field = "resource_server_id";
            }
          ];
          managedOnly = true;
          required = true;
          description = "Key of the managed openid_client hosting this policy.";
        };
      };
      requiredAttrs = [
        "decision_strategy"
        "role"
      ];
      description = "Policy granting access by realm or client role membership; each role block is `{ id; required = false; }`.";
      attrs = {
        name = oStr "Policy name. Defaults to the attribute key.";
        description = oStr "Policy description.";
        decision_strategy = oStr "Decision strategy.";
        logic = oStr "Policy logic ('POSITIVE' or 'NEGATIVE').";
        type = oStr "Policy type discriminator.";
        fetch_roles = oBool "Fetch role information on policy evaluation.";
        role = oListSub {
          id = rStr "Role id.";
          required = oBool "Treat the role as required (vs optional).";
        } "List of `{ id; required; }` blocks naming roles the policy applies to.";
      };
    };

    openid_client_authorization_time_policies = {
      type = "keycloak_openid_client_authorization_time_policy";
      prefix = "openid_client_authz_time_policy";
      nameAttr = "name";
      scope = null;
      refs = {
        realm = realmRef;
        resource_server = {
          attr = "resource_server_id";
          targets = [
            {
              collection = "openid_clients";
              field = "resource_server_id";
            }
          ];
          managedOnly = true;
          required = true;
          description = "Key of the managed openid_client hosting this policy.";
        };
      };
      requiredAttrs = [ "decision_strategy" ];
      description = "Policy granting access within a time window.";
      attrs = {
        name = oStr "Policy name. Defaults to the attribute key.";
        description = oStr "Policy description.";
        decision_strategy = oStr "Decision strategy.";
        logic = oStr "Policy logic ('POSITIVE' or 'NEGATIVE').";
        not_before = oStr "Date-time before which access is denied (`YYYY-MM-DD HH:MM:SS`).";
        not_on_or_after = oStr "Date-time on or after which access is denied.";
        day_month = oStr "Day-of-month window start.";
        day_month_end = oStr "Day-of-month window end.";
        month = oStr "Month window start.";
        month_end = oStr "Month window end.";
        year = oStr "Year window start.";
        year_end = oStr "Year window end.";
        hour = oStr "Hour-of-day window start.";
        hour_end = oStr "Hour-of-day window end.";
        minute = oStr "Minute-of-hour window start.";
        minute_end = oStr "Minute-of-hour window end.";
      };
    };

    ldap_user_federations = {
      type = "keycloak_ldap_user_federation";
      prefix = "ldap_user_federation";
      nameAttr = "name";
      scope = null;
      refs.realm = realmRef;
      secrets = [ "bind_credential" ];
      requiredAttrs = [
        "username_ldap_attribute"
        "rdn_ldap_attribute"
        "uuid_ldap_attribute"
        "user_object_classes"
        "connection_url"
        "users_dn"
      ];
      # `kerberos` and `cache` are TypeList+MaxItems:1 nested blocks --
      # declared as oSub here, but their JSON emission will be wrong
      # until R1 (block-list wrapping) lands. Avoid setting them.
      description = "LDAP user federations (per-realm), keyed by name.";
      attrs = {
        name = oStr "Federation name. Defaults to the attribute key.";
        enabled = oBool "Is the federation enabled?";
        priority = oInt "Evaluation priority (lower runs first).";
        import_enabled = oBool "Import users from LDAP into Keycloak's local DB.";
        edit_mode = oStr "'READ_ONLY' (default), 'WRITABLE', or 'UNSYNCED'.";
        sync_registrations = oBool "Write new user registrations back into LDAP.";
        vendor = oStr "LDAP vendor: 'OTHER' (default), 'EDIRECTORY', 'AD', 'RHDS', 'TIVOLI'.";
        username_ldap_attribute = oStr "LDAP attribute carrying the username.";
        rdn_ldap_attribute = oStr "LDAP RDN attribute.";
        uuid_ldap_attribute = oStr "LDAP attribute carrying a stable UUID.";
        user_object_classes = oListStr "LDAP objectClasses for users.";
        connection_url = oStr "LDAP connection URL (ldap[s]://host:port).";
        users_dn = oStr "Base DN under which users live.";
        bind_dn = oStr "DN used to authenticate to LDAP (omit for anonymous bind).";
        bind_credential = oStr "Password for bind_dn. Prefer `bind_credentialFile`.";
        custom_user_search_filter = oStr "Extra LDAP filter applied when looking up users.";
        krb_principal_attribute = oStr "LDAP attribute carrying the Kerberos principal.";
        debug = oStr "Enable LDAP debug logging ('true' / 'false').";
        search_scope = oStr "Search scope: 'ONE_LEVEL' (default) or 'SUBTREE'.";
        start_tls = oBool "Issue STARTTLS after connecting.";
        connection_pooling = oBool "Pool LDAP connections.";
        use_password_modify_extended_op = oBool "Use the LDAP password modify extended operation.";
        validate_password_policy = oBool "Validate passwords against the realm's password policy.";
        trust_email = oBool "Trust the email returned by LDAP without verification.";
        use_truststore_spi = oStr "Truststore SPI usage: 'ALWAYS', 'ONLY_FOR_LDAPS' (default), or 'NEVER'.";
        connection_timeout = oStr "LDAP connection timeout (duration string).";
        read_timeout = oStr "LDAP read timeout (duration string).";
        pagination = oBool "Enable LDAP pagination.";
        batch_size_for_sync = oInt "Number of users per sync batch.";
        full_sync_period = oInt "Full sync period in seconds (-1 disables).";
        changed_sync_period = oInt "Incremental sync period in seconds (-1 disables).";
        delete_default_mappers = oBool "Remove the default protocol mappers shipped with the federation.";
        kerberos = oSub {
          kerberos_realm = oStr "Kerberos realm.";
          server_principal = oStr "Kerberos service principal of the LDAP server.";
          key_tab = oStr "Path to the keytab file.";
          use_kerberos_for_password_authentication = oBool "Use Kerberos for password auth.";
        } "Kerberos integration sub-block. Needs R1 (block-list wrapping) to emit correctly.";
        cache = oSub {
          policy = oStr "Cache policy ('DEFAULT', 'EVICT_DAILY', 'EVICT_WEEKLY', 'MAX_LIFESPAN', 'NO_CACHE').";
          max_lifespan = oStr "Max lifespan (for MAX_LIFESPAN).";
          eviction_day = oStr "Eviction day (for EVICT_WEEKLY).";
          eviction_hour = oStr "Eviction hour.";
          eviction_minute = oStr "Eviction minute.";
        } "Cache configuration sub-block. Needs R1 (block-list wrapping) to emit correctly.";
      };
    };

    ldap_user_attribute_mappers = {
      type = "keycloak_ldap_user_attribute_mapper";
      prefix = "ldap_user_attribute_mapper";
      nameAttr = "name";
      scope = null;
      refs = {
        realm = realmRef;
        ldap_user_federation = ldapFederationIdRef;
      };
      requiredAttrs = [
        "user_model_attribute"
        "ldap_attribute"
      ];
      description = "Maps a keycloak user attribute to an LDAP attribute.";
      attrs = {
        name = oStr "Mapper name. Defaults to the attribute key.";
        user_model_attribute = oStr "Keycloak-side user attribute name.";
        ldap_attribute = oStr "LDAP attribute name.";
        read_only = oBool "Treat LDAP as the source of truth (writes are no-ops).";
        always_read_value_from_ldap = oBool "Re-read value from LDAP on every access.";
        is_mandatory_in_ldap = oBool "LDAP enforces presence of the attribute.";
        attribute_force_default = oBool "Force the default value when the LDAP attribute is missing.";
        attribute_default_value = oStr "Default value used when LDAP returns none.";
        is_binary_attribute = oBool "Treat the LDAP attribute as binary.";
      };
    };

    ldap_group_mappers = {
      type = "keycloak_ldap_group_mapper";
      prefix = "ldap_group_mapper";
      nameAttr = "name";
      scope = null;
      refs = {
        realm = realmRef;
        ldap_user_federation = ldapFederationIdRef;
      };
      requiredAttrs = [
        "ldap_groups_dn"
        "group_name_ldap_attribute"
        "group_object_classes"
        "membership_ldap_attribute"
        "membership_user_ldap_attribute"
      ];
      description = "Maps LDAP groups onto keycloak groups.";
      attrs = {
        name = oStr "Mapper name. Defaults to the attribute key.";
        ldap_groups_dn = oStr "Base DN under which groups live.";
        group_name_ldap_attribute = oStr "LDAP attribute carrying the group name.";
        group_object_classes = oListStr "LDAP objectClasses for groups.";
        preserve_group_inheritance = oBool "Preserve nested group hierarchy.";
        ignore_missing_groups = oBool "Ignore membership entries pointing to missing groups.";
        membership_ldap_attribute = oStr "LDAP attribute on the group holding member references.";
        membership_attribute_type = oStr "'DN' (default) or 'UID'.";
        membership_user_ldap_attribute = oStr "LDAP attribute on the user that uniquely identifies them.";
        groups_ldap_filter = oStr "Extra LDAP filter for group lookups.";
        mode = oStr "Mapper mode: 'READ_ONLY' (default), 'LDAP_ONLY', or 'IMPORT'.";
        user_roles_retrieve_strategy = oStr "Strategy for resolving a user's groups.";
        memberof_ldap_attribute = oStr "LDAP attribute holding direct group memberships (memberOf-style).";
        mapped_group_attributes = oListStr "LDAP group attributes preserved into keycloak.";
        drop_non_existing_groups_during_sync = oBool "Delete keycloak groups missing from LDAP during sync.";
        groups_path = oStr "Path under which mapped groups live (e.g. `/ldap-groups`).";
      };
    };

    ldap_role_mappers = {
      type = "keycloak_ldap_role_mapper";
      prefix = "ldap_role_mapper";
      nameAttr = "name";
      scope = null;
      refs = {
        realm = realmRef;
        ldap_user_federation = ldapFederationIdRef;
      };
      requiredAttrs = [
        "ldap_roles_dn"
        "role_name_ldap_attribute"
        "role_object_classes"
        "membership_ldap_attribute"
        "membership_user_ldap_attribute"
      ];
      description = "Maps LDAP roles onto keycloak realm or client roles.";
      attrs = {
        name = oStr "Mapper name. Defaults to the attribute key.";
        ldap_roles_dn = oStr "Base DN under which roles live.";
        role_name_ldap_attribute = oStr "LDAP attribute carrying the role name.";
        role_object_classes = oListStr "LDAP objectClasses for roles.";
        membership_ldap_attribute = oStr "LDAP attribute on the role holding member references.";
        membership_attribute_type = oStr "'DN' (default) or 'UID'.";
        membership_user_ldap_attribute = oStr "LDAP attribute on the user that uniquely identifies them.";
        roles_ldap_filter = oStr "Extra LDAP filter for role lookups.";
        mode = oStr "Mapper mode: 'READ_ONLY' (default), 'LDAP_ONLY', or 'IMPORT'.";
        user_roles_retrieve_strategy = oStr "Strategy for resolving a user's roles.";
        memberof_ldap_attribute = oStr "LDAP attribute holding direct role memberships.";
        use_realm_roles_mapping = oBool "Map onto realm roles (true) or client roles (false).";
        client_id = oStr "ClientId roles are scoped to when `use_realm_roles_mapping = false`.";
      };
    };

    ldap_hardcoded_role_mappers = {
      type = "keycloak_ldap_hardcoded_role_mapper";
      prefix = "ldap_hardcoded_role_mapper";
      nameAttr = "name";
      scope = null;
      refs = {
        realm = realmRef;
        ldap_user_federation = ldapFederationIdRef;
      };
      requiredAttrs = [ "role" ];
      description = "Grants a hardcoded role to every LDAP-federated user.";
      attrs = {
        name = oStr "Mapper name. Defaults to the attribute key.";
        role = oStr "Realm or `client.role` name granted.";
      };
    };

    ldap_hardcoded_attribute_mappers = {
      type = "keycloak_ldap_hardcoded_attribute_mapper";
      prefix = "ldap_hardcoded_attribute_mapper";
      nameAttr = "name";
      scope = null;
      refs = {
        realm = realmRef;
        ldap_user_federation = ldapFederationIdRef;
      };
      requiredAttrs = [
        "attribute_name"
        "attribute_value"
      ];
      description = "Sets a hardcoded user attribute on every LDAP-federated user.";
      attrs = {
        name = oStr "Mapper name. Defaults to the attribute key.";
        attribute_name = oStr "Name of the attribute to set.";
        attribute_value = oStr "Value of the attribute.";
      };
    };

    ldap_hardcoded_group_mappers = {
      type = "keycloak_ldap_hardcoded_group_mapper";
      prefix = "ldap_hardcoded_group_mapper";
      nameAttr = "name";
      scope = null;
      refs = {
        realm = realmRef;
        ldap_user_federation = ldapFederationIdRef;
      };
      requiredAttrs = [ "group" ];
      description = "Adds every LDAP-federated user to a hardcoded group.";
      attrs = {
        name = oStr "Mapper name. Defaults to the attribute key.";
        group = oStr "Group path (e.g. `/engineering`) every federated user joins.";
      };
    };

    ldap_msad_user_account_control_mappers = {
      type = "keycloak_ldap_msad_user_account_control_mapper";
      prefix = "ldap_msad_uac_mapper";
      nameAttr = "name";
      scope = null;
      refs = {
        realm = realmRef;
        ldap_user_federation = ldapFederationIdRef;
      };
      description = "MSAD userAccountControl integration mapper (enables / disables and locks out users).";
      attrs = {
        name = oStr "Mapper name. Defaults to the attribute key.";
        ldap_password_policy_hints_enabled = oBool "Forward keycloak password-policy hints to MSAD.";
      };
    };

    ldap_msad_lds_user_account_control_mappers = {
      type = "keycloak_ldap_msad_lds_user_account_control_mapper";
      prefix = "ldap_msad_lds_uac_mapper";
      nameAttr = "name";
      scope = null;
      refs = {
        realm = realmRef;
        ldap_user_federation = ldapFederationIdRef;
      };
      description = "MSAD LDS userAccountControl integration mapper.";
      attrs = {
        name = oStr "Mapper name. Defaults to the attribute key.";
      };
    };

    ldap_full_name_mappers = {
      type = "keycloak_ldap_full_name_mapper";
      prefix = "ldap_full_name_mapper";
      nameAttr = "name";
      scope = null;
      refs = {
        realm = realmRef;
        ldap_user_federation = ldapFederationIdRef;
      };
      requiredAttrs = [ "ldap_full_name_attribute" ];
      description = "Splits/joins a single LDAP full-name attribute into keycloak's first / last name fields.";
      attrs = {
        name = oStr "Mapper name. Defaults to the attribute key.";
        ldap_full_name_attribute = oStr "LDAP attribute carrying the full name.";
        read_only = oBool "Treat LDAP as source of truth.";
        write_only = oBool "Only push the full name back to LDAP.";
      };
    };

    ldap_custom_mappers = {
      type = "keycloak_ldap_custom_mapper";
      prefix = "ldap_custom_mapper";
      nameAttr = "name";
      scope = null;
      refs = {
        realm = realmRef;
        ldap_user_federation = ldapFederationIdRef;
      };
      requiredAttrs = [
        "provider_id"
        "provider_type"
      ];
      description = "Escape hatch for an LDAP mapper implementation without a dedicated typed resource.";
      attrs = {
        name = oStr "Mapper name. Defaults to the attribute key.";
        provider_id = oStr "Provider-id of the mapper implementation.";
        provider_type = oStr "SPI type the provider implements.";
        config = oAttrsStr "Mapper-specific configuration.";
      };
    };

    openid_client_authorization_user_policies = {
      type = "keycloak_openid_client_authorization_user_policy";
      prefix = "openid_client_authz_user_policy";
      nameAttr = "name";
      scope = null;
      refs = {
        realm = realmRef;
        resource_server = {
          attr = "resource_server_id";
          targets = [
            {
              collection = "openid_clients";
              field = "resource_server_id";
            }
          ];
          managedOnly = true;
          required = true;
          description = "Key of the managed openid_client hosting this policy.";
        };
      };
      requiredAttrs = [
        "decision_strategy"
        "users"
      ];
      description = "Policy granting access to a specific set of users.";
      attrs = {
        name = oStr "Policy name. Defaults to the attribute key.";
        description = oStr "Policy description.";
        decision_strategy = oStr "Decision strategy.";
        logic = oStr "Policy logic ('POSITIVE' or 'NEGATIVE').";
        users = oListStr "User ids the policy applies to.";
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
