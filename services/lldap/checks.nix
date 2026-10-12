# lldap pairing check, returned as a single-entry attrset merged into the
# flake's per-system `checks`.
#
#   lldap - Full integration test: boots a VM with services.lldap +
#     services.lldap.runtime and lets the run-once reconciler apply the config
#     at boot. Memberships and attribute values reference users, groups and
#     attributes by their keys, so a successful apply proves reference
#     resolution and apply ordering. A user with a `passwordFile` also proves
#     per-secret credential indirection - the value is loaded from a host file
#     and kept out of the generated `.tf.json`. Requires KVM (a NixOS VM test).
{ pkgs, self }:
let
  fixtures = import ./fixtures.nix;
  # lldap refuses an admin password shorter than 8 characters.
  adminPassword = "hackmehackme";
  alicePassword = "alice-hackme";
in
{
  lldap = pkgs.testers.runNixOSTest {
    name = "declarative-lldap";

    nodes.machine =
      { pkgs, ... }:
      {
        imports = [ self.nixosModules.default ];

        # curl and jq drive the post-convergence API assertions.
        environment.systemPackages = [
          pkgs.curl
          pkgs.jq
        ];

        # mock agenix secrets: the admin password lldap reads, and a user's
        # password fed to the reconciler via LoadCredential.
        environment.etc."lldap-admin-password".text = adminPassword;
        environment.etc."lldap-alice-password".text = alicePassword;

        services.lldap = {
          enable = true;
          settings = {
            ldap_base_dn = "dc=example,dc=com";
            ldap_user_pass_file = "/etc/lldap-admin-password";
            # Keep the admin password in step with the file, which the
            # reconciler logs in with.
            force_ldap_user_pass_reset = "always";
          };

          # No connection settings or tokenFile: all default to lldap's own
          # settings.
          runtime = {
            enable = true;
          }
          // fixtures.main;
        };

        virtualisation.memorySize = 2048;
      };

    testScript = ''
      import json

      def login(user, password):
          body = json.dumps({"username": user, "password": password})
          return json.loads(machine.succeed(
              f"curl --fail -H 'Content-Type: application/json' -d '{body}' "
              "http://localhost:17170/auth/simple/login"
          ))["token"]

      def graphql(token, query):
          body = json.dumps({"query": query})
          response = json.loads(machine.succeed(
              f"curl --fail -H 'Authorization: Bearer {token}' "
              f"-H 'Content-Type: application/json' -d '{body}' "
              "http://localhost:17170/api/graphql"
          ))
          assert "errors" not in response, f"GraphQL errors: {response}"
          return response["data"]

      def attributes(entity):
          return {a["name"]: a["value"] for a in entity["attributes"]}

      machine.start()

      # The whole chain must converge at boot:
      #   lldap.service -> declarative-lldap.service
      # wait_for_unit blocks until the run-once reconciler has applied every
      # declared resource successfully (a failed apply fails the unit).
      machine.wait_for_unit("declarative-lldap.service")

      token = login("admin", "${adminPassword}")

      schema = graphql(token, """{ schema {
        userSchema { attributes { name attributeType isList isVisible isEditable } }
        groupSchema { attributes { name attributeType isList } }
      } }""")["schema"]
      department = next(a for a in schema["userSchema"]["attributes"] if a["name"] == "department")
      assert department == {
          "name": "department",
          "attributeType": "STRING",
          "isList": False,
          "isVisible": True,
          "isEditable": False,
      }, f"user attribute not applied: {department}"
      cost_centers = next(a for a in schema["groupSchema"]["attributes"] if a["name"] == "cost-centers")
      assert cost_centers == {
          "name": "cost-centers",
          "attributeType": "INTEGER",
          "isList": True,
      }, f"group attribute not applied: {cost_centers}"

      alice = graphql(token, """{ user(userId: "alice") {
        email displayName firstName lastName attributes { name value }
      } }""")["user"]
      assert alice["email"] == "alice@example.com", f"email not applied: {alice}"
      assert alice["displayName"] == "Alice Liddell", f"display name not applied: {alice}"
      assert (alice["firstName"], alice["lastName"]) == ("Alice", "Liddell"), f"names not applied: {alice}"
      assert attributes(alice).get("department") == ["engineering"], f"user attribute value not applied: {alice}"

      # Each membership resource manages its own memberships; together they
      # make up the members of the three managed groups.
      groups = graphql(token, "{ groups { displayName users { id } attributes { name value } } }")["groups"]
      members = {g["displayName"]: sorted(u["id"] for u in g["users"]) for g in groups}
      for group, expected in {
          "developers": ["alice"],
          "ops": ["alice", "bob"],
          "readers": ["carol"],
      }.items():
          assert members.get(group) == expected, f"{group} members not applied: {members.get(group)}"
      ops = next(g for g in groups if g["displayName"] == "ops")
      assert sorted(attributes(ops).get("cost-centers", [])) == ["1200", "1300"], f"group attribute value not applied: {ops}"

      # Per-secret indirection: alice's password was supplied as a host file
      # and must not appear in the generated config; logging in with it
      # proves the value still reached lldap intact.
      login("alice", "${alicePassword}")
      tfjson = machine.succeed("cat /var/lib/declarative-lldap/declarative-terraform/main.tf.json")
      assert "${alicePassword}" not in tfjson, "user password leaked into generated .tf.json"
      assert "${adminPassword}" not in tfjson, "admin password leaked into generated .tf.json"

      # The state is in the reconciler's own state directory, and only its
      # dynamic user can read it. On the host, the files show as the dynamic
      # user, or as `nobody` when systemd maps the directory into the unit
      # with an ID-mapped mount.
      tfstate = "/var/lib/declarative-lldap/declarative-terraform/terraform.tfstate"
      uid = machine.succeed("systemctl show -P UID declarative-lldap.service").strip()
      owner, mode = machine.succeed(f"stat -c '%u %a' {tfstate}").split()
      assert owner in (uid, "65534"), f"tfstate not owned by the reconciler: uid {owner}, reconciler uid {uid}"
      assert mode == "600", f"tfstate readable by others: mode {mode}"

      # Re-applying must be idempotent: a second run must succeed *and*
      # report 0/0/0 (the last 'Apply complete!' line in the journal).
      machine.succeed("systemctl restart declarative-lldap.service")
      apply_lines = machine.succeed(
          "journalctl -u declarative-lldap.service --no-pager --output=cat "
          "| grep 'Apply complete'"
      ).strip().splitlines()
      assert apply_lines, "no 'Apply complete!' line in journal"
      assert "0 added, 0 changed, 0 destroyed" in apply_lines[-1], \
          f"reapply was not a no-op: {apply_lines[-1]}"
    '';
  };
}
