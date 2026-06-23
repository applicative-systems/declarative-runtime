{ pkgs, self }:
{
  keycloak = pkgs.testers.runNixOSTest {
    name = "declarative-keycloak";

    nodes.machine =
      { config, ... }:
      {
        imports = [ self.nixosModules.default ];

        # keycloak is thicc
        virtualisation.memorySize = 3072;

        networking.firewall.allowedTCPPorts = [
          config.services.keycloak.settings.http-port
        ];

        # keycloak does not like store paths for db password
        environment.etc."keycloak-db-password".text = "hackme";

        services.keycloak = {
          enable = true;
          settings = {
            hostname = "keycloak";
            http-port = 8080;
            http-enabled = true;
            hostname-strict = false;
          };

          database.passwordFile = "/etc/keycloak-db-password";

          runtime.enable = true;
        };
      };

    testScript = ''
      machine.start()
      machine.wait_for_unit("keycloak.service")
      machine.wait_for_open_port(8080)
      machine.wait_until_succeeds("curl -sSf http://localhost:8080/realms/master")
    '';
  };
}
