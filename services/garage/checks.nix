# Garage pairing check, returned as a single-entry attrset merged into the
# flake's per-system `checks`.
#
#   garage - Full integration test: boots a VM with services.garage +
#     services.garage.runtime and lets the pairing converge at boot. A
#     companion oneshot gives the single-node cluster a layout, which Garage
#     needs before it reports healthy or stores a bucket; then the run-once
#     reconciler applies the config. The permissions reference a bucket and a
#     key by their numeric ids, so a successful apply proves reference
#     resolution and apply ordering. An imported key with a
#     `secret_access_keyFile` also proves per-secret credential indirection -
#     the value is loaded from a host file and kept out of the generated
#     `.tf.json`. Requires KVM (a NixOS VM test).
{ pkgs, self }:
let
  fixtures = import ./fixtures.nix;
  adminToken = "hackme";
  # A Garage secret access key is 32 bytes, hex-encoded.
  importedSecret = "4f2b6c1d8e9a0b3c5d7e9f1a2b4c6d8e0f1a3b5c7d9e1f2a4b6c8d0e2f4a6b8c";
in
{
  garage = pkgs.testers.runNixOSTest {
    name = "declarative-garage";

    nodes.machine =
      { config, pkgs, ... }:
      {
        imports = [ self.nixosModules.default ];

        # curl and jq drive the post-convergence API assertions.
        environment.systemPackages = [
          pkgs.curl
          pkgs.jq
        ];

        # mock agenix secrets: the admin token Garage reads, and an imported
        # key's secret fed to the reconciler via LoadCredential.
        environment.etc."garage-admin-token".text = adminToken;
        environment.etc."garage-imported-secret".text = importedSecret;

        services.garage = {
          enable = true;
          # The provider speaks the v2 admin API.
          package = pkgs.garage_2;
          settings = {
            replication_factor = 1;
            rpc_bind_addr = "[::]:3901";
            rpc_secret = "5c1915fa04d0b6739675c61bf5907eb0fe3d9c69850c83820f51b4d25d13868c";
            # Garage runs as a dynamic user, which cannot own a file that
            # `environment.etc` makes.
            allow_world_readable_secrets = true;
            s3_api = {
              s3_region = "garage";
              api_bind_addr = "[::]:3900";
            };
            admin = {
              api_bind_addr = "[::]:3903";
              admin_token_file = "/etc/garage-admin-token";
            };
          };

          # No baseUrl or tokenFile: both default to Garage's own admin
          # settings.
          runtime = {
            enable = true;
          }
          // fixtures.main;
        };

        # A new cluster has no layout. An operator gives it one once, when the
        # cluster is set up; here a oneshot does it before the reconciler runs.
        systemd.services.garage-layout = {
          after = [ "garage.service" ];
          requires = [ "garage.service" ];
          before = [ "declarative-garage.service" ];
          requiredBy = [ "declarative-garage.service" ];
          path = [ config.services.garage.package ];
          serviceConfig = {
            Type = "oneshot";
            RemainAfterExit = true;
          };
          script = ''
            until node=$(garage node id 2>/dev/null); do sleep 1; done
            garage layout assign -z dc1 -c 1G "''${node%%@*}"
            garage layout apply --version 1
          '';
        };

        virtualisation = {
          memorySize = 2048;
          diskSize = 4096;
        };
      };

    testScript = ''
      import json

      def admin(call):
          return json.loads(machine.succeed(
              f"curl --fail -H 'Authorization: Bearer ${adminToken}' 'http://localhost:3903/v2/{call}'"
          ))

      machine.start()

      # The whole chain must converge at boot:
      #   garage.service -> garage-layout.service -> declarative-garage.service
      # wait_for_unit blocks until the run-once reconciler has applied every
      # declared resource successfully (a failed apply fails the unit).
      machine.wait_for_unit("declarative-garage.service")

      photos = admin("GetBucketInfo?globalAlias=photos")
      assert photos["websiteAccess"], f"website access not applied: {photos}"
      website = photos["websiteConfig"]
      assert (website["indexDocument"], website["errorDocument"]) == ("index.html", "error.html"), \
          f"website config not applied: {website}"
      assert photos["quotas"] == {
          "maxSize": 1073741824,
          "maxObjects": 1000,
      }, f"quotas not applied: {photos.get('quotas')}"

      app = admin("GetKeyInfo?search=app")
      grants = {k["accessKeyId"]: k["permissions"] for k in photos["keys"]}
      assert grants == {
          app["accessKeyId"]: {"read": True, "write": True, "owner": True},
          "GK0123456789abcdef01234567": {"read": True, "write": False, "owner": False},
      }, f"photos grants not applied: {grants}"

      backups = admin("GetBucketInfo?globalAlias=backups")
      grants = {k["accessKeyId"]: k["permissions"] for k in backups["keys"]}
      assert grants == {
          "GK0123456789abcdef01234567": {"read": False, "write": True, "owner": False},
      }, f"backups grants not applied: {grants}"

      # Per-secret indirection: the imported key's secret was supplied as a
      # host file and must not appear in the generated config; Garage holding
      # it proves the value still reached Garage intact.
      imported = admin("GetKeyInfo?id=GK0123456789abcdef01234567&showSecretKey=true")
      assert imported["name"] == "imported", f"imported key not named: {imported}"
      assert imported["secretAccessKey"] == "${importedSecret}", "imported secret not applied"
      tfjson = machine.succeed("cat /var/lib/declarative-garage/declarative-terraform/main.tf.json")
      assert "${importedSecret}" not in tfjson, "secret value leaked into generated .tf.json"
      assert "${adminToken}" not in tfjson, "admin token leaked into generated .tf.json"

      # The state is in the reconciler's own state directory, and only its
      # dynamic user can read it. On the host, the files show as the dynamic
      # user, or as `nobody` when systemd maps the directory into the unit
      # with an ID-mapped mount.
      tfstate = "/var/lib/declarative-garage/declarative-terraform/terraform.tfstate"
      uid = machine.succeed("systemctl show -P UID declarative-garage.service").strip()
      owner, mode = machine.succeed(f"stat -c '%u %a' {tfstate}").split()
      assert owner in (uid, "65534"), f"tfstate not owned by the reconciler: uid {owner}, reconciler uid {uid}"
      assert mode == "600", f"tfstate readable by others: mode {mode}"

      # Re-applying must be idempotent: a second run must succeed *and*
      # report 0/0/0 (the last 'Apply complete!' line in the journal).
      machine.succeed("systemctl restart declarative-garage.service")
      apply_lines = machine.succeed(
          "journalctl -u declarative-garage.service --no-pager --output=cat "
          "| grep 'Apply complete'"
      ).strip().splitlines()
      assert apply_lines, "no 'Apply complete!' line in journal"
      assert "0 added, 0 changed, 0 destroyed" in apply_lines[-1], \
          f"reapply was not a no-op: {apply_lines[-1]}"
    '';
  };
}
