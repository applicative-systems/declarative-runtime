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
