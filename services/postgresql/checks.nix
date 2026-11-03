# PostgreSQL pairing check, returned as a single-entry attrset merged into the
# flake's per-system `checks`.
#
#   postgresql - Full integration test: boots a VM with services.postgresql +
#     services.postgresql.runtime and lets the run-once reconciler apply the
#     config at boot. The fixtures use every resource type of the provider, and
#     most of them reference roles, databases, schemas and other entries by
#     their keys, so a successful apply proves reference resolution and apply
#     ordering. Role passwords, a subscription's `conninfo` and a user mapping
#     password come from host files, which proves per-secret credential
#     indirection - the values are kept out of the generated `.tf.json`.
#     Requires KVM (a NixOS VM test).
{ pkgs, self }:
let
  fixtures = import ./fixtures.nix;
  appPassword = "app-hackme";
  replicatorPassword = "replicator-hackme";
in
{
  postgresql = pkgs.testers.runNixOSTest {
    name = "declarative-postgresql";

    nodes.machine = {
      imports = [ self.nixosModules.default ];

      # mock agenix secrets, fed to the reconciler via LoadCredential.
      environment.etc."postgresql-app-password".text = appPassword;
      environment.etc."postgresql-replicator-password".text = replicatorPassword;
      environment.etc."postgresql-conninfo".text =
        "host=127.0.0.1 dbname=app user=replicator password=${replicatorPassword}";

      services.postgresql = {
        enable = true;
        # Publications and logical replication slots need logical decoding.
        settings.wal_level = "logical";

        runtime = {
          enable = true;
        }
        // fixtures.main;
      };

      virtualisation.memorySize = 2048;
    };

    testScript = ''
      def sql(query, db="postgres"):
          return machine.succeed(
              f"runuser -u postgres -- psql -d {db} -XtAc \"{query}\""
          ).strip()

      def login(user, password, db):
          return machine.succeed(
              f"PGPASSWORD='{password}' psql -h 127.0.0.1 -U {user} -d {db} -XtAc 'SELECT current_user'"
          ).strip()

      machine.start()

      # The whole chain must converge at boot:
      #   postgresql.target -> declarative-postgresql-password.service
      #     -> declarative-postgresql.service
      # wait_for_unit blocks until the run-once reconciler has applied every
      # declared resource successfully (a failed apply fails the unit).
      machine.wait_for_unit("declarative-postgresql.service")

      roles = sql(
          "SELECT rolname, rolcanlogin, rolsuper, rolreplication, rolconnlimit FROM pg_roles "
          "WHERE rolname IN ('app', 'owner', 'readers', 'replicator') ORDER BY 1"
      ).splitlines()
      assert roles == [
          "app|t|f|f|10",
          "owner|f|f|f|-1",
          "readers|f|f|f|-1",
          "replicator|t|t|t|-1",
      ], f"roles not applied: {roles}"
      search_path = sql("SELECT rolconfig FROM pg_roles WHERE rolname = 'app'")
      assert "search_path=app" in search_path and "public" in search_path, f"search_path not applied: {search_path}"
      members = sql("SELECT pg_has_role('app', 'readers', 'member'), pg_has_role('postgres', 'readers', 'member')")
      assert members == "t|t", f"role memberships not applied: {members}"

      owner = sql("SELECT pg_get_userbyid(datdba) FROM pg_database WHERE datname = 'app'")
      assert owner == "owner", f"database owner not applied: {owner}"
      owner = sql("SELECT pg_get_userbyid(nspowner) FROM pg_namespace WHERE nspname = 'app'", "app")
      assert owner == "owner", f"schema owner not applied: {owner}"
      assert sql("SELECT app.answer()", "app") == "42", "function not applied"

      # A table that the owner makes later gets the default privileges.
      sql("SET ROLE owner; CREATE TABLE app.t (x integer)", "app")
      privileges = sql(
          "SELECT has_schema_privilege('readers', 'app', 'USAGE'), "
          "has_table_privilege('readers', 'app.t', 'SELECT'), "
          "has_table_privilege('readers', 'app.t', 'INSERT')",
          "app",
      )
      assert privileges == "t|t|f", f"privileges not applied: {privileges}"

      assert sql("SELECT extname FROM pg_extension WHERE extname = 'postgres_fdw'") == "postgres_fdw", \
          "extension not applied"
      # The provider sets the options in a random order, so sort them.
      server = sql(
          "SELECT srvname, array_to_string(ARRAY(SELECT unnest(srvoptions) ORDER BY 1), ',') "
          "FROM pg_foreign_server"
      )
      assert server == "loopback|dbname=app,host=127.0.0.1", f"foreign server not applied: {server}"
      mapping = sql("SELECT umoptions FROM pg_user_mappings WHERE srvname = 'loopback' AND usename = 'app'")
      assert "user=replicator" in mapping and "password=${replicatorPassword}" in mapping, \
          f"user mapping not applied: {mapping}"

      assert sql("SELECT puballtables FROM pg_publication WHERE pubname = 'app'", "app") == "t", \
          "publication not applied"
      slots = sql("SELECT slot_name, slot_type, database FROM pg_replication_slots ORDER BY 1").splitlines()
      assert slots == ["app|logical|app", "standby|physical|"], f"replication slots not applied: {slots}"
      subscription = sql(
          "SELECT s.subenabled, s.subslotname, array_to_string(s.subpublications, ',') "
          "FROM pg_subscription s JOIN pg_database d ON d.oid = s.subdbid "
          "WHERE s.subname = 'app' AND d.datname = 'sub'"
      )
      assert subscription == "t|app|app", f"subscription not applied: {subscription}"

      # Per-secret indirection: the role passwords were supplied as host
      # files and must not appear in the generated config; logging in with
      # them proves the values still reached PostgreSQL intact.
      assert login("app", "${appPassword}", "app") == "app"
      assert login("replicator", "${replicatorPassword}", "postgres") == "replicator"
      tfjson = machine.succeed("cat /var/lib/declarative-postgresql/declarative-terraform/main.tf.json")
      admin_password = machine.succeed("cat /var/lib/declarative-postgresql/admin-password").strip()
      for secret in ["${appPassword}", "${replicatorPassword}", admin_password]:
          assert secret not in tfjson, "secret value leaked into generated .tf.json"

      # The state is in the reconciler's own state directory, and the
      # `postgres` user that the reconciler runs as owns it.
      owner = machine.succeed("stat -c %U /var/lib/declarative-postgresql/declarative-terraform/terraform.tfstate").strip()
      assert owner == "postgres", f"tfstate not owned by the reconciler: {owner}"

      # Re-applying must be idempotent: a second run must succeed *and*
      # report 0/0/0 (the last 'Apply complete!' line in the journal).
      machine.succeed("systemctl restart declarative-postgresql.service")
      apply_lines = machine.succeed(
          "journalctl -u declarative-postgresql.service --no-pager --output=cat "
          "| grep 'Apply complete'"
      ).strip().splitlines()
      assert apply_lines, "no 'Apply complete!' line in journal"
      assert "0 added, 0 changed, 0 destroyed" in apply_lines[-1], \
          f"reapply was not a no-op: {apply_lines[-1]}"
    '';
  };
}
