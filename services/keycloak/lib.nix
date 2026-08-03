# keycloak-provider specifics: executor, resource surface, provider block.
#
# The resource surface is *derived* from the vendored provider schema
# (./provider-schema.json, parsed by ./schema.nix) via
# ../../modules/lib/tf-schema.nix. What stays hand-written is only what a schema
# cannot state: the NixOS-facing collection descriptions, the reference graph
# between collections, and the odd documented correction. A provider bump that
# adds, removes or retypes anything is then an eval-time error rather than an
# apply-time surprise.
#
# Shared helpers (option helpers, renderer, reconciler) live in modules/lib.
{ pkgs, nixTfSchema }:
let
  genlib = import ../../modules/lib { inherit pkgs; };
  tfSchema = import ../../modules/lib/tf-schema.nix { inherit pkgs nixTfSchema; };
  provider = pkgs.terraform-providers.keycloak_keycloak;
  providerVersion = provider.version;
  # provider source address; also keys the vendored provider schema.
  providerSource = "keycloak/keycloak";
  runtimePrefix = "services.keycloak.runtime";

  # tf-var names for the service-account oauth2 client the reconciler uses.
  tokenVar = "keycloak_client_secret";
  clientIdVar = "keycloak_client_id";

  executor = pkgs.opentofu.withPlugins (_: [ provider ]);

  # most non-realm resources reference their realm by numeric id, which
  # the user can't know up front -- resolve it by managed key instead.
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
  # protocol mappers attach to a client *or* a client scope -- never
  # both, never neither (the provider rejects either).
  clientOrScopeOneOf = [
    [
      "client"
      "client_scope"
    ]
  ];

  # SAML counterparts of the openid refs above.
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

  # identity providers reference the realm by its alias (name) -- the
  # provider's `realm` attribute, not `realm_id`.
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

  # every ldap_*_mapper resolves its parent federation by id.
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

  # IdP mappers reference an IdP by alias; the alias can belong to
  # any of the eight IdP collections.
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
      {
        collection = "oidc_openshift_v4_identity_providers";
        field = "alias";
      }
      {
        collection = "spiffe_identity_providers";
        field = "alias";
      }
    ];
    managedOnly = false;
    required = true;
    description = "Alias of the managed identity provider (in any IdP collection) this mapper attaches to, or a literal alias.";
  };

  # generic mappers attach to either an openid or a saml client/scope.
  # multi-target: a managed key from either collection resolves; an
  # unknown string falls through as a literal.
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
  # The keycloak/keycloak resource surface. Per collection, only the facts the
  # schema does not carry (see modules/lib/tf-schema.nix for the full overlay
  # vocabulary):
  #   type         the `keycloak_*` resource type in the schema
  #   prefix       unique Terraform label prefix
  #   nameAttr     attribute defaulted from the collection key (or null)
  #   scope        unused here -- keycloak authenticates a service account, not
  #                a scoped token
  #   refs         parent links resolved to references against managed siblings
  #   description  the collection's NixOS option description
  generated = tfSchema.mkResourceTypes {
    schema = import ./schema.nix;
    inherit provider runtimePrefix;
    source = providerSource;
    # every sdk/v2 resource carries a synthetic `id`; it is the resource's own
    # identity, computed on apply, and nothing a configuration declares.
    omitEverywhere = [ "id" ];
    resources = {
      realms = {
        type = "keycloak_realm";
        prefix = "realm";
        nameAttr = "realm";
        scope = null;
        refs = { };
        description = "Keycloak realms, keyed by realm name.";
        # Computed identity attribute; nothing to declare.
        omit = [ "internal_id" ];
      };
      roles = {
        type = "keycloak_role";
        prefix = "role";
        nameAttr = "name";
        scope = null;
        refs = {
          realm = realmRef;
          composite_roles = {
            attr = "composite_roles";
            targets = [
              {
                collection = "roles";
                field = "id";
              }
            ];
            managedOnly = false;
            required = false;
            list = true;
            description = "Roles composited into this role. Each entry is a managed role key (resolved to its id) or a literal role UUID.";
          };
          # a role scoped to a client rather than to the realm.
          client = anyClientOptionalRef;
        };
        description = "Keycloak roles (realm-level by default), keyed by role name.";
      };
      default_roles = {
        type = "keycloak_default_roles";
        prefix = "default_roles";
        nameAttr = null;
        scope = null;
        refs = {
          realm = realmRef;
          default_roles = {
            attr = "default_roles";
            targets = [
              {
                collection = "roles";
                field = "name";
              }
            ];
            managedOnly = false;
            required = true;
            list = true;
            description = "Role names auto-granted to every new user. Each entry is a managed role key (resolved to its name) or a literal role name (built-ins like 'offline_access' work as literals).";
          };
        };
        description = "Realm-level default roles auto-granted to new users, keyed by an arbitrary label.";
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
          organization = {
            attr = "organization_id";
            targets = [
              {
                collection = "organizations";
                field = "id";
              }
            ];
            managedOnly = true;
            required = false;
            description = "Optional organization (key of a managed organization) this group belongs to.";
          };
        };
        description = "Keycloak groups, keyed by group name.";
      };
      default_groups = {
        type = "keycloak_default_groups";
        prefix = "default_groups";
        nameAttr = null;
        scope = null;
        refs = {
          realm = realmRef;
          group_ids = {
            attr = "group_ids";
            targets = [
              {
                collection = "groups";
                field = "id";
              }
            ];
            managedOnly = false;
            required = true;
            list = true;
            description = "Groups new users auto-join. Each entry is a managed group key (resolved to its id) or a literal group UUID.";
          };
        };
        description = "Realm-level default groups auto-joined by new users, keyed by an arbitrary label.";
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
          members = {
            attr = "members";
            targets = [
              {
                collection = "users";
                field = "username";
              }
            ];
            managedOnly = false;
            required = true;
            list = true;
            description = "Users to add to the group. Each entry is a managed user key (resolved to its username) or a literal username.";
          };
        };
        description = "Keycloak group memberships, keyed by an arbitrary label.";
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
          role_ids = {
            attr = "role_ids";
            targets = [
              {
                collection = "roles";
                field = "id";
              }
            ];
            managedOnly = false;
            required = true;
            list = true;
            description = "Roles granted to the group. Each entry is a managed role key (resolved to its id) or a literal role UUID.";
          };
        };
        description = "Role assignments for a group, keyed by an arbitrary label.";
      };
      users = {
        type = "keycloak_user";
        prefix = "user";
        nameAttr = "username";
        scope = null;
        refs.realm = realmRef;
        description = "Keycloak users, keyed by username (must be lowercase).";
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
          role_ids = {
            attr = "role_ids";
            targets = [
              {
                collection = "roles";
                field = "id";
              }
            ];
            managedOnly = false;
            required = true;
            list = true;
            description = "Roles granted to the user. Each entry is a managed role key (resolved to its id) or a literal role UUID.";
          };
        };
        description = "Role assignments for a user, keyed by an arbitrary label.";
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
          group_ids = {
            attr = "group_ids";
            targets = [
              {
                collection = "groups";
                field = "id";
              }
            ];
            managedOnly = false;
            required = true;
            list = true;
            description = "Groups the user joins. Each entry is a managed group key (resolved to its id) or a literal group UUID.";
          };
        };
        description = "Group memberships for a user, keyed by an arbitrary label.";
      };
      openid_client_scopes = {
        type = "keycloak_openid_client_scope";
        prefix = "openid_client_scope";
        nameAttr = "name";
        scope = null;
        refs.realm = realmRef;
        description = "OpenID client scopes (per-realm), keyed by scope name.";
      };
      saml_client_scopes = {
        type = "keycloak_saml_client_scope";
        prefix = "saml_client_scope";
        nameAttr = "name";
        scope = null;
        refs.realm = realmRef;
        description = "SAML client scopes (per-realm), keyed by scope name.";
      };
      openid_clients = {
        type = "keycloak_openid_client";
        prefix = "openid_client";
        nameAttr = "client_id";
        scope = null;
        refs.realm = realmRef;
        description = "OpenID Connect clients (per-realm), keyed by clientId.";
        # Write-only twins of `client_secret`: they take an ephemeral value,
        # which a rendered `.tf.json` cannot carry. `client_secretFile` covers
        # the same ground through `LoadCredential=`.
        omit = [
          "client_secret_wo"
          "client_secret_wo_version"
        ];
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
          default_scopes = {
            attr = "default_scopes";
            targets = [
              {
                collection = "openid_client_scopes";
                field = "name";
              }
            ];
            managedOnly = false;
            required = true;
            list = true;
            description = "Scopes attached by default. Each entry is a managed openid_client_scope key (resolved to its name) or a literal scope name (built-ins like 'profile' / 'email' work as literals).";
          };
        };
        description = "Default OAuth2 scopes auto-attached to a client, keyed by an arbitrary label.";
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
          optional_scopes = {
            attr = "optional_scopes";
            targets = [
              {
                collection = "openid_client_scopes";
                field = "name";
              }
            ];
            managedOnly = false;
            required = true;
            list = true;
            description = "Optionally-attached scopes. Each entry is a managed openid_client_scope key (resolved to its name) or a literal scope name.";
          };
        };
        description = "Optional OAuth2 scopes available to a client, keyed by an arbitrary label.";
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
        description = "Grant a per-client role to a service-account user, keyed by an arbitrary label.";
      };
      openid_client_service_account_realm_roles = {
        type = "keycloak_openid_client_service_account_realm_role";
        prefix = "openid_client_sa_realm_role";
        nameAttr = null;
        scope = null;
        refs.realm = realmRef;
        description = "Grant a realm-level role to a service-account user, keyed by an arbitrary label.";
      };
      saml_clients = {
        type = "keycloak_saml_client";
        prefix = "saml_client";
        nameAttr = "client_id";
        scope = null;
        refs.realm = realmRef;
        # signing_private_key isn't marked Sensitive upstream but is a
        # private key; expose <attr>File so it stays out of the store.
        description = "SAML clients (per-realm), keyed by clientId.";
        extraSecrets = [
          "signing_private_key"
        ];
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
          default_scopes = {
            attr = "default_scopes";
            targets = [
              {
                collection = "saml_client_scopes";
                field = "name";
              }
            ];
            managedOnly = false;
            required = true;
            list = true;
            description = "SAML scopes attached by default. Each entry is a managed saml_client_scope key (resolved to its name) or a literal scope name.";
          };
        };
        description = "Default SAML scopes auto-attached to a SAML client, keyed by an arbitrary label.";
      };
      # OpenID protocol mappers: one collection per mapper type. all share
      # realm + (client | client_scope) refs.
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
        description = "OpenID protocol mapper that maps a user attribute to a claim.";
        oneOfRefs = clientOrScopeOneOf;
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
        description = "OpenID protocol mapper that maps a built-in user property (e.g. `email`, `username`) to a claim.";
        oneOfRefs = clientOrScopeOneOf;
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
        description = "OpenID protocol mapper that maps group memberships to a claim.";
        oneOfRefs = clientOrScopeOneOf;
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
        oneOfRefs = clientOrScopeOneOf;
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
        oneOfRefs = clientOrScopeOneOf;
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
        description = "OpenID protocol mapper that adds a hardcoded claim with a fixed value.";
        oneOfRefs = clientOrScopeOneOf;
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
        oneOfRefs = clientOrScopeOneOf;
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
        oneOfRefs = clientOrScopeOneOf;
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
        description = "OpenID protocol mapper that adds a hardcoded role to issued tokens.";
        oneOfRefs = clientOrScopeOneOf;
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
        description = "OpenID protocol mapper that maps the user's realm roles to a claim.";
        oneOfRefs = clientOrScopeOneOf;
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
        description = "OpenID protocol mapper that maps the user's roles on a specific client to a claim.";
        oneOfRefs = clientOrScopeOneOf;
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
        description = "OpenID protocol mapper that maps a user session note to a claim.";
        oneOfRefs = clientOrScopeOneOf;
        requiredAttrs = [
          "session_note"
        ];
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
        description = "SAML mapper that exposes a user attribute as a SAML attribute.";
        oneOfRefs = clientOrScopeOneOf;
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
        description = "SAML mapper that exposes a built-in user property as a SAML attribute.";
        oneOfRefs = clientOrScopeOneOf;
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
        description = "Generic protocol mapper escape hatch (for mappers without a dedicated typed resource).";
        oneOfRefs = clientOrScopeOneOf;
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
        description = "Generic protocol mapper attached to a specific client (without a dedicated typed resource).";
        oneOfRefs = clientOrScopeOneOf;
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
        description = "Generic role-scope mapper that attaches a role to a client / client scope, keyed by an arbitrary label.";
        oneOfRefs = clientOrScopeOneOf;
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
        description = "Generic role-scope mapper attached to a specific client (deprecated alias kept for completeness).";
        oneOfRefs = clientOrScopeOneOf;
      };
      oidc_identity_providers = {
        type = "keycloak_oidc_identity_provider";
        prefix = "oidc_idp";
        nameAttr = "alias";
        scope = null;
        refs.realm = realmAliasRef;
        description = "Generic OIDC identity providers (per-realm), keyed by alias.";
        # Write-only twins of `client_secret`: they take an ephemeral value,
        # which a rendered `.tf.json` cannot carry. `client_secretFile` covers
        # the same ground through `LoadCredential=`.
        omit = [
          "client_secret_wo"
          "client_secret_wo_version"
        ];
      };
      saml_identity_providers = {
        type = "keycloak_saml_identity_provider";
        prefix = "saml_idp";
        nameAttr = "alias";
        scope = null;
        refs.realm = realmAliasRef;
        description = "SAML identity providers (per-realm), keyed by alias.";
      };
      oidc_google_identity_providers = {
        type = "keycloak_oidc_google_identity_provider";
        prefix = "oidc_google_idp";
        nameAttr = "alias";
        scope = null;
        refs.realm = realmAliasRef;
        description = "Google OIDC identity providers (per-realm), keyed by alias (defaults to 'google').";
      };
      oidc_facebook_identity_providers = {
        type = "keycloak_oidc_facebook_identity_provider";
        prefix = "oidc_facebook_idp";
        nameAttr = "alias";
        scope = null;
        refs.realm = realmAliasRef;
        description = "Facebook OIDC identity providers (per-realm), keyed by alias (defaults to 'facebook').";
      };
      oidc_github_identity_providers = {
        type = "keycloak_oidc_github_identity_provider";
        prefix = "oidc_github_idp";
        nameAttr = "alias";
        scope = null;
        refs.realm = realmAliasRef;
        description = "GitHub OIDC identity providers (per-realm), keyed by alias (defaults to 'github').";
      };
      kubernetes_identity_providers = {
        type = "keycloak_kubernetes_identity_provider";
        prefix = "kubernetes_idp";
        nameAttr = "alias";
        scope = null;
        refs.realm = realmAliasRef;
        description = "Kubernetes OIDC identity providers (per-realm), keyed by alias.";
      };
      oidc_openshift_v4_identity_providers = {
        type = "keycloak_oidc_openshift_v4_identity_provider";
        prefix = "oidc_openshift_v4_idp";
        nameAttr = "alias";
        scope = null;
        refs.realm = realmAliasRef;
        description = "OpenShift 4 OIDC identity providers (per-realm), keyed by alias (defaults to 'openshift-v4').";
      };
      spiffe_identity_providers = {
        type = "keycloak_spiffe_identity_provider";
        prefix = "spiffe_idp";
        nameAttr = "alias";
        scope = null;
        refs.realm = realmAliasRef;
        description = "SPIFFE identity providers (per-realm), keyed by alias.";
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
        description = "Sets a hardcoded user (or session-note) attribute on every federated user.";
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
        description = "Imports an attribute / claim from the IdP onto the federated user.";
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
        description = "Grants a role to federated users whose IdP attribute / claim matches a value.";
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
        description = "Escape hatch for an IdP mapper implementation without a dedicated typed resource.";
      };
      authentication_flows = {
        type = "keycloak_authentication_flow";
        prefix = "authentication_flow";
        nameAttr = "alias";
        scope = null;
        refs.realm = realmRef;
        description = "Top-level authentication flows (per-realm), keyed by alias.";
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
        description = "Authentication executions inside a flow / subflow, keyed by an arbitrary label.";
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
        description = "Per-execution configuration map, keyed by config alias.";
      };
      authentication_bindings = {
        type = "keycloak_authentication_bindings";
        prefix = "authentication_bindings";
        nameAttr = null;
        scope = null;
        refs.realm = realmRef;
        description = "Realm-level authentication flow bindings (browser / registration / direct grant / etc.), keyed by an arbitrary label.";
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
      };
      openid_client_aggregate_policies = {
        type = "keycloak_openid_client_aggregate_policy";
        prefix = "openid_client_aggregate_policy";
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
        description = "Aggregate policy combining other policies under a decision strategy.";
      };
      openid_client_client_policies = {
        type = "keycloak_openid_client_client_policy";
        prefix = "openid_client_client_policy";
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
        description = "Policy granting access to a specific set of clients.";
        requiredAttrs = [
          "decision_strategy"
        ];
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
        description = "Policy granting access by client scope membership; each scope block is `{ id; required = false; }`.";
        requiredAttrs = [
          "decision_strategy"
        ];
      };
      openid_client_group_policies = {
        type = "keycloak_openid_client_group_policy";
        prefix = "openid_client_group_policy";
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
        description = "Policy granting access by group membership; each group block is `{ id; path; extend_children; }`.";
      };
      openid_client_regex_policies = {
        type = "keycloak_openid_client_regex_policy";
        prefix = "openid_client_regex_policy";
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
        description = "Policy granting access when a token claim matches a regular expression.";
      };
      openid_client_role_policies = {
        type = "keycloak_openid_client_role_policy";
        prefix = "openid_client_role_policy";
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
        description = "Policy granting access by realm or client role membership; each role block is `{ id; required = false; }`.";
        requiredAttrs = [
          "decision_strategy"
        ];
      };
      openid_client_time_policies = {
        type = "keycloak_openid_client_time_policy";
        prefix = "openid_client_time_policy";
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
        description = "Policy granting access within a time window.";
      };
      ldap_user_federations = {
        type = "keycloak_ldap_user_federation";
        prefix = "ldap_user_federation";
        nameAttr = "name";
        scope = null;
        refs.realm = realmRef;
        description = "LDAP user federations (per-realm), keyed by name.";
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
        description = "Maps a keycloak user attribute to an LDAP attribute.";
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
        description = "Maps LDAP groups onto keycloak groups.";
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
        description = "Maps LDAP roles onto keycloak realm or client roles.";
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
        description = "Grants a hardcoded role to every LDAP-federated user.";
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
        description = "Sets a hardcoded user attribute on every LDAP-federated user.";
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
        description = "Adds every LDAP-federated user to a hardcoded group.";
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
        description = "Splits/joins a single LDAP full-name attribute into keycloak's first / last name fields.";
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
        description = "Escape hatch for an LDAP mapper implementation without a dedicated typed resource.";
      };
      custom_user_federations = {
        type = "keycloak_custom_user_federation";
        prefix = "custom_user_federation";
        nameAttr = "name";
        scope = null;
        refs.realm = realmRef;
        description = "Custom user federation backed by a JPA / SPI provider.";
      };
      realm_keystore_aes_generateds = {
        type = "keycloak_realm_keystore_aes_generated";
        prefix = "realm_keystore_aes_generated";
        nameAttr = "name";
        scope = null;
        refs.realm = realmRef;
        description = "AES keystore generated by Keycloak.";
      };
      realm_keystore_ecdsa_generateds = {
        type = "keycloak_realm_keystore_ecdsa_generated";
        prefix = "realm_keystore_ecdsa_generated";
        nameAttr = "name";
        scope = null;
        refs.realm = realmRef;
        description = "ECDSA keystore generated by Keycloak.";
      };
      realm_keystore_hmac_generateds = {
        type = "keycloak_realm_keystore_hmac_generated";
        prefix = "realm_keystore_hmac_generated";
        nameAttr = "name";
        scope = null;
        refs.realm = realmRef;
        description = "HMAC keystore generated by Keycloak.";
      };
      realm_keystore_java_keystores = {
        type = "keycloak_realm_keystore_java_keystore";
        prefix = "realm_keystore_java_keystore";
        nameAttr = "name";
        scope = null;
        refs.realm = realmRef;
        description = "Keystore backed by a Java KeyStore (JKS) file.";
        extraSecrets = [
          "key_password"
          "keystore_password"
        ];
      };
      realm_keystore_rsas = {
        type = "keycloak_realm_keystore_rsa";
        prefix = "realm_keystore_rsa";
        nameAttr = "name";
        scope = null;
        refs.realm = realmRef;
        # private_key and certificate are PEM material; expose <attr>File
        # for both even though only private_key is technically secret.
        description = "Keystore backed by an externally-provided RSA private key / certificate pair.";
        extraSecrets = [
          "certificate"
          "private_key"
        ];
      };
      realm_keystore_rsa_generateds = {
        type = "keycloak_realm_keystore_rsa_generated";
        prefix = "realm_keystore_rsa_generated";
        nameAttr = "name";
        scope = null;
        refs.realm = realmRef;
        description = "RSA keystore generated by Keycloak.";
      };
      hardcoded_attribute_mappers = {
        type = "keycloak_hardcoded_attribute_mapper";
        prefix = "hardcoded_attribute_mapper";
        nameAttr = "name";
        scope = null;
        refs = {
          realm = realmRef;
          ldap_user_federation = ldapFederationIdRef;
        };
        description = "Sets a hardcoded user attribute on every federated user. Distinct from ldap_hardcoded_attribute_mapper and hardcoded_attribute_identity_provider_mapper.";
      };
      openid_client_user_policies = {
        type = "keycloak_openid_client_user_policy";
        prefix = "openid_client_user_policy";
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
        description = "Policy granting access to a specific set of users.";
      };
      required_actions = {
        type = "keycloak_required_action";
        prefix = "required_action";
        nameAttr = "alias";
        scope = null;
        refs.realm = realmRef;
        description = "Realm required actions (per-realm), keyed by alias.";
      };
      realm_events = {
        type = "keycloak_realm_events";
        prefix = "realm_events";
        nameAttr = null;
        scope = null;
        refs.realm = realmRef;
        description = "Per-realm event logging configuration, keyed by an arbitrary label.";
      };
      realm_localizations = {
        type = "keycloak_realm_localization";
        prefix = "realm_localization";
        nameAttr = "locale";
        scope = null;
        refs.realm = realmRef;
        description = "Per-realm i18n message bundle, keyed by locale.";
      };
      realm_default_client_scopes = {
        type = "keycloak_realm_default_client_scopes";
        prefix = "realm_default_client_scopes";
        nameAttr = null;
        scope = null;
        refs = {
          realm = realmRef;
          default_scopes = {
            attr = "default_scopes";
            targets = [
              {
                collection = "openid_client_scopes";
                field = "name";
              }
              {
                collection = "saml_client_scopes";
                field = "name";
              }
            ];
            managedOnly = false;
            required = true;
            list = true;
            description = "Scope names auto-attached as default to every new client. Each entry is a managed openid/saml client_scope key (resolved to its name) or a literal scope name.";
          };
        };
        description = "Realm-wide default client-scope binding (set of scope names), keyed by an arbitrary label. Distinct from realms.<r>.default_default_client_scopes, which is a free-form realm attribute.";
      };
      realm_optional_client_scopes = {
        type = "keycloak_realm_optional_client_scopes";
        prefix = "realm_optional_client_scopes";
        nameAttr = null;
        scope = null;
        refs = {
          realm = realmRef;
          optional_scopes = {
            attr = "optional_scopes";
            targets = [
              {
                collection = "openid_client_scopes";
                field = "name";
              }
              {
                collection = "saml_client_scopes";
                field = "name";
              }
            ];
            managedOnly = false;
            required = true;
            list = true;
            description = "Scope names available as optional to every new client. Each entry is a managed openid/saml client_scope key (resolved to its name) or a literal scope name.";
          };
        };
        description = "Realm-wide optional client-scope binding (set of scope names), keyed by an arbitrary label.";
      };
      organizations = {
        type = "keycloak_organization";
        prefix = "organization";
        nameAttr = "name";
        scope = null;
        refs.realm = realmAliasRef;
        description = "Keycloak organizations (per-realm, requires the organizations feature), keyed by name.";
      };
      identity_provider_token_exchange_scope_permissions = {
        type = "keycloak_identity_provider_token_exchange_scope_permission";
        prefix = "idp_token_exchange_perm";
        nameAttr = null;
        scope = null;
        refs.realm = realmRef;
        description = "Per-IdP token-exchange permission policy granting a set of clients access to the IdP's token-exchange scope.";
      };
      realm_user_profiles = {
        type = "keycloak_realm_user_profile";
        prefix = "realm_user_profile";
        nameAttr = null;
        scope = null;
        refs.realm = realmRef;
        # nested block inside a list element; wrapBlocks recurses through
        # the list, so the dotted path matches.
        description = "Per-realm user-profile schema (attribute declarations + groups). Keyed by an arbitrary label (one resource per realm).";
      };
      realm_client_policy_profiles = {
        type = "keycloak_realm_client_policy_profile";
        prefix = "realm_client_policy_profile";
        nameAttr = "name";
        scope = null;
        refs.realm = realmRef;
        description = "Realm client-policy profile, listing executors that enforce a client policy.";
      };
      realm_client_policy_profile_policies = {
        type = "keycloak_realm_client_policy_profile_policy";
        prefix = "realm_client_policy_profile_policy";
        nameAttr = "name";
        scope = null;
        refs = {
          realm = realmRef;
          profiles = {
            attr = "profiles";
            targets = [
              {
                collection = "realm_client_policy_profiles";
                field = "name";
              }
            ];
            managedOnly = false;
            required = true;
            list = true;
            description = "Names of client-policy profiles this policy applies. Each entry is a managed realm_client_policy_profile key (resolved to its name) or a literal profile name.";
          };
        };
        description = "Realm client-policy policy binding a set of profiles to a set of conditions.";
      };
      group_permissions = {
        type = "keycloak_group_permissions";
        prefix = "group_permissions";
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
            description = "Key of the managed group these fine-grained permissions apply to.";
          };
        };
        # every scope_* attr is a MaxItems:1 nested block.
        description = "Fine-grained authorization permissions for a group; each scope_* attr binds a scope to a `{ decision_strategy; policies; description; }` block.";
      };
      openid_client_permissions = {
        type = "keycloak_openid_client_permissions";
        prefix = "openid_client_permissions";
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
            description = "Key of the managed openid_client these fine-grained permissions apply to.";
          };
        };
        description = "Fine-grained authorization permissions on an openid_client; each scope_* attr binds a scope to a `{ decision_strategy; policies; description; }` block.";
      };
      users_permissions = {
        type = "keycloak_users_permissions";
        prefix = "users_permissions";
        nameAttr = null;
        scope = null;
        refs.realm = realmRef;
        description = "Fine-grained authorization permissions on the realm's users collection; each scope_* attr binds a scope to a `{ decision_strategy; policies; description; }` block.";
      };
      workflows = {
        type = "keycloak_workflow";
        prefix = "workflow";
        nameAttr = "name";
        scope = null;
        refs.realm = realmAliasRef;
        description = "Realm workflows: an event trigger (`on`) plus an ordered list of `step` actions, keyed by workflow name.";
      };
    };
  };
  inherit (generated) resourceTypes;

  keycloakTfConfig = genlib.mkTfConfig {
    inherit
      resourceTypes
      providerVersion
      providerSource
      tokenVar
      ;
    providerName = "keycloak";
    inherit runtimePrefix;
    extraSensitiveVars = [ clientIdVar ];
    providerBlock = cfg: {
      url = cfg.baseUrl;
      realm = cfg.adminRealm;
      client_id = "\${var.${clientIdVar}}";
      client_secret = "\${var.${tokenVar}}";
    };
  };
in
{
  inherit
    provider
    providerSource
    resourceTypes
    keycloakTfConfig
    clientIdVar
    ;
  inherit (generated) checks coverage;
  resourceOptions = genlib.resourceOptions resourceTypes;
  mkReconcileService = args: genlib.mkReconcileService (args // { inherit executor tokenVar; });
}
