# Keycloak pairing check, returned as a single-entry attrset merged into the
# flake's per-system `checks`.
#
#   keycloak — Full integration test: boots a VM with services.keycloak +
#     services.keycloak.runtime and lets the pairing converge at boot with no
#     manual setup. The module's own machinery bootstraps a service-account
#     OIDC client via a companion oneshot, then the run-once reconciler
#     applies the declared realm. A specialisation adds a second realm to
#     exercise config-change reconciliation. Keycloak is a heavy JVM service,
#     so the VM gets extra memory and the bootstrap probe budget is wide.
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

        # Stand-ins for operator-managed secret files (sops/agenix in
        # production): the database password Keycloak rejects as a store
        # path (it expects an /etc-style host path), and the bootstrap admin
        # password the reconciler oneshot reads via LoadCredential.
        environment.etc."keycloak-db-password".text = "hackme";
        environment.etc."keycloak-admin-password".text = "hackme";

        services.keycloak = {
          enable = true;
          # initialAdminPassword seeds the master-realm `admin` user on
          # first boot. The bootstrap oneshot then logs in as that user
          # (reading the same secret from a file via LoadCredential) to
          # mint the service-account client.
          initialAdminPassword = "hackme";
          settings = {
            hostname = "keycloak";
            http-port = 8080;
            # HTTP-only test deployment: skip TLS material and the strict
            # hostname URL/scheme validation that aborts startup otherwise.
            http-enabled = true;
            hostname-strict = false;
          };

          database.passwordFile = "/etc/keycloak-db-password";

          # No client credentials supplied: the pairing bootstraps its own
          # service-account client at boot using the admin password file.
          runtime = {
            enable = true;
            bootstrapAdminPasswordFile = "/etc/keycloak-admin-password";

            realms.acme = {
              display_name = "ACME Corp.";
              display_name_html = "<b>ACME</b> Corp.";
            };
          };
        };

        # Exercises that the reconciler picks up a new declared resource
        # on a config switch (the bootstrap oneshot stays a no-op because
        # its credentials file persists across reboots).
        specialisation.addRealm.configuration = {
          services.keycloak.runtime.realms.delta = {
            display_name = "Delta Realm";
          };
        };
      };

    testScript = ''
      import json

      def admin_token():
          # Anonymous /realms/<r> only exposes a tiny field set (no
          # displayName); use the master-realm admin-cli token to read the
          # full realm representation via /admin/realms/<r>.
          resp = machine.succeed(
              "curl --fail -s -X POST "
              "http://localhost:8080/realms/master/protocol/openid-connect/token "
              "-d grant_type=password -d client_id=admin-cli "
              "-d username=admin -d password=hackme"
          )
          return json.loads(resp)["access_token"]

      def get_realm(realm):
          tok = admin_token()
          return json.loads(machine.succeed(
              f"curl --fail -s -H 'Authorization: Bearer {tok}' "
              f"http://localhost:8080/admin/realms/{realm}"
          ))

      machine.start()

      # The whole chain must converge at boot with zero manual setup:
      #   keycloak.service ->
      #   declarative-keycloak-bootstrap.service ->
      #   declarative-keycloak.service
      # wait_for_unit blocks until the run-once reconciler has applied
      # every declared resource successfully (a failed apply fails the unit).
      machine.wait_for_unit("declarative-keycloak.service")

      # The realm exists and its typed attributes were applied as declared.
      acme = get_realm("acme")
      assert acme.get("realm") == "acme", f"realm name not applied: {acme}"
      assert acme.get("displayName") == "ACME Corp.", f"display_name not applied: {acme}"
      assert acme.get("displayNameHtml") == "<b>ACME</b> Corp.", \
          f"display_name_html not applied: {acme}"

      # Per-secret indirection: the admin password was supplied as a host
      # file and the minted client_secret was written to /var/lib by the
      # bootstrap. Neither must appear in the generated .tf.json.
      tfjson = machine.succeed(
        "cat /var/lib/keycloak/declarative-terraform/main.tf.json"
      )
      assert "hackme" not in tfjson, "admin password leaked into generated .tf.json"
      client_secret = machine.succeed(
        "cat /var/lib/declarative-keycloak-bootstrap/client_secret"
      ).strip()
      assert client_secret, "bootstrap did not write client_secret"
      assert client_secret not in tfjson, "client_secret leaked into generated .tf.json"

      # State lands under /var/lib/keycloak (via systemd `StateDirectory=`
      # under DynamicUser), is readable across runs (the `cat` above
      # succeeded), and the reconciler exited 0 -- proving it ran as a
      # working non-root UID that owns the state dir. We don't assert a
      # specific owner name: DynamicUser allocates an opaque per-unit UID
      # the host kernel may render as the overflow uid (65534) when
      # stat'd outside the unit's mount namespace.
      machine.succeed(
        "test -s /var/lib/keycloak/declarative-terraform/terraform.tfstate"
      )

      # Re-applying must be idempotent (a second run must also succeed).
      machine.succeed("systemctl restart declarative-keycloak.service")

      # Config-change reconciliation: switching to the specialisation that
      # declares a second realm must apply it without manual intervention.
      machine.succeed(
        "/run/current-system/specialisation/addRealm/bin/switch-to-configuration test"
      )
      machine.wait_until_succeeds("curl --fail http://localhost:8080/realms/delta")
      delta = get_realm("delta")
      assert delta.get("displayName") == "Delta Realm", \
          f"delta realm display_name not applied: {delta}"
    '';
  };
}
