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
