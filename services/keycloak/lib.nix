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
{ pkgs, nix-tf-schema }:
let
  genlib = import ../../modules/lib { inherit pkgs; };
  tfSchema = import ../../modules/lib/tf-schema.nix { inherit pkgs nix-tf-schema; };
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
    targets = [
      {
        type = "keycloak_realm";
        field = "id";
      }
    ];
    managedOnly = true;
    description = "Key of the managed realm (services.keycloak.runtime.realms.<name>) this belongs to.";
  };

  # optional refs to a managed openid_client / openid_client_scope, used by
  # all openid protocol mappers (mutually exclusive at the provider).
  openidClientOptionalRef = {
    targets = [
      {
        type = "keycloak_openid_client";
        field = "id";
      }
    ];
    managedOnly = true;
    description = "Optional managed OpenID client this mapper attaches to.";
  };
  openidClientScopeOptionalRef = {
    targets = [
      {
        type = "keycloak_openid_client_scope";
        field = "id";
      }
    ];
    managedOnly = true;
    description = "Optional managed OpenID client scope this mapper attaches to.";
  };
  # protocol mappers attach to a client *or* a client scope -- never
  # both, never neither (the provider rejects either).
  clientOrScopeOneOf = [
    [
      "client_id"
      "client_scope_id"
    ]
  ];

  # SAML counterparts of the openid refs above.
  samlClientOptionalRef = {
    targets = [
      {
        type = "keycloak_saml_client";
        field = "id";
      }
    ];
    managedOnly = true;
    description = "Optional managed SAML client this mapper attaches to.";
  };
  samlClientScopeOptionalRef = {
    targets = [
      {
        type = "keycloak_saml_client_scope";
        field = "id";
      }
    ];
    managedOnly = true;
    description = "Optional managed SAML client scope this mapper attaches to.";
  };

  # identity providers reference the realm by its alias (name) -- the
  # provider's `realm` attribute, not `realm_id`.
  realmAliasRef = {
    targets = [
      {
        type = "keycloak_realm";
        field = "realm";
      }
    ];
    managedOnly = true;
    description = "Key of the managed realm (services.keycloak.runtime.realms.<name>) the IdP lives in.";
  };

  # every ldap_*_mapper resolves its parent federation by id.
  ldapFederationIdRef = {
    targets = [
      {
        type = "keycloak_ldap_user_federation";
        field = "id";
      }
    ];
    managedOnly = true;
    description = "Key of the managed LDAP user federation (services.keycloak.runtime.ldap_user_federations.<name>) this mapper attaches to.";
  };

  # IdP mappers reference an IdP by alias; the alias can belong to
  # any of the nine IdP collections.
  idpAliasRequiredRef = {
    targets = [
      {
        type = "keycloak_oidc_identity_provider";
        field = "alias";
      }
      {
        type = "keycloak_saml_identity_provider";
        field = "alias";
      }
      {
        type = "keycloak_oidc_google_identity_provider";
        field = "alias";
      }
      {
        type = "keycloak_oidc_facebook_identity_provider";
        field = "alias";
      }
      {
        type = "keycloak_oidc_github_identity_provider";
        field = "alias";
      }
      {
        type = "keycloak_kubernetes_identity_provider";
        field = "alias";
      }
      {
        type = "keycloak_oidc_openshift_v4_identity_provider";
        field = "alias";
      }
      {
        type = "keycloak_spiffe_identity_provider";
        field = "alias";
      }
      {
        type = "keycloak_oidc_microsoft_identity_provider";
        field = "alias";
      }
    ];
    managedOnly = false;
    description = "Alias of the managed identity provider (in any IdP collection) this mapper attaches to, or a literal alias.";
  };

  # generic mappers attach to either an openid or a saml client/scope.
  # multi-target: a managed key from either collection resolves; an
  # unknown string falls through as a literal.
  anyClientOptionalRef = {
    targets = [
      {
        type = "keycloak_openid_client";
        field = "id";
      }
      {
        type = "keycloak_saml_client";
        field = "id";
      }
    ];
    managedOnly = false;
    description = "Optional managed client (openid or saml) this mapper attaches to.";
  };
  anyClientScopeOptionalRef = {
    targets = [
      {
        type = "keycloak_openid_client_scope";
        field = "id";
      }
      {
        type = "keycloak_saml_client_scope";
        field = "id";
      }
    ];
    managedOnly = false;
    description = "Optional managed client scope (openid or saml) this mapper attaches to.";
  };
  # The keycloak/keycloak resource surface, keyed by resource type. Each type
  # becomes the collection `services.keycloak.runtime.<plural>`
  # (`keycloak_realm` -> `realms`). Per type, only the facts the schema does not
  # carry (see modules/lib/tf-schema.nix for the full overlay vocabulary):
  #   nameAttr     attribute the collection key fills in, where it is not `name`
  #   refs         parent links resolved to references against managed siblings
  #   description  the collection's NixOS option description
  generated = tfSchema.mkResourceTypes {
    unsupported = { };
    schema = import ./schema.nix;
    inherit provider runtimePrefix;
    source = providerSource;
    # every sdk/v2 resource carries a synthetic `id`; it is the resource's own
    # identity, computed on apply, and nothing a configuration declares.
    omitEverywhere = [ "id" ];
    resources = {
      keycloak_realm = {
        nameAttr = "realm";
        # Computed identity attribute; nothing to declare.
        omit = [ "internal_id" ];
      };
      keycloak_role = {
        refs = {
          realm_id = realmRef;
          composite_roles = {
            targets = [
              {
                type = "keycloak_role";
                field = "id";
              }
            ];
            managedOnly = false;
            description = "Roles composited into this role. Each entry is a managed role key (resolved to its id) or a literal role UUID.";
          };
          # a role scoped to a client rather than to the realm.
          client_id = anyClientOptionalRef;
        };
        description = "Keycloak roles (realm-level by default).";
      };
      keycloak_default_roles = {
        refs = {
          realm_id = realmRef;
          default_roles = {
            targets = [
              {
                type = "keycloak_role";
                field = "name";
              }
            ];
            managedOnly = false;
            description = "Role names auto-granted to every new user. Each entry is a managed role key (resolved to its name) or a literal role name (built-ins like 'offline_access' work as literals).";
          };
        };
        description = "Realm-level default roles auto-granted to new users.";
      };
      keycloak_group = {
        refs = {
          realm_id = realmRef;
          parent_id = {
            targets = [
              {
                type = "keycloak_group";
                field = "id";
              }
            ];
            managedOnly = true;
            description = "Optional parent group (key of another managed group) for nested groups.";
          };
          organization_id = {
            targets = [
              {
                type = "keycloak_organization";
                field = "id";
              }
            ];
            managedOnly = true;
            description = "Optional organization (key of a managed organization) this group belongs to.";
          };
        };
      };
      keycloak_default_groups = {
        refs = {
          realm_id = realmRef;
          group_ids = {
            targets = [
              {
                type = "keycloak_group";
                field = "id";
              }
            ];
            managedOnly = false;
            description = "Groups new users auto-join. Each entry is a managed group key (resolved to its id) or a literal group UUID.";
          };
        };
        description = "Realm-level default groups auto-joined by new users.";
      };
      keycloak_group_memberships = {
        refs = {
          realm_id = realmRef;
          group_id = {
            targets = [
              {
                type = "keycloak_group";
                field = "id";
              }
            ];
            managedOnly = true;
            # the schema marks `group_id` optional, but a membership needs a
            # group to add its members to.
            required = true;
            description = "Key of the managed group (services.keycloak.runtime.groups.<name>) the members are added to.";
          };
          members = {
            targets = [
              {
                type = "keycloak_user";
                field = "username";
              }
            ];
            managedOnly = false;
            description = "Users to add to the group. Each entry is a managed user key (resolved to its username) or a literal username.";
          };
        };
      };
      keycloak_group_roles = {
        refs = {
          realm_id = realmRef;
          group_id = {
            targets = [
              {
                type = "keycloak_group";
                field = "id";
              }
            ];
            managedOnly = true;
            description = "Key of the managed group (services.keycloak.runtime.groups.<name>) to assign roles to.";
          };
          role_ids = {
            targets = [
              {
                type = "keycloak_role";
                field = "id";
              }
            ];
            managedOnly = false;
            description = "Roles granted to the group. Each entry is a managed role key (resolved to its id) or a literal role UUID.";
          };
        };
        description = "Role assignments for a group.";
      };
      keycloak_user = {
        nameAttr = "username";
        refs.realm_id = realmRef;
        description = "Keycloak users. A username must be lowercase.";
      };
      keycloak_user_roles = {
        refs = {
          realm_id = realmRef;
          user_id = {
            targets = [
              {
                type = "keycloak_user";
                field = "id";
              }
            ];
            managedOnly = true;
            description = "Key of the managed user (services.keycloak.runtime.users.<name>) to assign roles to.";
          };
          role_ids = {
            targets = [
              {
                type = "keycloak_role";
                field = "id";
              }
            ];
            managedOnly = false;
            description = "Roles granted to the user. Each entry is a managed role key (resolved to its id) or a literal role UUID.";
          };
        };
        description = "Role assignments for a user.";
      };
      keycloak_user_groups = {
        refs = {
          realm_id = realmRef;
          user_id = {
            targets = [
              {
                type = "keycloak_user";
                field = "id";
              }
            ];
            managedOnly = true;
            description = "Key of the managed user (services.keycloak.runtime.users.<name>) to add to groups.";
          };
          group_ids = {
            targets = [
              {
                type = "keycloak_group";
                field = "id";
              }
            ];
            managedOnly = false;
            description = "Groups the user joins. Each entry is a managed group key (resolved to its id) or a literal group UUID.";
          };
        };
        description = "Group memberships for a user.";
      };
      keycloak_openid_client_scope = {
        refs.realm_id = realmRef;
      };
      keycloak_saml_client_scope = {
        refs.realm_id = realmRef;
      };
      keycloak_openid_client = {
        nameAttr = "client_id";
        refs.realm_id = realmRef;
        # Write-only twins of `client_secret`: they take an ephemeral value,
        # which a rendered `.tf.json` cannot carry. `client_secretFile` covers
        # the same ground through `LoadCredential=`.
        omit = [
          "client_secret_wo"
          "client_secret_wo_version"
        ];
      };
      keycloak_openid_client_default_scopes = {
        refs = {
          realm_id = realmRef;
          client_id = {
            targets = [
              {
                type = "keycloak_openid_client";
                field = "id";
              }
            ];
            managedOnly = true;
            description = "Key of the managed OpenID client (services.keycloak.runtime.openid_clients.<name>) the scope binding applies to.";
          };
          default_scopes = {
            targets = [
              {
                type = "keycloak_openid_client_scope";
                field = "name";
              }
            ];
            managedOnly = false;
            description = "Scopes attached by default. Each entry is a managed openid_client_scope key (resolved to its name) or a literal scope name (built-ins like 'profile' / 'email' work as literals).";
          };
        };
        description = "Default OAuth2 scopes auto-attached to a client.";
      };
      keycloak_openid_client_optional_scopes = {
        refs = {
          realm_id = realmRef;
          client_id = {
            targets = [
              {
                type = "keycloak_openid_client";
                field = "id";
              }
            ];
            managedOnly = true;
            description = "Key of the managed OpenID client (services.keycloak.runtime.openid_clients.<name>) the scope binding applies to.";
          };
          optional_scopes = {
            targets = [
              {
                type = "keycloak_openid_client_scope";
                field = "name";
              }
            ];
            managedOnly = false;
            description = "Optionally-attached scopes. Each entry is a managed openid_client_scope key (resolved to its name) or a literal scope name.";
          };
        };
        description = "Optional OAuth2 scopes available to a client.";
      };
      keycloak_openid_client_service_account_role = {
        refs = {
          realm_id = realmRef;
          client_id = {
            targets = [
              {
                type = "keycloak_openid_client";
                field = "id";
              }
            ];
            managedOnly = true;
            description = "Key of the managed target client whose role is granted.";
          };
        };
        description = "Grant a per-client role to a service-account user.";
      };
      keycloak_openid_client_service_account_realm_role = {
        refs.realm_id = realmRef;
        description = "Grant a realm-level role to a service-account user.";
      };
      keycloak_saml_client = {
        nameAttr = "client_id";
        refs.realm_id = realmRef;
        # signing_private_key isn't marked Sensitive upstream but is a
        # private key; expose <attr>File so it stays out of the store.
        extraSecrets = [
          "signing_private_key"
        ];
      };
      keycloak_saml_client_default_scopes = {
        refs = {
          realm_id = realmRef;
          client_id = {
            targets = [
              {
                type = "keycloak_saml_client";
                field = "id";
              }
            ];
            managedOnly = true;
            description = "Key of the managed SAML client (services.keycloak.runtime.saml_clients.<name>) the scope binding applies to.";
          };
          default_scopes = {
            targets = [
              {
                type = "keycloak_saml_client_scope";
                field = "name";
              }
            ];
            managedOnly = false;
            description = "SAML scopes attached by default. Each entry is a managed saml_client_scope key (resolved to its name) or a literal scope name.";
          };
        };
        description = "Default SAML scopes auto-attached to a SAML client.";
      };
      # OpenID protocol mappers: one collection per mapper type. all share
      # realm + (client | client_scope) refs.
      keycloak_openid_user_attribute_protocol_mapper = {
        refs = {
          realm_id = realmRef;
          client_id = openidClientOptionalRef;
          client_scope_id = openidClientScopeOptionalRef;
        };
        description = "OpenID protocol mapper that maps a user attribute to a claim.";
        oneOfRefs = clientOrScopeOneOf;
      };
      keycloak_openid_user_property_protocol_mapper = {
        refs = {
          realm_id = realmRef;
          client_id = openidClientOptionalRef;
          client_scope_id = openidClientScopeOptionalRef;
        };
        description = "OpenID protocol mapper that maps a built-in user property (e.g. `email`, `username`) to a claim.";
        oneOfRefs = clientOrScopeOneOf;
      };
      keycloak_openid_group_membership_protocol_mapper = {
        refs = {
          realm_id = realmRef;
          client_id = openidClientOptionalRef;
          client_scope_id = openidClientScopeOptionalRef;
        };
        description = "OpenID protocol mapper that maps group memberships to a claim.";
        oneOfRefs = clientOrScopeOneOf;
      };
      keycloak_openid_full_name_protocol_mapper = {
        refs = {
          realm_id = realmRef;
          client_id = openidClientOptionalRef;
          client_scope_id = openidClientScopeOptionalRef;
        };
        description = "OpenID protocol mapper that emits the user's full name as a single claim.";
        oneOfRefs = clientOrScopeOneOf;
      };
      keycloak_openid_sub_protocol_mapper = {
        refs = {
          realm_id = realmRef;
          client_id = openidClientOptionalRef;
          client_scope_id = openidClientScopeOptionalRef;
        };
        description = "OpenID protocol mapper for the `sub` claim.";
        oneOfRefs = clientOrScopeOneOf;
      };
      keycloak_openid_hardcoded_claim_protocol_mapper = {
        refs = {
          realm_id = realmRef;
          client_id = openidClientOptionalRef;
          client_scope_id = openidClientScopeOptionalRef;
        };
        description = "OpenID protocol mapper that adds a hardcoded claim with a fixed value.";
        oneOfRefs = clientOrScopeOneOf;
      };
      keycloak_openid_audience_protocol_mapper = {
        refs = {
          realm_id = realmRef;
          client_id = openidClientOptionalRef;
          client_scope_id = openidClientScopeOptionalRef;
        };
        description = "OpenID protocol mapper that adds an audience to issued tokens (exactly one of `included_client_audience` / `included_custom_audience`).";
        oneOfRefs = clientOrScopeOneOf;
      };
      keycloak_openid_audience_resolve_protocol_mapper = {
        refs = {
          realm_id = realmRef;
          client_id = openidClientOptionalRef;
          client_scope_id = openidClientScopeOptionalRef;
        };
        description = "OpenID audience-resolve mapper (derives audience from client roles).";
        oneOfRefs = clientOrScopeOneOf;
      };
      keycloak_openid_hardcoded_role_protocol_mapper = {
        refs = {
          realm_id = realmRef;
          client_id = openidClientOptionalRef;
          client_scope_id = openidClientScopeOptionalRef;
        };
        description = "OpenID protocol mapper that adds a hardcoded role to issued tokens.";
        oneOfRefs = clientOrScopeOneOf;
      };
      keycloak_openid_user_realm_role_protocol_mapper = {
        refs = {
          realm_id = realmRef;
          client_id = openidClientOptionalRef;
          client_scope_id = openidClientScopeOptionalRef;
        };
        description = "OpenID protocol mapper that maps the user's realm roles to a claim.";
        oneOfRefs = clientOrScopeOneOf;
      };
      keycloak_openid_user_client_role_protocol_mapper = {
        refs = {
          realm_id = realmRef;
          client_id = openidClientOptionalRef;
          client_scope_id = openidClientScopeOptionalRef;
        };
        description = "OpenID protocol mapper that maps the user's roles on a specific client to a claim.";
        oneOfRefs = clientOrScopeOneOf;
      };
      keycloak_openid_user_session_note_protocol_mapper = {
        refs = {
          realm_id = realmRef;
          client_id = openidClientOptionalRef;
          client_scope_id = openidClientScopeOptionalRef;
        };
        description = "OpenID protocol mapper that maps a user session note to a claim.";
        oneOfRefs = clientOrScopeOneOf;
        requiredAttrs = [
          "session_note"
        ];
      };
      keycloak_saml_user_attribute_protocol_mapper = {
        refs = {
          realm_id = realmRef;
          client_id = samlClientOptionalRef;
          client_scope_id = samlClientScopeOptionalRef;
        };
        description = "SAML mapper that exposes a user attribute as a SAML attribute.";
        oneOfRefs = clientOrScopeOneOf;
      };
      keycloak_saml_user_property_protocol_mapper = {
        refs = {
          realm_id = realmRef;
          client_id = samlClientOptionalRef;
          client_scope_id = samlClientScopeOptionalRef;
        };
        description = "SAML mapper that exposes a built-in user property as a SAML attribute.";
        oneOfRefs = clientOrScopeOneOf;
      };
      keycloak_generic_protocol_mapper = {
        refs = {
          realm_id = realmRef;
          client_id = anyClientOptionalRef;
          client_scope_id = anyClientScopeOptionalRef;
        };
        description = "Generic protocol mapper escape hatch (for mappers without a dedicated typed resource).";
        oneOfRefs = clientOrScopeOneOf;
      };
      keycloak_generic_client_protocol_mapper = {
        refs = {
          realm_id = realmRef;
          client_id = anyClientOptionalRef;
          client_scope_id = anyClientScopeOptionalRef;
        };
        description = "Generic protocol mapper attached to a specific client (without a dedicated typed resource).";
        oneOfRefs = clientOrScopeOneOf;
      };
      keycloak_generic_role_mapper = {
        refs = {
          realm_id = realmRef;
          client_id = anyClientOptionalRef;
          client_scope_id = anyClientScopeOptionalRef;
        };
        description = "Generic role-scope mapper that attaches a role to a client / client scope.";
        oneOfRefs = clientOrScopeOneOf;
      };
      keycloak_generic_client_role_mapper = {
        refs = {
          realm_id = realmRef;
          client_id = anyClientOptionalRef;
          client_scope_id = anyClientScopeOptionalRef;
        };
        description = "Generic role-scope mapper attached to a specific client (deprecated alias kept for completeness).";
        oneOfRefs = clientOrScopeOneOf;
      };
      keycloak_oidc_identity_provider = {
        nameAttr = "alias";
        refs.realm = realmAliasRef;
        description = "Generic OIDC identity providers.";
        # Write-only twins of `client_secret`: they take an ephemeral value,
        # which a rendered `.tf.json` cannot carry. `client_secretFile` covers
        # the same ground through `LoadCredential=`.
        omit = [
          "client_secret_wo"
          "client_secret_wo_version"
        ];
      };
      keycloak_saml_identity_provider = {
        nameAttr = "alias";
        refs.realm = realmAliasRef;
      };
      keycloak_oidc_google_identity_provider = {
        nameAttr = "alias";
        refs.realm = realmAliasRef;
      };
      keycloak_oidc_facebook_identity_provider = {
        nameAttr = "alias";
        refs.realm = realmAliasRef;
      };
      keycloak_oidc_github_identity_provider = {
        nameAttr = "alias";
        refs.realm = realmAliasRef;
      };
      keycloak_oidc_microsoft_identity_provider = {
        nameAttr = "alias";
        refs.realm = realmAliasRef;
      };
      keycloak_kubernetes_identity_provider = {
        nameAttr = "alias";
        refs.realm = realmAliasRef;
      };
      keycloak_oidc_openshift_v4_identity_provider = {
        nameAttr = "alias";
        refs.realm = realmAliasRef;
      };
      keycloak_spiffe_identity_provider = {
        nameAttr = "alias";
        refs.realm = realmAliasRef;
      };
      keycloak_hardcoded_attribute_identity_provider_mapper = {
        refs = {
          realm = realmAliasRef;
          identity_provider_alias = idpAliasRequiredRef;
        };
        description = "Sets a hardcoded user (or session-note) attribute on every federated user.";
      };
      keycloak_hardcoded_group_identity_provider_mapper = {
        refs = {
          realm = realmAliasRef;
          identity_provider_alias = idpAliasRequiredRef;
        };
        description = "Adds every federated user to a hardcoded group.";
      };
      keycloak_hardcoded_role_identity_provider_mapper = {
        refs = {
          realm = realmAliasRef;
          identity_provider_alias = idpAliasRequiredRef;
        };
        description = "Grants a hardcoded role to every federated user.";
      };
      keycloak_attribute_importer_identity_provider_mapper = {
        refs = {
          realm = realmAliasRef;
          identity_provider_alias = idpAliasRequiredRef;
        };
        description = "Imports an attribute / claim from the IdP onto the federated user.";
      };
      keycloak_attribute_to_role_identity_provider_mapper = {
        refs = {
          realm = realmAliasRef;
          identity_provider_alias = idpAliasRequiredRef;
        };
        description = "Grants a role to federated users whose IdP attribute / claim matches a value.";
      };
      keycloak_user_template_importer_identity_provider_mapper = {
        refs = {
          realm = realmAliasRef;
          identity_provider_alias = idpAliasRequiredRef;
        };
        description = "Derives the federated user's username from a Mustache-style template over IdP claims.";
      };
      keycloak_custom_identity_provider_mapper = {
        refs = {
          realm = realmAliasRef;
          identity_provider_alias = idpAliasRequiredRef;
        };
        description = "Escape hatch for an IdP mapper implementation without a dedicated typed resource.";
      };
      keycloak_authentication_flow = {
        nameAttr = "alias";
        refs.realm_id = realmRef;
        description = "Top-level authentication flows.";
      };
      keycloak_authentication_subflow = {
        nameAttr = "alias";
        refs = {
          realm_id = realmRef;
          parent_flow_alias = {
            targets = [
              {
                type = "keycloak_authentication_flow";
                field = "alias";
              }
              {
                type = "keycloak_authentication_subflow";
                field = "alias";
              }
            ];
            managedOnly = false;
            description = "Alias of the parent flow (managed key or literal alias).";
          };
        };
        description = "Authentication subflows nested under a parent flow.";
      };
      keycloak_authentication_execution = {
        refs = {
          realm_id = realmRef;
          parent_flow_alias = {
            targets = [
              {
                type = "keycloak_authentication_flow";
                field = "alias";
              }
              {
                type = "keycloak_authentication_subflow";
                field = "alias";
              }
            ];
            managedOnly = false;
            description = "Alias of the parent flow / subflow (managed key or literal alias).";
          };
        };
        description = "Authentication executions inside a flow / subflow.";
      };
      keycloak_authentication_execution_config = {
        nameAttr = "alias";
        refs = {
          realm_id = realmRef;
          execution_id = {
            targets = [
              {
                type = "keycloak_authentication_execution";
                field = "id";
              }
            ];
            managedOnly = true;
            description = "Key of the managed authentication_execution (services.keycloak.runtime.authentication_executions.<name>) this config attaches to.";
          };
        };
        description = "Per-execution configuration map.";
      };
      keycloak_authentication_bindings = {
        refs.realm_id = realmRef;
        description = "Realm-level authentication flow bindings (browser / registration / direct grant / etc.).";
      };
      keycloak_openid_client_authorization_resource = {
        refs = {
          realm_id = realmRef;
          resource_server_id = {
            targets = [
              {
                type = "keycloak_openid_client";
                field = "resource_server_id";
              }
            ];
            managedOnly = true;
            description = "Key of the managed openid_client (with authorization enabled) hosting this resource.";
          };
        };
        description = "Authorization resources hosted on an openid_client's resource server.";
      };
      keycloak_openid_client_authorization_scope = {
        refs = {
          realm_id = realmRef;
          resource_server_id = {
            targets = [
              {
                type = "keycloak_openid_client";
                field = "resource_server_id";
              }
            ];
            managedOnly = true;
            description = "Key of the managed openid_client (with authorization enabled) hosting this scope.";
          };
        };
        description = "Authorization scopes on an openid_client's resource server.";
      };
      keycloak_openid_client_authorization_permission = {
        refs = {
          realm_id = realmRef;
          resource_server_id = {
            targets = [
              {
                type = "keycloak_openid_client";
                field = "resource_server_id";
              }
            ];
            managedOnly = true;
            description = "Key of the managed openid_client (with authorization enabled) hosting this permission.";
          };
        };
        description = "Authorization permissions tying resources/scopes to policies.";
      };
      keycloak_openid_client_aggregate_policy = {
        refs = {
          realm_id = realmRef;
          resource_server_id = {
            targets = [
              {
                type = "keycloak_openid_client";
                field = "resource_server_id";
              }
            ];
            managedOnly = true;
            description = "Key of the managed openid_client hosting this aggregate policy.";
          };
        };
        description = "Aggregate policy combining other policies under a decision strategy.";
      };
      keycloak_openid_client_client_policy = {
        refs = {
          realm_id = realmRef;
          resource_server_id = {
            targets = [
              {
                type = "keycloak_openid_client";
                field = "resource_server_id";
              }
            ];
            managedOnly = true;
            description = "Key of the managed openid_client hosting this policy.";
          };
        };
        description = "Policy granting access to a specific set of clients.";
        requiredAttrs = [
          "decision_strategy"
        ];
      };
      keycloak_openid_client_authorization_client_scope_policy = {
        refs = {
          realm_id = realmRef;
          resource_server_id = {
            targets = [
              {
                type = "keycloak_openid_client";
                field = "resource_server_id";
              }
            ];
            managedOnly = true;
            description = "Key of the managed openid_client hosting this policy.";
          };
        };
        description = "Policy granting access by client scope membership; each scope block is `{ id; required = false; }`.";
        requiredAttrs = [
          "decision_strategy"
        ];
      };
      keycloak_openid_client_group_policy = {
        refs = {
          realm_id = realmRef;
          resource_server_id = {
            targets = [
              {
                type = "keycloak_openid_client";
                field = "resource_server_id";
              }
            ];
            managedOnly = true;
            description = "Key of the managed openid_client hosting this policy.";
          };
        };
        description = "Policy granting access by group membership; each group block is `{ id; path; extend_children; }`.";
      };
      keycloak_openid_client_regex_policy = {
        refs = {
          realm_id = realmRef;
          resource_server_id = {
            targets = [
              {
                type = "keycloak_openid_client";
                field = "resource_server_id";
              }
            ];
            managedOnly = true;
            description = "Key of the managed openid_client hosting this policy.";
          };
        };
        description = "Policy granting access when a token claim matches a regular expression.";
      };
      keycloak_openid_client_role_policy = {
        refs = {
          realm_id = realmRef;
          resource_server_id = {
            targets = [
              {
                type = "keycloak_openid_client";
                field = "resource_server_id";
              }
            ];
            managedOnly = true;
            description = "Key of the managed openid_client hosting this policy.";
          };
        };
        description = "Policy granting access by realm or client role membership; each role block is `{ id; required = false; }`.";
        requiredAttrs = [
          "decision_strategy"
        ];
      };
      keycloak_openid_client_time_policy = {
        refs = {
          realm_id = realmRef;
          resource_server_id = {
            targets = [
              {
                type = "keycloak_openid_client";
                field = "resource_server_id";
              }
            ];
            managedOnly = true;
            description = "Key of the managed openid_client hosting this policy.";
          };
        };
        description = "Policy granting access within a time window.";
      };
      keycloak_generic_client_authorization_policy = {
        refs = {
          realm_id = realmRef;
          resource_server_id = {
            targets = [
              {
                type = "keycloak_openid_client";
                field = "resource_server_id";
              }
            ];
            managedOnly = true;
            description = "Key of the managed openid_client hosting this policy.";
          };
        };
        description = "Generic (provider-typed) authorization policy on an openid_client's resource server, selected by `type`.";
      };
      keycloak_openid_client_js_policy = {
        refs = {
          realm_id = realmRef;
          resource_server_id = {
            targets = [
              {
                type = "keycloak_openid_client";
                field = "resource_server_id";
              }
            ];
            managedOnly = true;
            description = "Key of the managed openid_client hosting this policy.";
          };
        };
        description = "JavaScript-based authorization policy (evaluates `code`) on an openid_client's resource server.";
      };
      keycloak_ldap_user_federation = {
        refs.realm_id = realmRef;
      };
      keycloak_ldap_user_attribute_mapper = {
        refs = {
          realm_id = realmRef;
          ldap_user_federation_id = ldapFederationIdRef;
        };
        description = "Maps a keycloak user attribute to an LDAP attribute.";
      };
      keycloak_ldap_group_mapper = {
        refs = {
          realm_id = realmRef;
          ldap_user_federation_id = ldapFederationIdRef;
        };
        description = "Maps LDAP groups onto keycloak groups.";
      };
      keycloak_ldap_role_mapper = {
        refs = {
          realm_id = realmRef;
          ldap_user_federation_id = ldapFederationIdRef;
        };
        description = "Maps LDAP roles onto keycloak realm or client roles.";
      };
      keycloak_ldap_hardcoded_role_mapper = {
        refs = {
          realm_id = realmRef;
          ldap_user_federation_id = ldapFederationIdRef;
        };
        description = "Grants a hardcoded role to every LDAP-federated user.";
      };
      keycloak_ldap_hardcoded_attribute_mapper = {
        refs = {
          realm_id = realmRef;
          ldap_user_federation_id = ldapFederationIdRef;
        };
        description = "Sets a hardcoded user attribute on every LDAP-federated user.";
      };
      keycloak_ldap_hardcoded_group_mapper = {
        refs = {
          realm_id = realmRef;
          ldap_user_federation_id = ldapFederationIdRef;
        };
        description = "Adds every LDAP-federated user to a hardcoded group.";
      };
      keycloak_ldap_msad_user_account_control_mapper = {
        refs = {
          realm_id = realmRef;
          ldap_user_federation_id = ldapFederationIdRef;
        };
        description = "MSAD userAccountControl integration mapper (enables / disables and locks out users).";
      };
      keycloak_ldap_msad_lds_user_account_control_mapper = {
        refs = {
          realm_id = realmRef;
          ldap_user_federation_id = ldapFederationIdRef;
        };
        description = "MSAD LDS userAccountControl integration mapper.";
      };
      keycloak_ldap_full_name_mapper = {
        refs = {
          realm_id = realmRef;
          ldap_user_federation_id = ldapFederationIdRef;
        };
        description = "Splits/joins a single LDAP full-name attribute into keycloak's first / last name fields.";
      };
      keycloak_ldap_custom_mapper = {
        refs = {
          realm_id = realmRef;
          ldap_user_federation_id = ldapFederationIdRef;
        };
        description = "Escape hatch for an LDAP mapper implementation without a dedicated typed resource.";
      };
      keycloak_custom_user_federation = {
        refs.realm_id = realmRef;
        description = "Custom user federation backed by a JPA / SPI provider.";
      };
      keycloak_realm_keystore_aes_generated = {
        refs.realm_id = realmRef;
        description = "AES keystore generated by Keycloak.";
      };
      keycloak_realm_keystore_ecdsa_generated = {
        refs.realm_id = realmRef;
        description = "ECDSA keystore generated by Keycloak.";
      };
      keycloak_realm_keystore_hmac_generated = {
        refs.realm_id = realmRef;
        description = "HMAC keystore generated by Keycloak.";
      };
      keycloak_realm_keystore_java_keystore = {
        refs.realm_id = realmRef;
        description = "Keystore backed by a Java KeyStore (JKS) file.";
        extraSecrets = [
          "key_password"
          "keystore_password"
        ];
      };
      keycloak_realm_keystore_rsa = {
        refs.realm_id = realmRef;
        # private_key and certificate are PEM material; expose <attr>File
        # for both even though only private_key is technically secret.
        description = "Keystore backed by an externally-provided RSA private key / certificate pair.";
        extraSecrets = [
          "certificate"
          "private_key"
        ];
      };
      keycloak_realm_keystore_rsa_generated = {
        refs.realm_id = realmRef;
        description = "RSA keystore generated by Keycloak.";
      };
      keycloak_hardcoded_attribute_mapper = {
        refs = {
          realm_id = realmRef;
          ldap_user_federation_id = ldapFederationIdRef;
        };
        description = "Sets a hardcoded user attribute on every federated user. Distinct from ldap_hardcoded_attribute_mapper and hardcoded_attribute_identity_provider_mapper.";
      };
      keycloak_openid_client_user_policy = {
        refs = {
          realm_id = realmRef;
          resource_server_id = {
            targets = [
              {
                type = "keycloak_openid_client";
                field = "resource_server_id";
              }
            ];
            managedOnly = true;
            description = "Key of the managed openid_client hosting this policy.";
          };
        };
        description = "Policy granting access to a specific set of users.";
      };
      keycloak_required_action = {
        nameAttr = "alias";
        refs.realm_id = realmRef;
      };
      keycloak_realm_events = {
        refs.realm_id = realmRef;
        description = "Per-realm event logging configuration.";
      };
      keycloak_realm_localization = {
        nameAttr = "locale";
        refs.realm_id = realmRef;
      };
      keycloak_realm_default_client_scopes = {
        refs = {
          realm_id = realmRef;
          default_scopes = {
            targets = [
              {
                type = "keycloak_openid_client_scope";
                field = "name";
              }
              {
                type = "keycloak_saml_client_scope";
                field = "name";
              }
            ];
            managedOnly = false;
            description = "Scope names auto-attached as default to every new client. Each entry is a managed openid/saml client_scope key (resolved to its name) or a literal scope name.";
          };
        };
        description = "Realm-wide default client-scope binding (set of scope names). Distinct from realms.<r>.default_default_client_scopes, which is a free-form realm attribute.";
      };
      keycloak_realm_optional_client_scopes = {
        refs = {
          realm_id = realmRef;
          optional_scopes = {
            targets = [
              {
                type = "keycloak_openid_client_scope";
                field = "name";
              }
              {
                type = "keycloak_saml_client_scope";
                field = "name";
              }
            ];
            managedOnly = false;
            description = "Scope names available as optional to every new client. Each entry is a managed openid/saml client_scope key (resolved to its name) or a literal scope name.";
          };
        };
        description = "Realm-wide optional client-scope binding (set of scope names).";
      };
      keycloak_organization = {
        refs.realm = realmAliasRef;
        description = "Keycloak organizations. They require the organizations feature.";
      };
      keycloak_identity_provider_token_exchange_scope_permission = {
        refs.realm_id = realmRef;
        description = "Per-IdP token-exchange permission policy granting a set of clients access to the IdP's token-exchange scope.";
      };
      keycloak_realm_user_profile = {
        refs.realm_id = realmRef;
        # nested block inside a list element; wrapBlocks recurses through
        # the list, so the dotted path matches.
        description = "Per-realm user-profile schema (attribute declarations + groups). Declare one resource per realm.";
      };
      keycloak_realm_client_policy_profile = {
        refs.realm_id = realmRef;
        description = "Realm client-policy profile, listing executors that enforce a client policy.";
      };
      keycloak_realm_client_policy_profile_policy = {
        refs = {
          realm_id = realmRef;
          profiles = {
            targets = [
              {
                type = "keycloak_realm_client_policy_profile";
                field = "name";
              }
            ];
            managedOnly = false;
            description = "Names of client-policy profiles this policy applies. Each entry is a managed realm_client_policy_profile key (resolved to its name) or a literal profile name.";
          };
        };
        description = "Realm client-policy policy binding a set of profiles to a set of conditions.";
      };
      keycloak_group_permissions = {
        refs = {
          realm_id = realmRef;
          group_id = {
            targets = [
              {
                type = "keycloak_group";
                field = "id";
              }
            ];
            managedOnly = true;
            description = "Key of the managed group these fine-grained permissions apply to.";
          };
        };
        # every scope_* attr is a MaxItems:1 nested block.
        description = "Fine-grained authorization permissions for a group; each scope_* attr binds a scope to a `{ decision_strategy; policies; description; }` block.";
      };
      keycloak_openid_client_permissions = {
        refs = {
          realm_id = realmRef;
          client_id = {
            targets = [
              {
                type = "keycloak_openid_client";
                field = "id";
              }
            ];
            managedOnly = true;
            description = "Key of the managed openid_client these fine-grained permissions apply to.";
          };
        };
        description = "Fine-grained authorization permissions on an openid_client; each scope_* attr binds a scope to a `{ decision_strategy; policies; description; }` block.";
      };
      keycloak_users_permissions = {
        refs.realm_id = realmRef;
        description = "Fine-grained authorization permissions on the realm's users collection; each scope_* attr binds a scope to a `{ decision_strategy; policies; description; }` block.";
      };
      keycloak_group_admin_permissions = {
        refs = {
          realm_id = realmRef;
          group_ids = {
            targets = [
              {
                type = "keycloak_group";
                field = "id";
              }
            ];
            managedOnly = false;
            description = "Groups this admin permission applies to. Each entry is a managed group key (resolved to its id) or a literal group UUID; leave empty to target all groups in the realm.";
          };
        };
        description = "Fine-grained admin permission over groups; `scopes` names the admin actions granted and `policies` the authorization policies that gate them.";
      };
      keycloak_openid_client_admin_permissions = {
        refs = {
          realm_id = realmRef;
          client_ids = {
            targets = [
              {
                type = "keycloak_openid_client";
                field = "id";
              }
            ];
            managedOnly = false;
            description = "Clients this admin permission applies to. Each entry is a managed openid_client key (resolved to its id) or a literal client UUID; leave empty to target all clients in the realm.";
          };
        };
        description = "Fine-grained admin permission over openid_clients; `scopes` names the admin actions granted and `policies` the authorization policies that gate them.";
      };
      keycloak_role_admin_permissions = {
        refs = {
          realm_id = realmRef;
          role_ids = {
            targets = [
              {
                type = "keycloak_role";
                field = "id";
              }
            ];
            managedOnly = false;
            description = "Roles this admin permission applies to. Each entry is a managed role key (resolved to its id) or a literal role UUID; leave empty to target all roles in the realm.";
          };
        };
        description = "Fine-grained admin permission over roles; `scopes` names the admin actions granted and `policies` the authorization policies that gate them.";
      };
      keycloak_users_admin_permissions = {
        refs.realm_id = realmRef;
        description = "Fine-grained admin permission over the realm's users; `scopes` names the admin actions granted and `policies` the authorization policies that gate them.";
      };
      keycloak_realm_client_registration_policy = {
        refs.realm_id = realmRef;
        description = "Per-realm client-registration policy (`provider_id` selects the policy type, `sub_type` its anonymous/authenticated scope, `config` its settings).";
      };
      keycloak_workflow = {
        refs.realm = realmAliasRef;
        description = "Realm workflows: an event trigger (`on`) plus an ordered list of `step` actions.";
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
    legacyLabelPrefixes = import ./legacy-label-prefixes.nix;
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
