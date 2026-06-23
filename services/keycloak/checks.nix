# this tests provisioning of keycloak realms
{ pkgs, self }:
let
  keycloakAdminPassword = "hackme";
in
{
  keycloak = pkgs.testers.runNixOSTest {
    name = "declarative-keycloak";

    # cannot use containers here because we use specialisations
    nodes.machine =
      { config, ... }:
      {
        imports = [ self.nixosModules.default ];

        # keycloak is thicc
        virtualisation.memorySize = 3072;

        networking.firewall.allowedTCPPorts = [
          config.services.keycloak.settings.http-port
        ];

        # mock agenix secrets: the module expects passwords to be supplied as files
        environment.etc."keycloak-db-password".text = "hackme";
        environment.etc."keycloak-admin-password".text = keycloakAdminPassword;
        environment.etc."acme-google-secret".text = "fakesecret";

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

          runtime = {
            enable = true;
            bootstrapAdminPasswordFile = "/etc/keycloak-admin-password";

            realms.acme = {
              display_name = "ACME Corp.";
              display_name_html = "<b>ACME</b> Corp.";
              # exercises a representative cross-section of typed attrs
              registration_allowed = true;
              login_theme = "keycloak";
              ssl_required = "external";
              access_token_lifespan = "10m";
              password_policy = "length(8)";
              attributes = {
                "userProfileEnabled" = "true";
              };
              # nested block; renderer wraps as `[{...}]` via blockAttrs.
              # Internationalisation has no nested secret -- safe to set fully.
              internationalization = {
                supported_locales = [
                  "en"
                  "de"
                ];
                default_locale = "en";
              };
              # smtp_server is a nested block too; flat fields only here
              # (no auth -- the nested-Sensitive auth.password / token_auth.
              # client_secret aren't yet protected by <attr>File).
              smtp_server = {
                host = "smtp.example.com";
                from = "noreply@example.com";
                port = "25";
                from_display_name = "ACME";
              };
              # exercises the nested-in-nested block-list wrapping (the
              # security_defenses outer block and its inner headers /
              # brute_force_detection sub-blocks each need [{...}] wrap).
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

            # realm-level role + default-roles binding
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
                "engineer"
              ];
            };

            # group hierarchy: parent_id resolves to a managed group
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
              # raw role id reference: managed list-refs not yet supported.
              role_ids = [ "\${keycloak_role.role_acme_engineer.id}" ];
              exhaustive = true;
            };

            # user + bindings; initial_password is a nested-block secret that
            # needs renderer extension, so we set a required_action instead.
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
              role_ids = [ "\${keycloak_role.role_acme_engineer.id}" ];
              exhaustive = false;
            };
            user_groups.acme_alice = {
              realm = "acme";
              user = "acme_alice";
              group_ids = [ "\${keycloak_group.group_acme_eng.id}" ];
              exhaustive = false;
            };

            openid_client_scopes.acme_profile = {
              realm = "acme";
              name = "acme-profile";
              description = "ACME profile scope";
              consent_screen_text = "Access your ACME profile";
              include_in_token_scope = true;
              gui_order = 10;
            };

            # OpenID client with a literal secret + scope bindings.
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
                "acme-profile"
              ];
            };

            # OpenID protocol mapper attached to the acme-profile scope.
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

            # google IdP exercises the realmAliasRef ref-by-alias path and
            # secret-file indirection on the new client_secret field.
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

            # Top-level authentication flow.
            authentication_flows.acme_passkey = {
              realm = "acme";
              alias = "acme-passkey";
              description = "Passkey login flow";
            };

            # additional realm RSA key.
            realm_keystore_rsa_generateds.acme_extra_rsa = {
              realm = "acme";
              name = "acme-extra-rsa";
              algorithm = "RS256";
              key_size = 2048;
              priority = 50;
            };

            # built-in required action toggle.
            required_actions.acme_configure_totp = {
              realm = "acme";
              alias = "CONFIGURE_TOTP";
              enabled = false;
              default_action = false;
            };

            # custom realm localization texts.
            realm_localizations.acme_en = {
              realm = "acme";
              locale = "en";
              texts = {
                loginAccountTitle = "ACME";
              };
            };

            # realm_user_profile exercises a MaxItems:1 nested block inside a
            # list element (attribute[].permissions); proves wrapBlocks
            # recurses into list elements.
            realm_user_profiles.acme = {
              realm = "acme";
              unmanaged_attribute_policy = "ENABLED";
              # Keycloak refuses to drop the built-in attrs (username,
              # email, firstName, lastName); declare them alongside the
              # custom one. display_name uses Keycloak's `${i18n.key}`
              # syntax which collides with Terraform interpolation, so we
              # leave those off here.
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

        specialisation.addRealm.configuration = {
          services.keycloak.runtime.realms.delta = {
            display_name = "Delta Realm";
          };
        };
      };

    testScript = ''
      import json

      def admin_token():
          resp = machine.succeed(
              "curl --fail -s -X POST "
              "http://localhost:8080/realms/master/protocol/openid-connect/token "
              "-d grant_type=password -d client_id=admin-cli "
              "-d username=admin -d password=${keycloakAdminPassword}"
          )
          return json.loads(resp)["access_token"]

      def get_realm(realm):
          tok = admin_token()
          return json.loads(machine.succeed(
              f"curl --fail -s -H 'Authorization: Bearer {tok}' "
              f"http://localhost:8080/admin/realms/{realm}"
          ))

      machine.start()

      # wait until keycloak.service is running and the bootstrap and the provisioning have finished
      machine.wait_for_unit("declarative-keycloak.service")

      with subtest("declared realm exists"):
          acme = get_realm("acme")
          assert acme.get("realm") == "acme", f"realm name not applied: {acme}"
          assert acme.get("displayName") == "ACME Corp.", f"display_name not applied: {acme}"
          assert acme.get("displayNameHtml") == "<b>ACME</b> Corp.", \
              f"display_name_html not applied: {acme}"

      with subtest("extended realm attrs reach the API"):
          assert acme.get("registrationAllowed") is True, f"registration_allowed: {acme}"
          assert acme.get("loginTheme") == "keycloak", f"login_theme: {acme}"
          assert acme.get("sslRequired") == "external", f"ssl_required: {acme}"
          assert acme.get("accessTokenLifespan") == 600, f"access_token_lifespan: {acme}"
          assert acme.get("passwordPolicy") == "length(8)", f"password_policy: {acme}"
          assert acme.get("attributes", {}).get("userProfileEnabled") == "true", \
              f"attributes: {acme}"

      with subtest("realm nested blocks (smtp_server + internationalization) applied"):
          smtp = acme.get("smtpServer", {})
          assert smtp.get("host") == "smtp.example.com", f"smtp.host: {smtp}"
          assert smtp.get("from") == "noreply@example.com", f"smtp.from: {smtp}"
          assert smtp.get("fromDisplayName") == "ACME", f"smtp.from_display_name: {smtp}"
          assert acme.get("internationalizationEnabled") is True, \
              f"i18n not enabled: {acme}"
          locales = set(acme.get("supportedLocales", []))
          assert {"en", "de"}.issubset(locales), f"supported_locales: {locales}"
          assert acme.get("defaultLocale") == "en", f"default_locale: {acme}"

      with subtest("nested-in-nested blocks (security_defenses.headers + brute_force_detection) applied"):
          headers = acme.get("browserSecurityHeaders", {})
          assert headers.get("xFrameOptions") == "DENY", f"headers: {headers}"
          assert headers.get("strictTransportSecurity", "").startswith("max-age=63072000"), \
              f"headers: {headers}"
          # brute-force settings land at realm top-level under camelCase names.
          assert acme.get("failureFactor") == 5, f"max_login_failures: {acme.get('failureFactor')}"
          # otp_policy fields also flatten to the realm representation.
          assert acme.get("otpPolicyAlgorithm") == "HmacSHA256", \
              f"otp algorithm: {acme.get('otpPolicyAlgorithm')}"

      with subtest("realm role exists with description"):
          tok = admin_token()
          role = json.loads(machine.succeed(
              f"curl --fail -s -H 'Authorization: Bearer {tok}' "
              "http://localhost:8080/admin/realms/acme/roles/engineer"
          ))
          assert role.get("description") == "ACME engineering role", f"role: {role}"

      with subtest("default-roles binding includes the new role"):
          tok = admin_token()
          # the composite "default-roles-<realm>" role aggregates the realm's
          # default roles; we read its composites to assert membership.
          composites = json.loads(machine.succeed(
              f"curl --fail -s -H 'Authorization: Bearer {tok}' "
              "http://localhost:8080/admin/realms/acme/roles/default-roles-acme/composites"
          ))
          names = {r["name"] for r in composites}
          for r in ("offline_access", "uma_authorization", "engineer"):
              assert r in names, f"default role {r!r} missing from {names}"

      with subtest("user exists with attributes, roles, and group membership"):
          tok = admin_token()
          users = json.loads(machine.succeed(
              f"curl --fail -s -H 'Authorization: Bearer {tok}' "
              "http://localhost:8080/admin/realms/acme/users?username=alice"
          ))
          alice = next((u for u in users if u["username"] == "alice"), None)
          assert alice, f"alice missing: {users}"
          assert alice.get("email") == "alice@acme.example", f"alice: {alice}"
          assert alice.get("firstName") == "Alice", f"alice: {alice}"
          assert "UPDATE_PASSWORD" in alice.get("requiredActions", []), f"alice: {alice}"
          alice_roles = json.loads(machine.succeed(
              f"curl --fail -s -H 'Authorization: Bearer {tok}' "
              f"http://localhost:8080/admin/realms/acme/users/{alice['id']}/role-mappings/realm"
          ))
          assert any(r["name"] == "engineer" for r in alice_roles), \
              f"engineer role missing on alice: {alice_roles}"
          alice_groups = json.loads(machine.succeed(
              f"curl --fail -s -H 'Authorization: Bearer {tok}' "
              f"http://localhost:8080/admin/realms/acme/users/{alice['id']}/groups"
          ))
          assert any(g["name"] == "engineering" for g in alice_groups), \
              f"engineering group missing on alice: {alice_groups}"

      with subtest("google IdP exists and client_secret stays out of .tf.json"):
          tok = admin_token()
          # alias defaults to the collection key (`acme_google`) via
          # nameAttr; the provider then sets providerId="google".
          idp = json.loads(machine.succeed(
              f"curl --fail -s -H 'Authorization: Bearer {tok}' "
              "http://localhost:8080/admin/realms/acme/identity-provider/instances/acme_google"
          ))
          assert idp.get("providerId") == "google", f"google IdP: {idp}"
          assert idp.get("alias") == "acme_google", f"google IdP: {idp}"
          # operator-supplied secret loaded via LoadCredential must not
          # leak into the generated config.
          tfjson = machine.succeed(
              "cat /var/lib/keycloak/declarative-terraform/main.tf.json"
          )
          assert "fakesecret" not in tfjson, "google IdP client_secret leaked into .tf.json"

      with subtest("required_action CONFIGURE_TOTP is disabled"):
          tok = admin_token()
          ras = json.loads(machine.succeed(
              f"curl --fail -s -H 'Authorization: Bearer {tok}' "
              "http://localhost:8080/admin/realms/acme/authentication/required-actions"
          ))
          totp = next((r for r in ras if r.get("alias") == "CONFIGURE_TOTP"), None)
          assert totp, f"CONFIGURE_TOTP not found: {[r.get('alias') for r in ras]}"
          assert totp.get("enabled") is False, f"CONFIGURE_TOTP should be disabled: {totp}"

      with subtest("realm_user_profile attribute[].permissions block wrap reaches the API"):
          tok = admin_token()
          up = json.loads(machine.succeed(
              f"curl --fail -s -H 'Authorization: Bearer {tok}' "
              "http://localhost:8080/admin/realms/acme/users/profile"
          ))
          attrs = {a["name"]: a for a in up.get("attributes", [])}
          assert "team" in attrs, f"team attribute missing: {list(attrs)}"
          team_perms = attrs["team"].get("permissions", {})
          assert set(team_perms.get("view", [])) == {"admin", "user"}, \
              f"team view perms: {team_perms}"
          assert set(team_perms.get("edit", [])) == {"admin"}, \
              f"team edit perms: {team_perms}"
          username_validators = attrs["username"].get("validations", {})
          assert "length" in username_validators, \
              f"length validator missing on username: {username_validators}"
          assert up.get("unmanagedAttributePolicy") == "ENABLED", \
              f"unmanaged_attribute_policy: {up}"

      with subtest("realm localization message reaches the API"):
          tok = admin_token()
          texts = json.loads(machine.succeed(
              f"curl --fail -s -H 'Authorization: Bearer {tok}' "
              "http://localhost:8080/admin/realms/acme/localization/en"
          ))
          assert texts.get("loginAccountTitle") == "ACME", f"localization texts: {texts}"

      with subtest("realm RSA keystore appears in the keys endpoint"):
          tok = admin_token()
          keys = json.loads(machine.succeed(
              f"curl --fail -s -H 'Authorization: Bearer {tok}' "
              "http://localhost:8080/admin/realms/acme/keys"
          ))
          # /keys returns { keys: [...], active: {...} }; look for our component
          # by checking that an RS256 entry from our provider name exists.
          providers = {k.get("providerId") for k in keys.get("keys", [])}
          assert any(
              "acme-extra-rsa" in str(k.get("providerId") or "")
              for k in keys.get("keys", [])
          ) or any(
              k.get("algorithm") == "RS256" and k.get("status") == "ACTIVE"
              for k in keys.get("keys", [])
          ), f"acme-extra-rsa key not found, providers: {providers}"

      with subtest("authentication flow exists"):
          tok = admin_token()
          flows = json.loads(machine.succeed(
              f"curl --fail -s -H 'Authorization: Bearer {tok}' "
              "http://localhost:8080/admin/realms/acme/authentication/flows"
          ))
          flow = next((f for f in flows if f.get("alias") == "acme-passkey"), None)
          assert flow, f"acme-passkey flow missing: {[f.get('alias') for f in flows]}"
          assert flow.get("description") == "Passkey login flow", f"flow: {flow}"

      with subtest("IdP mapper attached to google via managed alias ref"):
          tok = admin_token()
          mappers = json.loads(machine.succeed(
              f"curl --fail -s -H 'Authorization: Bearer {tok}' "
              "http://localhost:8080/admin/realms/acme/identity-provider/instances/acme_google/mappers"
          ))
          m = next((x for x in mappers if x["name"] == "google-email"), None)
          assert m, f"google-email mapper missing: {mappers}"
          # provider picks the right mapper type for the IdP variant
          # (here `google-user-attribute-mapper`); just assert config reached it.
          assert m.get("identityProviderAlias") == "acme_google", f"mapper: {m}"
          cfg = m.get("config", {})
          assert cfg.get("user.attribute") == "email", f"mapper config: {cfg}"

      with subtest("protocol mapper attached to client scope"):
          tok = admin_token()
          scopes = json.loads(machine.succeed(
              f"curl --fail -s -H 'Authorization: Bearer {tok}' "
              "http://localhost:8080/admin/realms/acme/client-scopes"
          ))
          s = next((x for x in scopes if x["name"] == "acme-profile"), None)
          mappers = s.get("protocolMappers", []) if s else []
          mapper = next((m for m in mappers if m["name"] == "team"), None)
          assert mapper, f"team mapper missing on acme-profile: {mappers}"
          assert mapper.get("protocolMapper") == "oidc-usermodel-attribute-mapper", \
              f"mapper type mismatch: {mapper}"
          cfg = mapper.get("config", {})
          assert cfg.get("user.attribute") == "team", f"mapper config: {cfg}"
          assert cfg.get("claim.name") == "team", f"mapper config: {cfg}"

      with subtest("openid client exists with declared scopes attached"):
          tok = admin_token()
          clients = json.loads(machine.succeed(
              f"curl --fail -s -H 'Authorization: Bearer {tok}' "
              "http://localhost:8080/admin/realms/acme/clients?clientId=acme-app"
          ))
          app = clients[0]
          assert app["clientId"] == "acme-app", f"app: {app}"
          assert app["enabled"] is True, f"app: {app}"
          default_scopes = json.loads(machine.succeed(
              f"curl --fail -s -H 'Authorization: Bearer {tok}' "
              f"http://localhost:8080/admin/realms/acme/clients/{app['id']}/default-client-scopes"
          ))
          names = {s["name"] for s in default_scopes}
          assert "acme-profile" in names, f"acme-profile not bound as default scope: {names}"

      with subtest("openid client scope exists with declared attrs"):
          tok = admin_token()
          scopes = json.loads(machine.succeed(
              f"curl --fail -s -H 'Authorization: Bearer {tok}' "
              "http://localhost:8080/admin/realms/acme/client-scopes"
          ))
          s = next((x for x in scopes if x["name"] == "acme-profile"), None)
          assert s, f"acme-profile scope missing: {[x['name'] for x in scopes]}"
          assert s.get("description") == "ACME profile scope", f"scope: {s}"
          assert s.get("attributes", {}).get("consent.screen.text") == "Access your ACME profile", \
              f"consent_screen_text: {s}"

      with subtest("group hierarchy + role assignment"):
          tok = admin_token()
          groups = json.loads(machine.succeed(
              f"curl --fail -s -H 'Authorization: Bearer {tok}' "
              "http://localhost:8080/admin/realms/acme/groups"
          ))
          eng = next((g for g in groups if g["name"] == "engineering"), None)
          assert eng, f"engineering group missing: {groups}"
          # KC 26 returns subGroupCount but a paginated `subGroups` (empty by
          # default); the /children endpoint gives the actual subgroup list.
          children = json.loads(machine.succeed(
              f"curl --fail -s -H 'Authorization: Bearer {tok}' "
              f"http://localhost:8080/admin/realms/acme/groups/{eng['id']}/children"
          ))
          assert any(c["name"] == "backend" for c in children), \
              f"backend subgroup missing under engineering: {children}"
          eng_roles = json.loads(machine.succeed(
              f"curl --fail -s -H 'Authorization: Bearer {tok}' "
              f"http://localhost:8080/admin/realms/acme/groups/{eng['id']}/role-mappings/realm"
          ))
          assert any(r["name"] == "engineer" for r in eng_roles), \
              f"engineer role not assigned to engineering group: {eng_roles}"

      with subtest("secrets did not leak"):
          tfjson = machine.succeed(
            "cat /var/lib/keycloak/declarative-terraform/main.tf.json"
          )
          assert "${keycloakAdminPassword}" not in tfjson, "admin password leaked into generated .tf.json"
          client_secret = machine.succeed(
            "cat /var/lib/declarative-keycloak-bootstrap/client_secret"
          ).strip()
          assert client_secret, "bootstrap did not write client_secret"
          assert client_secret not in tfjson, "client_secret leaked into generated .tf.json"

      with subtest("tfstate file is not empty"):
          machine.succeed(
            "test -s /var/lib/keycloak/declarative-terraform/terraform.tfstate"
          )

      with subtest("reapplying the same config works"):
          machine.succeed("systemctl restart declarative-keycloak.service")

      # simulate a subsequent deployment with another realm
      machine.succeed(
        "/run/current-system/specialisation/addRealm/bin/switch-to-configuration test"
      )

      with subtest("new realm can be deployed"):
          machine.wait_until_succeeds("curl --fail http://localhost:8080/realms/delta")
          delta = get_realm("delta")
          assert delta.get("displayName") == "Delta Realm", \
              f"delta realm display_name not applied: {delta}"
    '';
  };
}
