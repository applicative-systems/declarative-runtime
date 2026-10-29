# keycloak-provider specifics: executor, resource surface, provider block.
#
# The resource surface is *derived* from the vendored provider schema
# (./provider-schema.json, parsed by ./schema.nix) via
# ../../modules/lib/tf-schema.nix. What stays hand-written is only what a schema
# cannot state: the reference graph between collections, the odd description
# that adds a fact, and the odd documented correction. A provider bump that
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
        type = "realm";
        field = "id";
      }
    ];
    managedOnly = true;
  };

  # authorization resources, scopes, permissions and policies live on an
  # openid_client's resource server.
  resourceServerRef = {
    targets = [
      {
        type = "openid_client";
        field = "resource_server_id";
      }
    ];
    managedOnly = true;
    description = "The OpenID client that hosts this, as an authorization resource server. The client must enable authorization.";
  };

  # optional refs to a managed openid_client / openid_client_scope, used by
  # all openid protocol mappers (mutually exclusive at the provider).
  openidClientOptionalRef = {
    targets = [
      {
        type = "openid_client";
        field = "id";
      }
    ];
    managedOnly = true;
  };
  openidClientScopeOptionalRef = {
    targets = [
      {
        type = "openid_client_scope";
        field = "id";
      }
    ];
    managedOnly = true;
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
        type = "saml_client";
        field = "id";
      }
    ];
    managedOnly = true;
  };
  samlClientScopeOptionalRef = {
    targets = [
      {
        type = "saml_client_scope";
        field = "id";
      }
    ];
    managedOnly = true;
  };

  # identity providers reference the realm by its alias (name) -- the
  # provider's `realm` attribute, not `realm_id`.
  realmAliasRef = {
    targets = [
      {
        type = "realm";
        field = "realm";
      }
    ];
    managedOnly = true;
  };

  # every ldap_*_mapper resolves its parent federation by id.
  ldapFederationIdRef = {
    targets = [
      {
        type = "ldap_user_federation";
        field = "id";
      }
    ];
    managedOnly = true;
  };

  # IdP mappers reference an IdP by alias; the alias can belong to
  # any of the nine IdP collections.
  idpAliasRequiredRef = {
    targets = [
      {
        type = "oidc_identity_provider";
        field = "alias";
      }
      {
        type = "saml_identity_provider";
        field = "alias";
      }
      {
        type = "oidc_google_identity_provider";
        field = "alias";
      }
      {
        type = "oidc_facebook_identity_provider";
        field = "alias";
      }
      {
        type = "oidc_github_identity_provider";
        field = "alias";
      }
      {
        type = "kubernetes_identity_provider";
        field = "alias";
      }
      {
        type = "oidc_openshift_v4_identity_provider";
        field = "alias";
      }
      {
        type = "spiffe_identity_provider";
        field = "alias";
      }
      {
        type = "oidc_microsoft_identity_provider";
        field = "alias";
      }
    ];
    managedOnly = false;
  };

  # generic mappers attach to either an openid or a saml client/scope.
  # multi-target: a managed key from either collection resolves; an
  # unknown string falls through as a literal.
  anyClientOptionalRef = {
    targets = [
      {
        type = "openid_client";
        field = "id";
      }
      {
        type = "saml_client";
        field = "id";
      }
    ];
    managedOnly = false;
  };
  anyClientScopeOptionalRef = {
    targets = [
      {
        type = "openid_client_scope";
        field = "id";
      }
      {
        type = "saml_client_scope";
        field = "id";
      }
    ];
    managedOnly = false;
  };
  # The keycloak/keycloak resource surface, keyed by resource name: the resource
  # type without `keycloak_`, as the provider docs give it. Each resource
  # becomes the collection `services.keycloak.runtime.<plural>`
  # (`realm` -> `realms`). Per resource, only the facts the schema does not
  # carry (see modules/lib/tf-schema.nix for the full overlay vocabulary):
  #   nameAttr     attribute the collection key fills in, where it is not `name`
  #   refs         parent links resolved to references against managed siblings
  #   description  replaces the generated description, only to add a fact
  generated = tfSchema.mkResourceTypes {
    unsupported = { };
    schema = import ./schema.nix;
    inherit provider runtimePrefix;
    source = providerSource;
    # every sdk/v2 resource carries a synthetic `id`; it is the resource's own
    # identity, computed on apply, and nothing a configuration declares.
    omitEverywhere = [ "id" ];
    resources = {
      realm = {
        nameAttr = "realm";
        # Computed identity attribute; nothing to declare.
        omit = [ "internal_id" ];
      };
      role = {
        refs = {
          realm_id = realmRef;
          composite_roles = {
            targets = [
              {
                type = "role";
                field = "id";
              }
            ];
            managedOnly = false;
          };
          # a role scoped to a client rather than to the realm.
          client_id = anyClientOptionalRef;
        };
        description = "Keycloak roles (realm-level by default).";
      };
      default_roles = {
        refs = {
          realm_id = realmRef;
          default_roles = {
            targets = [
              {
                type = "role";
                field = "name";
              }
            ];
            managedOnly = false;
          };
        };
        description = "Realm-level default roles auto-granted to new users.";
      };
      group = {
        refs = {
          realm_id = realmRef;
          parent_id = {
            targets = [
              {
                type = "group";
                field = "id";
              }
            ];
            managedOnly = true;
          };
          organization_id = {
            targets = [
              {
                type = "organization";
                field = "id";
              }
            ];
            managedOnly = true;
          };
        };
      };
      default_groups = {
        refs = {
          realm_id = realmRef;
          group_ids = {
            targets = [
              {
                type = "group";
                field = "id";
              }
            ];
            managedOnly = false;
          };
        };
        description = "Realm-level default groups auto-joined by new users.";
      };
      group_memberships = {
        refs = {
          realm_id = realmRef;
          group_id = {
            targets = [
              {
                type = "group";
                field = "id";
              }
            ];
            managedOnly = true;
            # the schema marks `group_id` optional, but a membership needs a
            # group to add its members to.
            required = true;
          };
          members = {
            targets = [
              {
                type = "user";
                field = "username";
              }
            ];
            managedOnly = false;
          };
        };
      };
      group_roles = {
        refs = {
          realm_id = realmRef;
          group_id = {
            targets = [
              {
                type = "group";
                field = "id";
              }
            ];
            managedOnly = true;
          };
          role_ids = {
            targets = [
              {
                type = "role";
                field = "id";
              }
            ];
            managedOnly = false;
          };
        };
      };
      user = {
        nameAttr = "username";
        refs.realm_id = realmRef;
        description = "Keycloak users. A username must be lowercase.";
      };
      user_roles = {
        refs = {
          realm_id = realmRef;
          user_id = {
            targets = [
              {
                type = "user";
                field = "id";
              }
            ];
            managedOnly = true;
          };
          role_ids = {
            targets = [
              {
                type = "role";
                field = "id";
              }
            ];
            managedOnly = false;
          };
        };
      };
      user_groups = {
        refs = {
          realm_id = realmRef;
          user_id = {
            targets = [
              {
                type = "user";
                field = "id";
              }
            ];
            managedOnly = true;
          };
          group_ids = {
            targets = [
              {
                type = "group";
                field = "id";
              }
            ];
            managedOnly = false;
          };
        };
      };
      openid_client_scope = {
        refs.realm_id = realmRef;
      };
      saml_client_scope = {
        refs.realm_id = realmRef;
      };
      openid_client = {
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
      openid_client_default_scopes = {
        refs = {
          realm_id = realmRef;
          client_id = {
            targets = [
              {
                type = "openid_client";
                field = "id";
              }
            ];
            managedOnly = true;
          };
          default_scopes = {
            targets = [
              {
                type = "openid_client_scope";
                field = "name";
              }
            ];
            managedOnly = false;
          };
        };
      };
      openid_client_optional_scopes = {
        refs = {
          realm_id = realmRef;
          client_id = {
            targets = [
              {
                type = "openid_client";
                field = "id";
              }
            ];
            managedOnly = true;
          };
          optional_scopes = {
            targets = [
              {
                type = "openid_client_scope";
                field = "name";
              }
            ];
            managedOnly = false;
          };
        };
      };
      openid_client_service_account_role = {
        refs = {
          realm_id = realmRef;
          client_id = {
            targets = [
              {
                type = "openid_client";
                field = "id";
              }
            ];
            managedOnly = true;
          };
        };
      };
      openid_client_service_account_realm_role = {
        refs.realm_id = realmRef;
      };
      saml_client = {
        nameAttr = "client_id";
        refs.realm_id = realmRef;
        # signing_private_key isn't marked Sensitive upstream but is a
        # private key; expose <attr>File so it stays out of the store.
        extraSecrets = [
          "signing_private_key"
        ];
      };
      saml_client_default_scopes = {
        refs = {
          realm_id = realmRef;
          client_id = {
            targets = [
              {
                type = "saml_client";
                field = "id";
              }
            ];
            managedOnly = true;
          };
          default_scopes = {
            targets = [
              {
                type = "saml_client_scope";
                field = "name";
              }
            ];
            managedOnly = false;
          };
        };
      };
      # OpenID protocol mappers: one collection per mapper type. all share
      # realm + (client | client_scope) refs.
      openid_user_attribute_protocol_mapper = {
        refs = {
          realm_id = realmRef;
          client_id = openidClientOptionalRef;
          client_scope_id = openidClientScopeOptionalRef;
        };
        oneOfRefs = clientOrScopeOneOf;
      };
      openid_user_property_protocol_mapper = {
        refs = {
          realm_id = realmRef;
          client_id = openidClientOptionalRef;
          client_scope_id = openidClientScopeOptionalRef;
        };
        oneOfRefs = clientOrScopeOneOf;
      };
      openid_group_membership_protocol_mapper = {
        refs = {
          realm_id = realmRef;
          client_id = openidClientOptionalRef;
          client_scope_id = openidClientScopeOptionalRef;
        };
        oneOfRefs = clientOrScopeOneOf;
      };
      openid_full_name_protocol_mapper = {
        refs = {
          realm_id = realmRef;
          client_id = openidClientOptionalRef;
          client_scope_id = openidClientScopeOptionalRef;
        };
        oneOfRefs = clientOrScopeOneOf;
      };
      openid_sub_protocol_mapper = {
        refs = {
          realm_id = realmRef;
          client_id = openidClientOptionalRef;
          client_scope_id = openidClientScopeOptionalRef;
        };
        oneOfRefs = clientOrScopeOneOf;
      };
      openid_hardcoded_claim_protocol_mapper = {
        refs = {
          realm_id = realmRef;
          client_id = openidClientOptionalRef;
          client_scope_id = openidClientScopeOptionalRef;
        };
        oneOfRefs = clientOrScopeOneOf;
      };
      openid_audience_protocol_mapper = {
        refs = {
          realm_id = realmRef;
          client_id = openidClientOptionalRef;
          client_scope_id = openidClientScopeOptionalRef;
        };
        description = "OpenID protocol mapper that adds an audience to issued tokens (exactly one of `included_client_audience` / `included_custom_audience`).";
        oneOfRefs = clientOrScopeOneOf;
      };
      openid_audience_resolve_protocol_mapper = {
        refs = {
          realm_id = realmRef;
          client_id = openidClientOptionalRef;
          client_scope_id = openidClientScopeOptionalRef;
        };
        description = "OpenID audience-resolve mapper (derives audience from client roles).";
        oneOfRefs = clientOrScopeOneOf;
      };
      openid_hardcoded_role_protocol_mapper = {
        refs = {
          realm_id = realmRef;
          client_id = openidClientOptionalRef;
          client_scope_id = openidClientScopeOptionalRef;
        };
        oneOfRefs = clientOrScopeOneOf;
      };
      openid_user_realm_role_protocol_mapper = {
        refs = {
          realm_id = realmRef;
          client_id = openidClientOptionalRef;
          client_scope_id = openidClientScopeOptionalRef;
        };
        oneOfRefs = clientOrScopeOneOf;
      };
      openid_user_client_role_protocol_mapper = {
        refs = {
          realm_id = realmRef;
          client_id = openidClientOptionalRef;
          client_scope_id = openidClientScopeOptionalRef;
        };
        oneOfRefs = clientOrScopeOneOf;
      };
      openid_user_session_note_protocol_mapper = {
        refs = {
          realm_id = realmRef;
          client_id = openidClientOptionalRef;
          client_scope_id = openidClientScopeOptionalRef;
        };
        oneOfRefs = clientOrScopeOneOf;
        requiredAttrs = [
          "session_note"
        ];
      };
      saml_user_attribute_protocol_mapper = {
        refs = {
          realm_id = realmRef;
          client_id = samlClientOptionalRef;
          client_scope_id = samlClientScopeOptionalRef;
        };
        oneOfRefs = clientOrScopeOneOf;
      };
      saml_user_property_protocol_mapper = {
        refs = {
          realm_id = realmRef;
          client_id = samlClientOptionalRef;
          client_scope_id = samlClientScopeOptionalRef;
        };
        oneOfRefs = clientOrScopeOneOf;
      };
      generic_protocol_mapper = {
        refs = {
          realm_id = realmRef;
          client_id = anyClientOptionalRef;
          client_scope_id = anyClientScopeOptionalRef;
        };
        description = "Generic protocol mapper escape hatch (for mappers without a dedicated typed resource).";
        oneOfRefs = clientOrScopeOneOf;
      };
      generic_client_protocol_mapper = {
        refs = {
          realm_id = realmRef;
          client_id = anyClientOptionalRef;
          client_scope_id = anyClientScopeOptionalRef;
        };
        description = "Generic protocol mapper attached to a specific client (without a dedicated typed resource).";
        oneOfRefs = clientOrScopeOneOf;
      };
      generic_role_mapper = {
        refs = {
          realm_id = realmRef;
          client_id = anyClientOptionalRef;
          client_scope_id = anyClientScopeOptionalRef;
        };
        oneOfRefs = clientOrScopeOneOf;
      };
      generic_client_role_mapper = {
        refs = {
          realm_id = realmRef;
          client_id = anyClientOptionalRef;
          client_scope_id = anyClientScopeOptionalRef;
        };
        description = "Generic role-scope mapper attached to a specific client (deprecated alias kept for completeness).";
        oneOfRefs = clientOrScopeOneOf;
      };
      oidc_identity_provider = {
        nameAttr = "alias";
        refs.realm = realmAliasRef;
        # Write-only twins of `client_secret`: they take an ephemeral value,
        # which a rendered `.tf.json` cannot carry. `client_secretFile` covers
        # the same ground through `LoadCredential=`.
        omit = [
          "client_secret_wo"
          "client_secret_wo_version"
        ];
      };
      saml_identity_provider = {
        nameAttr = "alias";
        refs.realm = realmAliasRef;
      };
      oidc_google_identity_provider = {
        nameAttr = "alias";
        refs.realm = realmAliasRef;
      };
      oidc_facebook_identity_provider = {
        nameAttr = "alias";
        refs.realm = realmAliasRef;
      };
      oidc_github_identity_provider = {
        nameAttr = "alias";
        refs.realm = realmAliasRef;
      };
      oidc_microsoft_identity_provider = {
        nameAttr = "alias";
        refs.realm = realmAliasRef;
      };
      kubernetes_identity_provider = {
        nameAttr = "alias";
        refs.realm = realmAliasRef;
      };
      oidc_openshift_v4_identity_provider = {
        nameAttr = "alias";
        refs.realm = realmAliasRef;
      };
      spiffe_identity_provider = {
        nameAttr = "alias";
        refs.realm = realmAliasRef;
      };
      hardcoded_attribute_identity_provider_mapper = {
        refs = {
          realm = realmAliasRef;
          identity_provider_alias = idpAliasRequiredRef;
        };
        description = "Sets a hardcoded user (or session-note) attribute on every federated user.";
      };
      hardcoded_group_identity_provider_mapper = {
        refs = {
          realm = realmAliasRef;
          identity_provider_alias = idpAliasRequiredRef;
        };
      };
      hardcoded_role_identity_provider_mapper = {
        refs = {
          realm = realmAliasRef;
          identity_provider_alias = idpAliasRequiredRef;
        };
      };
      attribute_importer_identity_provider_mapper = {
        refs = {
          realm = realmAliasRef;
          identity_provider_alias = idpAliasRequiredRef;
        };
      };
      attribute_to_role_identity_provider_mapper = {
        refs = {
          realm = realmAliasRef;
          identity_provider_alias = idpAliasRequiredRef;
        };
        description = "Grants a role to federated users whose IdP attribute / claim matches a value.";
      };
      user_template_importer_identity_provider_mapper = {
        refs = {
          realm = realmAliasRef;
          identity_provider_alias = idpAliasRequiredRef;
        };
        description = "Derives the federated user's username from a Mustache-style template over IdP claims.";
      };
      custom_identity_provider_mapper = {
        refs = {
          realm = realmAliasRef;
          identity_provider_alias = idpAliasRequiredRef;
        };
        description = "Escape hatch for an IdP mapper implementation without a dedicated typed resource.";
      };
      authentication_flow = {
        nameAttr = "alias";
        refs.realm_id = realmRef;
      };
      authentication_subflow = {
        nameAttr = "alias";
        refs = {
          realm_id = realmRef;
          parent_flow_alias = {
            targets = [
              {
                type = "authentication_flow";
                field = "alias";
              }
              {
                type = "authentication_subflow";
                field = "alias";
              }
            ];
            managedOnly = false;
          };
        };
      };
      authentication_execution = {
        refs = {
          realm_id = realmRef;
          parent_flow_alias = {
            targets = [
              {
                type = "authentication_flow";
                field = "alias";
              }
              {
                type = "authentication_subflow";
                field = "alias";
              }
            ];
            managedOnly = false;
          };
        };
      };
      authentication_execution_config = {
        nameAttr = "alias";
        refs = {
          realm_id = realmRef;
          execution_id = {
            targets = [
              {
                type = "authentication_execution";
                field = "id";
              }
            ];
            managedOnly = true;
          };
        };
      };
      authentication_bindings = {
        refs.realm_id = realmRef;
        description = "Realm-level authentication flow bindings (browser / registration / direct grant / etc.).";
      };
      openid_client_authorization_resource = {
        refs = {
          realm_id = realmRef;
          resource_server_id = resourceServerRef;
        };
      };
      openid_client_authorization_scope = {
        refs = {
          realm_id = realmRef;
          resource_server_id = resourceServerRef;
        };
      };
      openid_client_authorization_permission = {
        refs = {
          realm_id = realmRef;
          resource_server_id = resourceServerRef;
        };
        description = "Authorization permissions tying resources/scopes to policies.";
      };
      openid_client_aggregate_policy = {
        refs = {
          realm_id = realmRef;
          resource_server_id = resourceServerRef;
        };
      };
      openid_client_client_policy = {
        refs = {
          realm_id = realmRef;
          resource_server_id = resourceServerRef;
        };
        requiredAttrs = [
          "decision_strategy"
        ];
      };
      openid_client_authorization_client_scope_policy = {
        refs = {
          realm_id = realmRef;
          resource_server_id = resourceServerRef;
        };
        requiredAttrs = [
          "decision_strategy"
        ];
      };
      openid_client_group_policy = {
        refs = {
          realm_id = realmRef;
          resource_server_id = resourceServerRef;
        };
      };
      openid_client_regex_policy = {
        refs = {
          realm_id = realmRef;
          resource_server_id = resourceServerRef;
        };
        description = "Policy granting access when a token claim matches a regular expression.";
      };
      openid_client_role_policy = {
        refs = {
          realm_id = realmRef;
          resource_server_id = resourceServerRef;
        };
        requiredAttrs = [
          "decision_strategy"
        ];
      };
      openid_client_time_policy = {
        refs = {
          realm_id = realmRef;
          resource_server_id = resourceServerRef;
        };
      };
      generic_client_authorization_policy = {
        refs = {
          realm_id = realmRef;
          resource_server_id = resourceServerRef;
        };
        description = "Generic (provider-typed) authorization policy on an openid_client's resource server, selected by `type`.";
      };
      openid_client_js_policy = {
        refs = {
          realm_id = realmRef;
          resource_server_id = resourceServerRef;
        };
      };
      ldap_user_federation = {
        refs.realm_id = realmRef;
      };
      ldap_user_attribute_mapper = {
        refs = {
          realm_id = realmRef;
          ldap_user_federation_id = ldapFederationIdRef;
        };
      };
      ldap_group_mapper = {
        refs = {
          realm_id = realmRef;
          ldap_user_federation_id = ldapFederationIdRef;
        };
      };
      ldap_role_mapper = {
        refs = {
          realm_id = realmRef;
          ldap_user_federation_id = ldapFederationIdRef;
        };
      };
      ldap_hardcoded_role_mapper = {
        refs = {
          realm_id = realmRef;
          ldap_user_federation_id = ldapFederationIdRef;
        };
      };
      ldap_hardcoded_attribute_mapper = {
        refs = {
          realm_id = realmRef;
          ldap_user_federation_id = ldapFederationIdRef;
        };
      };
      ldap_hardcoded_group_mapper = {
        refs = {
          realm_id = realmRef;
          ldap_user_federation_id = ldapFederationIdRef;
        };
      };
      ldap_msad_user_account_control_mapper = {
        refs = {
          realm_id = realmRef;
          ldap_user_federation_id = ldapFederationIdRef;
        };
        description = "MSAD userAccountControl integration mapper (enables / disables and locks out users).";
      };
      ldap_msad_lds_user_account_control_mapper = {
        refs = {
          realm_id = realmRef;
          ldap_user_federation_id = ldapFederationIdRef;
        };
      };
      ldap_full_name_mapper = {
        refs = {
          realm_id = realmRef;
          ldap_user_federation_id = ldapFederationIdRef;
        };
        description = "Splits/joins a single LDAP full-name attribute into keycloak's first / last name fields.";
      };
      ldap_custom_mapper = {
        refs = {
          realm_id = realmRef;
          ldap_user_federation_id = ldapFederationIdRef;
        };
        description = "Escape hatch for an LDAP mapper implementation without a dedicated typed resource.";
      };
      custom_user_federation = {
        refs.realm_id = realmRef;
        description = "Custom user federation backed by a JPA / SPI provider.";
      };
      realm_keystore_aes_generated = {
        refs.realm_id = realmRef;
      };
      realm_keystore_ecdsa_generated = {
        refs.realm_id = realmRef;
      };
      realm_keystore_hmac_generated = {
        refs.realm_id = realmRef;
      };
      realm_keystore_java_keystore = {
        refs.realm_id = realmRef;
        extraSecrets = [
          "key_password"
          "keystore_password"
        ];
      };
      realm_keystore_rsa = {
        refs.realm_id = realmRef;
        # private_key and certificate are PEM material; expose <attr>File
        # for both even though only private_key is technically secret.
        description = "Keystore backed by an externally-provided RSA private key / certificate pair.";
        extraSecrets = [
          "certificate"
          "private_key"
        ];
      };
      realm_keystore_rsa_generated = {
        refs.realm_id = realmRef;
      };
      hardcoded_attribute_mapper = {
        refs = {
          realm_id = realmRef;
          ldap_user_federation_id = ldapFederationIdRef;
        };
        description = "Sets a hardcoded user attribute on every federated user. Distinct from ldap_hardcoded_attribute_mapper and hardcoded_attribute_identity_provider_mapper.";
      };
      openid_client_user_policy = {
        refs = {
          realm_id = realmRef;
          resource_server_id = resourceServerRef;
        };
      };
      required_action = {
        nameAttr = "alias";
        refs.realm_id = realmRef;
      };
      realm_events = {
        refs.realm_id = realmRef;
      };
      realm_localization = {
        nameAttr = "locale";
        refs.realm_id = realmRef;
      };
      realm_default_client_scopes = {
        refs = {
          realm_id = realmRef;
          default_scopes = {
            targets = [
              {
                type = "openid_client_scope";
                field = "name";
              }
              {
                type = "saml_client_scope";
                field = "name";
              }
            ];
            managedOnly = false;
          };
        };
        description = "Realm-wide default client-scope binding (set of scope names). Distinct from realms.<r>.default_default_client_scopes, which is a free-form realm attribute.";
      };
      realm_optional_client_scopes = {
        refs = {
          realm_id = realmRef;
          optional_scopes = {
            targets = [
              {
                type = "openid_client_scope";
                field = "name";
              }
              {
                type = "saml_client_scope";
                field = "name";
              }
            ];
            managedOnly = false;
          };
        };
      };
      organization = {
        refs.realm = realmAliasRef;
        description = "Keycloak organizations. They require the organizations feature.";
      };
      identity_provider_token_exchange_scope_permission = {
        refs.realm_id = realmRef;
        description = "Per-IdP token-exchange permission policy granting a set of clients access to the IdP's token-exchange scope.";
      };
      realm_user_profile = {
        refs.realm_id = realmRef;
        # nested block inside a list element; wrapBlocks recurses through
        # the list, so the dotted path matches.
        description = "Per-realm user-profile schema (attribute declarations + groups). Declare one resource per realm.";
      };
      realm_client_policy_profile = {
        refs.realm_id = realmRef;
        description = "Realm client-policy profile, listing executors that enforce a client policy.";
      };
      realm_client_policy_profile_policy = {
        refs = {
          realm_id = realmRef;
          profiles = {
            targets = [
              {
                type = "realm_client_policy_profile";
                field = "name";
              }
            ];
            managedOnly = false;
          };
        };
        description = "Realm client-policy policy binding a set of profiles to a set of conditions.";
      };
      group_permissions = {
        refs = {
          realm_id = realmRef;
          group_id = {
            targets = [
              {
                type = "group";
                field = "id";
              }
            ];
            managedOnly = true;
          };
        };
        # every scope_* attr is a MaxItems:1 nested block.
      };
      openid_client_permissions = {
        refs = {
          realm_id = realmRef;
          client_id = {
            targets = [
              {
                type = "openid_client";
                field = "id";
              }
            ];
            managedOnly = true;
          };
        };
      };
      users_permissions = {
        refs.realm_id = realmRef;
      };
      group_admin_permissions = {
        refs = {
          realm_id = realmRef;
          group_ids = {
            targets = [
              {
                type = "group";
                field = "id";
              }
            ];
            managedOnly = false;
          };
        };
      };
      openid_client_admin_permissions = {
        refs = {
          realm_id = realmRef;
          client_ids = {
            targets = [
              {
                type = "openid_client";
                field = "id";
              }
            ];
            managedOnly = false;
          };
        };
      };
      role_admin_permissions = {
        refs = {
          realm_id = realmRef;
          role_ids = {
            targets = [
              {
                type = "role";
                field = "id";
              }
            ];
            managedOnly = false;
          };
        };
      };
      users_admin_permissions = {
        refs.realm_id = realmRef;
      };
      realm_client_registration_policy = {
        refs.realm_id = realmRef;
        description = "Per-realm client-registration policy (`provider_id` selects the policy type, `sub_type` its anonymous/authenticated scope, `config` its settings).";
      };
      workflow = {
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
