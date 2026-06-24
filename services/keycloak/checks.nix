# Per-resource-family keycloak tests. The `keycloak` test is a full VM
# (specialisations only work in QEMU nodes); the rest are nspawn containers
# for faster boot and tighter focus.
{ pkgs, self }:
let
  inherit (pkgs) lib;
  keycloakAdminPassword = "hackme";

  # Python helpers; each takes the machine reference (`machine` for VMs,
  # `keycloak` for containers) so the body is identical across both shapes.
  pyHelpers = ''
    import json
    def admin_token(m):
        resp = m.succeed(
            "curl --fail -s -X POST "
            "http://localhost:8080/realms/master/protocol/openid-connect/token "
            "-d grant_type=password -d client_id=admin-cli "
            "-d username=admin -d password=${keycloakAdminPassword}"
        )
        return json.loads(resp)["access_token"]
    def admin_get(m, path):
        tok = admin_token(m)
        return json.loads(m.succeed(
            f"curl --fail -s -H 'Authorization: Bearer {tok}' "
            f"http://localhost:8080/admin/realms/{path}"
        ))
    def get_realm(m, realm):
        return admin_get(m, realm)
  '';

  # Common keycloak service config every test reuses. `runtime` carries
  # the per-test resource fixture; `extraEtc` mocks operator secret files.
  mkHost =
    {
      runtime,
      extraEtc ? { },
    }:
    {
      config,
      ...
    }:
    {
      imports = [ self.nixosModules.default ];

      networking.firewall.allowedTCPPorts = [
        config.services.keycloak.settings.http-port
      ];

      environment.etc = {
        "keycloak-db-password".text = "hackme";
        "keycloak-admin-password".text = keycloakAdminPassword;
      }
      // extraEtc;

      services.keycloak = {
        enable = true;
        initialAdminPassword = keycloakAdminPassword;
        settings = {
          hostname = "keycloak";
          http-port = 8080;
          http-enabled = true; # HTTP-only test deployment
          hostname-strict = false;
        };

        database.passwordFile = "/etc/keycloak-db-password";

        runtime = runtime // {
          enable = true;
          bootstrapAdminPasswordFile = "/etc/keycloak-admin-password";
        };
      };
    };
in
{
  # Core test: full VM proving the boot -> bootstrap -> reconcile chain
  # plus config-change reconciliation via a specialisation.
  keycloak = pkgs.testers.runNixOSTest {
    name = "declarative-keycloak";

    nodes.machine =
      args:
      lib.recursiveUpdate
        (mkHost {
          runtime.realms.acme = {
            display_name = "ACME Corp.";
            display_name_html = "<b>ACME</b> Corp.";
          };
        } args)
        {
          # keycloak is thicc -- only VMs accept memorySize.
          virtualisation.memorySize = 3072;
          specialisation.addRealm.configuration.services.keycloak.runtime.realms.delta = {
            display_name = "Delta Realm";
          };
        };

    testScript = ''
      ${pyHelpers}
      machine.start()

      # whole chain (keycloak -> bootstrap -> reconciler) must converge.
      machine.wait_for_unit("declarative-keycloak.service")

      with subtest("declared realm exists with display_name applied"):
          acme = get_realm(machine, "acme")
          assert acme.get("realm") == "acme", f"realm: {acme}"
          assert acme.get("displayName") == "ACME Corp.", f"displayName: {acme}"
          assert acme.get("displayNameHtml") == "<b>ACME</b> Corp.", \
              f"displayNameHtml: {acme}"

      with subtest("admin password and minted client_secret kept out of .tf.json"):
          tfjson = machine.succeed(
              "cat /var/lib/keycloak/declarative-terraform/main.tf.json"
          )
          assert "${keycloakAdminPassword}" not in tfjson, \
              "admin password leaked into .tf.json"
          client_secret = machine.succeed(
              "cat /var/lib/declarative-keycloak-bootstrap/client_secret"
          ).strip()
          assert client_secret and client_secret not in tfjson, \
              "minted client_secret leaked into .tf.json"

      with subtest("tfstate file exists and is non-empty"):
          machine.succeed(
              "test -s /var/lib/keycloak/declarative-terraform/terraform.tfstate"
          )

      with subtest("reapplying the same config is a no-op"):
          machine.succeed("systemctl restart declarative-keycloak.service")

      with subtest("new realm is applied on config switch"):
          machine.succeed(
              "/run/current-system/specialisation/addRealm/bin/switch-to-configuration test"
          )
          machine.wait_until_succeeds("curl --fail http://localhost:8080/realms/delta")
          delta = get_realm(machine, "delta")
          assert delta.get("displayName") == "Delta Realm", f"delta: {delta}"
    '';
  };

  # RBAC: roles, groups, users + bindings via managed-key list refs.
  keycloak-rbac = pkgs.testers.runNixOSTest {
    name = "declarative-keycloak-rbac";

    containers.keycloak = mkHost {
      runtime = {
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
    };

    testScript = ''
      ${pyHelpers}
      start_all()
      keycloak.wait_for_unit("declarative-keycloak.service")

      with subtest("role exists with description"):
          role = admin_get(keycloak, "acme/roles/engineer")
          assert role.get("description") == "ACME engineering role", f"role: {role}"

      with subtest("default-roles binding includes the managed role"):
          composites = admin_get(keycloak, "acme/roles/default-roles-acme/composites")
          names = {r["name"] for r in composites}
          for r in ("offline_access", "uma_authorization", "engineer"):
              assert r in names, f"default role {r!r} missing from {names}"

      with subtest("group hierarchy + managed-key role binding"):
          groups = admin_get(keycloak, "acme/groups")
          eng = next((g for g in groups if g["name"] == "engineering"), None)
          assert eng, f"engineering group missing: {[g['name'] for g in groups]}"
          children = admin_get(keycloak, f"acme/groups/{eng['id']}/children")
          assert any(c["name"] == "backend" for c in children), \
              f"backend subgroup missing: {children}"
          eng_roles = admin_get(keycloak, f"acme/groups/{eng['id']}/role-mappings/realm")
          assert any(r["name"] == "engineer" for r in eng_roles), \
              f"engineer role missing on engineering: {eng_roles}"

      with subtest("user attributes + managed-key role + group bindings"):
          users = admin_get(keycloak, "acme/users?username=alice")
          alice = next((u for u in users if u["username"] == "alice"), None)
          assert alice, f"alice missing: {users}"
          assert alice.get("email") == "alice@acme.example"
          assert alice.get("firstName") == "Alice"
          assert "UPDATE_PASSWORD" in alice.get("requiredActions", [])
          alice_roles = admin_get(keycloak, f"acme/users/{alice['id']}/role-mappings/realm")
          assert any(r["name"] == "engineer" for r in alice_roles), \
              f"engineer role missing on alice: {alice_roles}"
          alice_groups = admin_get(keycloak, f"acme/users/{alice['id']}/groups")
          assert any(g["name"] == "engineering" for g in alice_groups), \
              f"engineering group missing on alice: {alice_groups}"
    '';
  };

  # OpenID clients + scopes + a protocol mapper + default-scope binding.
  keycloak-clients = pkgs.testers.runNixOSTest {
    name = "declarative-keycloak-clients";

    containers.keycloak = mkHost {
      runtime = {
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
          client_secret = "topsecret";
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

        # Protocol mapper attached to the managed scope via its key.
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
    };

    testScript = ''
      ${pyHelpers}
      start_all()
      keycloak.wait_for_unit("declarative-keycloak.service")

      with subtest("openid client scope exists with declared attrs"):
          scopes = admin_get(keycloak, "acme/client-scopes")
          s = next((x for x in scopes if x["name"] == "acme-profile"), None)
          assert s, f"acme-profile scope missing: {[x['name'] for x in scopes]}"
          assert s.get("description") == "ACME profile scope", f"scope: {s}"
          assert s.get("attributes", {}).get("consent.screen.text") == "Access your ACME profile", \
              f"consent_screen_text: {s}"

      with subtest("openid client exists with declared default scopes"):
          clients = admin_get(keycloak, "acme/clients?clientId=acme-app")
          app = clients[0]
          assert app["enabled"] is True
          bindings = admin_get(keycloak, f"acme/clients/{app['id']}/default-client-scopes")
          names = {b["name"] for b in bindings}
          assert "acme-profile" in names, \
              f"acme-profile not bound as default scope: {names}"

      with subtest("protocol mapper attached to client scope"):
          # protocolMappers travel with the client-scope representation.
          scopes = admin_get(keycloak, "acme/client-scopes")
          s = next((x for x in scopes if x["name"] == "acme-profile"), None)
          assert s, f"acme-profile scope missing: {[x['name'] for x in scopes]}"
          mapper = next(
              (m for m in (s.get("protocolMappers") or []) if m["name"] == "team"),
              None,
          )
          assert mapper, f"team mapper missing on acme-profile: {s.get('protocolMappers')}"
          assert mapper.get("protocolMapper") == "oidc-usermodel-attribute-mapper", \
              f"mapper type mismatch: {mapper}"
          cfg = mapper.get("config", {})
          assert cfg.get("user.attribute") == "team", f"mapper config: {cfg}"
          assert cfg.get("claim.name") == "team", f"mapper config: {cfg}"
    '';
  };

  # Realm extras: extended realm attrs, nested-secret smtp, security
  # defenses (nested-in-nested), otp_policy, realm_user_profile (nested
  # in list elements), a keystore, required_action, localization.
  keycloak-realm-extras = pkgs.testers.runNixOSTest {
    name = "declarative-keycloak-realm-extras";

    containers.keycloak = mkHost {
      extraEtc."acme-smtp-password".text = "verysecretpassword";
      runtime = {
        realms.acme = {
          display_name = "ACME Corp.";
          display_name_html = "<b>ACME</b> Corp.";
          # extended attrs
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
          # smtp_server with nested-secret indirection.
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
          # nested-in-nested block-list wrap (security_defenses.headers,
          # security_defenses.brute_force_detection).
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

        # realm_user_profile exercises a MaxItems:1 nested block inside a
        # list element (attribute[].permissions). Keycloak refuses to drop
        # the built-in attrs; declare them alongside the custom one.
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
    };

    testScript = ''
      ${pyHelpers}
      start_all()
      keycloak.wait_for_unit("declarative-keycloak.service")
      acme = get_realm(keycloak, "acme")

      with subtest("extended realm attrs reach the API"):
          assert acme.get("registrationAllowed") is True, f"acme: {acme}"
          assert acme.get("loginTheme") == "keycloak"
          assert acme.get("sslRequired") == "external"
          assert acme.get("accessTokenLifespan") == 600
          assert acme.get("passwordPolicy") == "length(8)"
          assert acme.get("attributes", {}).get("userProfileEnabled") == "true"

      with subtest("smtp_server nested-secret stays out of .tf.json"):
          tfjson = keycloak.succeed(
              "cat /var/lib/keycloak/declarative-terraform/main.tf.json"
          )
          assert "verysecretpassword" not in tfjson, \
              "smtp_server.auth.password leaked into .tf.json"
          assert "secret_realm_acme_smtp_server_auth_password" in tfjson, \
              "nested-secret var reference missing in .tf.json"
          smtp = acme.get("smtpServer", {})
          assert smtp.get("host") == "smtp.example.com", f"smtp: {smtp}"
          assert smtp.get("from") == "noreply@example.com", f"smtp: {smtp}"

      with subtest("internationalization applied"):
          assert acme.get("internationalizationEnabled") is True
          locales = set(acme.get("supportedLocales", []))
          assert {"en", "de"}.issubset(locales), f"locales: {locales}"
          assert acme.get("defaultLocale") == "en"

      with subtest("nested-in-nested blocks (security_defenses + otp_policy) applied"):
          headers = acme.get("browserSecurityHeaders", {})
          assert headers.get("xFrameOptions") == "DENY"
          assert headers.get("strictTransportSecurity", "").startswith("max-age=63072000")
          assert acme.get("failureFactor") == 5
          assert acme.get("otpPolicyAlgorithm") == "HmacSHA256"

      with subtest("realm RSA keystore appears in the keys endpoint"):
          keys = admin_get(keycloak, "acme/keys")
          assert any(
              k.get("algorithm") == "RS256" and k.get("status") == "ACTIVE"
              for k in keys.get("keys", [])
          ), f"RS256 ACTIVE key missing: {keys}"

      with subtest("required_action CONFIGURE_TOTP is disabled"):
          ras = admin_get(keycloak, "acme/authentication/required-actions")
          totp = next((r for r in ras if r.get("alias") == "CONFIGURE_TOTP"), None)
          assert totp, f"CONFIGURE_TOTP not found: {[r.get('alias') for r in ras]}"
          assert totp.get("enabled") is False, f"CONFIGURE_TOTP should be disabled: {totp}"

      with subtest("realm localization message reaches the API"):
          texts = admin_get(keycloak, "acme/localization/en")
          assert texts.get("loginAccountTitle") == "ACME", f"localization texts: {texts}"

      with subtest("realm_user_profile attribute[].permissions block wrap works"):
          up = admin_get(keycloak, "acme/users/profile")
          attrs = {a["name"]: a for a in up.get("attributes", [])}
          assert "team" in attrs, f"team attribute missing: {list(attrs)}"
          team_perms = attrs["team"].get("permissions", {})
          assert set(team_perms.get("view", [])) == {"admin", "user"}, \
              f"team view: {team_perms}"
          assert set(team_perms.get("edit", [])) == {"admin"}, \
              f"team edit: {team_perms}"
          assert "length" in attrs["username"].get("validations", {}), \
              "length validator missing on username"
          assert up.get("unmanagedAttributePolicy") == "ENABLED"
    '';
  };

  # Identity providers + IdP mappers + an authentication flow.
  keycloak-idp = pkgs.testers.runNixOSTest {
    name = "declarative-keycloak-idp";

    containers.keycloak = mkHost {
      extraEtc."acme-google-secret".text = "fakesecret";
      runtime = {
        realms.acme.display_name = "ACME";

        # google IdP exercises realmAliasRef and secret-file indirection.
        oidc_google_identity_providers.acme_google = {
          realm = "acme";
          client_id = "fake-client-id";
          client_secretFile = "/etc/acme-google-secret";
        };

        # IdP mapper exercises idpAliasRequiredRef across IdP collections.
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
    };

    testScript = ''
      ${pyHelpers}
      start_all()
      keycloak.wait_for_unit("declarative-keycloak.service")

      with subtest("google IdP exists, client_secret kept out of .tf.json"):
          # alias defaults to the collection key (`acme_google`) via nameAttr;
          # the provider sets providerId="google".
          idp = admin_get(keycloak, "acme/identity-provider/instances/acme_google")
          assert idp.get("providerId") == "google", f"idp: {idp}"
          assert idp.get("alias") == "acme_google"
          tfjson = keycloak.succeed(
              "cat /var/lib/keycloak/declarative-terraform/main.tf.json"
          )
          assert "fakesecret" not in tfjson, \
              "google IdP client_secret leaked into .tf.json"

      with subtest("IdP mapper attached to google via managed alias ref"):
          mappers = admin_get(keycloak, "acme/identity-provider/instances/acme_google/mappers")
          m = next((x for x in mappers if x["name"] == "google-email"), None)
          assert m, f"google-email mapper missing: {mappers}"
          assert m.get("identityProviderAlias") == "acme_google", f"mapper: {m}"
          assert m.get("config", {}).get("user.attribute") == "email", f"mapper: {m}"

      with subtest("authentication flow exists with description"):
          flows = admin_get(keycloak, "acme/authentication/flows")
          flow = next((f for f in flows if f.get("alias") == "acme-passkey"), None)
          assert flow, f"acme-passkey flow missing: {[f.get('alias') for f in flows]}"
          assert flow.get("description") == "Passkey login flow"
    '';
  };
}
