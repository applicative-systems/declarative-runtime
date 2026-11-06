# Garage pairing check, returned as a single-entry attrset merged into the
# flake's per-system `checks`.
#
#   garage - Full integration test: boots a VM with services.garage +
#     services.garage.runtime and lets the pairing converge at boot, with no
#     manual setup. The config sets no admin token, so the module bootstraps
#     the cluster itself: `declarative-garage-layout` gives the single node
#     its role, `declarative-garage-token` mints a scoped admin token, and
#     then the run-once reconciler applies the config. The permissions
#     reference a bucket and a key by their numeric ids, so a successful apply
#     proves reference resolution and apply ordering. An imported key with a
#     `secret_access_keyFile` also proves per-secret credential indirection -
#     the value is loaded from a host file and kept out of the generated
#     `.tf.json`. The `operator-token` specialisation changes the capacity of
#     the node and gives Garage an admin token of its own, which the
#     reconciler then uses in place of a minted one. Requires KVM (a NixOS VM
#     test).
{ pkgs, self }:
let
  fixtures = import ./fixtures.nix;
  adminToken = "hackme";
  # A Garage secret access key is 32 bytes, hex-encoded.
  importedSecret = "4f2b6c1d8e9a0b3c5d7e9f1a2b4c6d8e0f1a3b5c7d9e1f2a4b6c8d0e2f4a6b8c";
  # The admin API functions the provider calls, stated here again so that a
  # change to the scope the module mints is a test failure.
  adminScope = [
    "AddBucketAlias"
    "AllowBucketKey"
    "CreateBucket"
    "CreateKey"
    "DeleteBucket"
    "DeleteKey"
    "DenyBucketKey"
    "GetBucketInfo"
    "GetKeyInfo"
    "ImportKey"
    "RemoveBucketAlias"
    "UpdateBucket"
    "UpdateKey"
  ];
in
{
  garage = pkgs.testers.runNixOSTest {
    name = "declarative-garage";

    nodes.machine =
      { lib, pkgs, ... }:
      {
        imports = [ self.nixosModules.default ];

        # curl and jq drive the post-convergence API assertions.
        environment.systemPackages = [
          pkgs.curl
          pkgs.jq
        ];

        # mock agenix secrets: the admin token of the `operator-token`
        # specialisation, and an imported key's secret fed to the reconciler
        # via LoadCredential.
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
            # No admin token: the module mints one.
            admin.api_bind_addr = "[::]:3903";
          };

          # No baseUrl: it defaults to Garage's own admin API.
          runtime = {
            enable = true;
            layout = {
              zone = "dc1";
              capacity = 1000 * 1000 * 1000;
            };
          }
          // fixtures.main;
        };

        # The operator gives Garage an admin token, so the reconciler uses it
        # and the module mints no token. The node also gets a new capacity.
        specialisation.operator-token.configuration = {
          services.garage.settings.admin.admin_token_file = "/etc/garage-admin-token";
          services.garage.runtime.layout.capacity = lib.mkForce (2 * 1000 * 1000 * 1000);
        };

        virtualisation = {
          memorySize = 2048;
          diskSize = 4096;
        };
      };

    testScript = ''
      import json

      # `garage json-api` calls the admin API through RPC as root, so the
      # assertions need no admin token.
      def admin(endpoint, request=None):
          return json.loads(machine.succeed(
              f"garage json-api {endpoint} '{json.dumps(request)}'"
          ))

      def minted_tokens():
          return [t for t in admin("ListAdminTokens") if t["name"] == "declarative-garage-token"]

      # The last 'Apply complete!' line in the journal of the reconciler.
      def last_apply():
          lines = machine.succeed(
              "journalctl -u declarative-garage.service --no-pager --output=cat "
              "| grep 'Apply complete'"
          ).strip().splitlines()
          assert lines, "no 'Apply complete!' line in journal"
          return lines[-1]

      def assert_noop(what):
          line = last_apply()
          assert "0 added, 0 changed, 0 destroyed" in line, f"{what} was not a no-op: {line}"

      tfjson_path = "/var/lib/declarative-garage/declarative-terraform/main.tf.json"
      bearer = "-H 'Authorization: Bearer ${adminToken}' http://localhost:3903/v2/ListBuckets"

      machine.start()

      # The whole chain must converge at boot:
      #   garage.service -> declarative-garage-layout.service
      #     -> declarative-garage-token.service -> declarative-garage.service
      # wait_for_unit blocks until the run-once reconciler has applied every
      # declared resource successfully (a failed apply fails the unit).
      machine.wait_for_unit("declarative-garage.service")

      # Layout bootstrap: this node has its role, in the first layout version.
      layout = admin("GetClusterLayout")
      roles = [(r["zone"], r["capacity"], r["tags"]) for r in layout["roles"]]
      assert (layout["version"], roles) == (1, [("dc1", 1000000000, [])]), \
          f"layout role not applied: {layout}"

      # Token bootstrap: one token, scoped to the functions the provider
      # calls; Garage itself has no admin token.
      minted = minted_tokens()
      assert len(minted) == 1, f"not exactly one minted token: {minted}"
      assert sorted(minted[0]["scope"]) == ${builtins.toJSON adminScope}, \
          f"minted token scope: {minted[0]['scope']}"
      machine.fail(f"curl --fail {bearer}")

      photos = admin("GetBucketInfo", {"globalAlias": "photos"})
      assert photos["websiteAccess"], f"website access not applied: {photos}"
      website = photos["websiteConfig"]
      assert (website["indexDocument"], website["errorDocument"]) == ("index.html", "error.html"), \
          f"website config not applied: {website}"
      assert photos["quotas"] == {
          "maxSize": 1073741824,
          "maxObjects": 1000,
      }, f"quotas not applied: {photos.get('quotas')}"

      app = admin("GetKeyInfo", {"search": "app"})
      grants = {k["accessKeyId"]: k["permissions"] for k in photos["keys"]}
      assert grants == {
          app["accessKeyId"]: {"read": True, "write": True, "owner": True},
          "GK0123456789abcdef01234567": {"read": True, "write": False, "owner": False},
      }, f"photos grants not applied: {grants}"

      backups = admin("GetBucketInfo", {"globalAlias": "backups"})
      grants = {k["accessKeyId"]: k["permissions"] for k in backups["keys"]}
      assert grants == {
          "GK0123456789abcdef01234567": {"read": False, "write": True, "owner": False},
      }, f"backups grants not applied: {grants}"

      # Per-secret indirection: the imported key's secret was supplied as a
      # host file and must not appear in the generated config; Garage holding
      # it proves the value still reached Garage intact. The minted admin
      # token must not appear either.
      imported = admin("GetKeyInfo", {"id": "GK0123456789abcdef01234567", "showSecretKey": True})
      assert imported["name"] == "imported", f"imported key not named: {imported}"
      assert imported["secretAccessKey"] == "${importedSecret}", "imported secret not applied"
      tfjson = machine.succeed(f"cat {tfjson_path}")
      assert "${importedSecret}" not in tfjson, "secret value leaked into generated .tf.json"
      token = machine.succeed("cat /run/declarative-garage-token/token").strip()
      assert token and token not in tfjson, "admin token leaked into generated .tf.json"

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
      # report 0/0/0.
      machine.succeed("systemctl restart declarative-garage.service")
      assert_noop("reapply")

      # A node that has its role keeps the layout as it is.
      machine.succeed("systemctl restart declarative-garage-layout.service")
      assert admin("GetClusterLayout")["version"] == 1, "layout changed with no new role"

      # A new token replaces the token minted before, and the reconciler
      # applies with it.
      machine.succeed("systemctl restart declarative-garage-token.service")
      rotated = minted_tokens()
      assert len(rotated) == 1 and rotated[0]["id"] != minted[0]["id"], \
          f"token not replaced: {minted} -> {rotated}"
      machine.succeed("systemctl restart declarative-garage.service")
      assert_noop("apply with the new token")

      # The operator's token: the module mints no token, the layout has the
      # new capacity, and the reconciler applies with Garage's own token.
      machine.succeed("/run/current-system/specialisation/operator-token/bin/switch-to-configuration test")
      machine.wait_for_unit("declarative-garage.service")
      machine.fail("systemctl is-active declarative-garage-token.service")
      layout = admin("GetClusterLayout")
      roles = [(r["zone"], r["capacity"]) for r in layout["roles"]]
      assert (layout["version"], roles) == (2, [("dc1", 2000000000)]), \
          f"new capacity not applied: {layout}"
      machine.succeed(f"curl --fail {bearer}")
      machine.succeed("systemctl restart declarative-garage.service")
      assert_noop("apply with the operator token")
      assert "${adminToken}" not in machine.succeed(f"cat {tfjson_path}"), \
          "admin token leaked into generated .tf.json"
    '';
  };
}
