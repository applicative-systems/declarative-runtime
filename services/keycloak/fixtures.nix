# `services.keycloak.runtime` fixtures, shared by the VM tests in ./checks.nix
# and by the `keycloak-rendered-fixtures` package.
#
# why the indirection: `keycloak-rendered-fixtures` renders these through the
# real option system and renderer, so the `.tf.json` snapshot that guards
# refactors of the resource surface is produced from exactly the configurations
# the VM tests prove converge against a live Keycloak.
{
  # Core test: one realm, plus the realm its specialisation adds.
  core = {
    realms.acme = {
      display_name = "ACME Corp.";
      display_name_html = "<b>ACME</b> Corp.";
    };
  };
  coreAddRealm = {
    realms.delta = {
      display_name = "Delta Realm";
    };
  };

  # Roles, groups, users and their bindings via managed-key list refs.
  rbac = {
    realms.acme.display_name = "ACME";

    roles.acme_engineer = {
      realm = "acme";
      name = "engineer";
      description = "ACME engineering role";
    };
    default_roles.acme = {
      realm = "acme";
      default_roles = [
        "offline_access"
        "uma_authorization"
        "acme_engineer" # managed key, resolves to role name "engineer"
      ];
    };

    groups.acme_eng = {
      realm = "acme";
      name = "engineering";
      attributes."team" = "infra";
    };
    groups.acme_eng_backend = {
      realm = "acme";
      name = "backend";
      parent = "acme_eng";
    };
    group_roles.acme_eng_admins = {
      realm = "acme";
      group = "acme_eng";
      role_ids = [ "acme_engineer" ]; # managed key
      exhaustive = true;
    };

    users.acme_alice = {
      realm = "acme";
      username = "alice";
      email = "alice@acme.example";
      first_name = "Alice";
      last_name = "Anderson";
      email_verified = true;
      required_actions = [ "UPDATE_PASSWORD" ];
    };
    user_roles.acme_alice = {
      realm = "acme";
      user = "acme_alice";
      role_ids = [ "acme_engineer" ];
      exhaustive = false;
    };
    user_groups.acme_alice = {
      realm = "acme";
      user = "acme_alice";
      group_ids = [ "acme_eng" ]; # managed key
      exhaustive = false;
    };
  };

  # OpenID clients + scopes + protocol mapper + default-scope binding.
  clients = {
    realms.acme.display_name = "ACME";

    openid_client_scopes.acme_profile = {
      realm = "acme";
      name = "acme-profile";
      description = "ACME profile scope";
      consent_screen_text = "Access your ACME profile";
      include_in_token_scope = true;
      gui_order = 10;
    };

    openid_clients.acme_app = {
      realm = "acme";
      client_id = "acme-app";
      name = "ACME App";
      access_type = "CONFIDENTIAL";
      client_secretFile = "/etc/acme-app-client-secret";
      standard_flow_enabled = true;
      direct_access_grants_enabled = true;
      service_accounts_enabled = true;
      valid_redirect_uris = [ "https://app.acme.example/*" ];
      web_origins = [ "https://app.acme.example" ];
      consent_required = false;
      full_scope_allowed = true;
    };
    openid_client_default_scopes.acme_app = {
      realm = "acme";
      client = "acme_app";
      default_scopes = [
        "profile"
        "email"
        "acme_profile" # managed key, resolves to scope name "acme-profile"
      ];
    };

    # protocol mapper attached to the managed scope by key.
    openid_user_attribute_protocol_mappers.team_claim = {
      realm = "acme";
      client_scope = "acme_profile";
      name = "team";
      user_attribute = "team";
      claim_name = "team";
      claim_value_type = "String";
      add_to_id_token = true;
      add_to_access_token = true;
      add_to_userinfo = true;
    };
  };

  # Realm extras: extended realm attrs, smtp with nested-secret,
  # security_defenses (nested-in-nested), otp_policy, realm_user_profile
  # (nested-in-list), a keystore, required_action, localization.
  realmExtras = {
    realms.acme = {
      display_name = "ACME Corp.";
      display_name_html = "<b>ACME</b> Corp.";
      # cross-section of the extended realm attrs.
      registration_allowed = true;
      login_theme = "keycloak";
      ssl_required = "external";
      access_token_lifespan = "10m";
      password_policy = "length(8)";
      attributes."userProfileEnabled" = "true";
      internationalization = {
        supported_locales = [
          "en"
          "de"
        ];
        default_locale = "en";
      };
      # smtp with a nested-secret indirection (auth.passwordFile).
      smtp_server = {
        host = "smtp.example.com";
        from = "noreply@example.com";
        port = "25";
        from_display_name = "ACME";
        auth = {
          username = "noreply";
          passwordFile = "/etc/acme-smtp-password";
        };
      };
      # nested-in-nested block wrap (headers + brute_force_detection
      # inside security_defenses).
      security_defenses = {
        headers = {
          x_frame_options = "DENY";
          strict_transport_security = "max-age=63072000; includeSubDomains; preload";
        };
        brute_force_detection = {
          permanent_lockout = false;
          max_login_failures = 5;
        };
      };
      otp_policy = {
        type = "totp";
        algorithm = "HmacSHA256";
        digits = 6;
        period = 30;
        initial_counter = 0;
        look_ahead_window = 1;
      };
    };

    realm_keystore_rsa_generateds.acme_extra_rsa = {
      realm = "acme";
      name = "acme-extra-rsa";
      algorithm = "RS256";
      key_size = 2048;
      priority = 50;
    };

    required_actions.acme_configure_totp = {
      realm = "acme";
      alias = "CONFIGURE_TOTP";
      enabled = false;
      default_action = false;
    };

    realm_localizations.acme_en = {
      realm = "acme";
      locale = "en";
      texts.loginAccountTitle = "ACME";
    };

    # realm_user_profile exercises a nested MaxItems:1 block inside a
    # list element (attribute[].permissions). keycloak refuses to drop
    # the built-in attrs, so declare them alongside the custom one.
    realm_user_profiles.acme = {
      realm = "acme";
      unmanaged_attribute_policy = "ENABLED";
      attribute = [
        {
          name = "username";
          permissions = {
            view = [
              "admin"
              "user"
            ];
            edit = [
              "admin"
              "user"
            ];
          };
          validator = [
            {
              name = "length";
              config = {
                min = "3";
                max = "255";
              };
            }
          ];
        }
        {
          name = "email";
          permissions = {
            view = [
              "admin"
              "user"
            ];
            edit = [
              "admin"
              "user"
            ];
          };
        }
        {
          name = "firstName";
          permissions = {
            view = [
              "admin"
              "user"
            ];
            edit = [
              "admin"
              "user"
            ];
          };
        }
        {
          name = "lastName";
          permissions = {
            view = [
              "admin"
              "user"
            ];
            edit = [
              "admin"
              "user"
            ];
          };
        }
        {
          name = "team";
          display_name = "Team";
          group = "metadata";
          permissions = {
            view = [
              "admin"
              "user"
            ];
            edit = [ "admin" ];
          };
        }
      ];
      group = [
        {
          name = "metadata";
          display_header = "Metadata";
          display_description = "ACME-internal user metadata";
        }
      ];
    };
  };

  # Identity providers + IdP mappers + an authentication flow.
  idp = {
    realms.acme.display_name = "ACME";

    # google IdP exercises realm-alias resolution + secret-file indirection.
    oidc_google_identity_providers.acme_google = {
      realm = "acme";
      client_id = "fake-client-id";
      client_secretFile = "/etc/acme-google-secret";
    };

    # IdP mapper exercises the multi-target idp-alias ref.
    attribute_importer_identity_provider_mappers.google_email = {
      realm = "acme";
      identity_provider = "acme_google";
      name = "google-email";
      user_attribute = "email";
      claim_name = "email";
    };

    authentication_flows.acme_passkey = {
      realm = "acme";
      alias = "acme-passkey";
      description = "Passkey login flow";
    };
  };

  # OIDC password-grant end-to-end: a declared user authenticating against a
  # declared client.
  e2e = {
    realms.acme = {
      display_name = "ACME";
      login_with_email_allowed = true;
    };

    users.alice = {
      realm = "acme";
      username = "alice";
      email = "alice@acme.test";
      first_name = "Alice";
      last_name = "Tester";
      enabled = true;
      email_verified = true;
      initial_password = {
        valueFile = "/etc/secrets/alice-pw";
        temporary = false;
      };
    };

    # PUBLIC client, only direct access grants enabled (the password
    # grant doesn't use redirects, so no valid_redirect_uris and
    # standard/implicit flow off -- the provider rejects redirect
    # URIs without a flow that uses them).
    openid_clients.test_app = {
      realm = "acme";
      client_id = "test-app";
      name = "Test App";
      access_type = "PUBLIC";
      standard_flow_enabled = false;
      direct_access_grants_enabled = true;
    };
  };
}
