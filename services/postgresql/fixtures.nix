# `services.postgresql.runtime` fixtures, shared by the VM test in ./checks.nix
# and by the `postgresql-rendered-fixtures` package.
#
# why the indirection: `postgresql-rendered-fixtures` renders these through the
# real option system and renderer, so the `.tf.json` snapshot that guards
# refactors of the resource surface is produced from exactly the configuration
# the VM test proves converges against a live PostgreSQL.
{
  # Everything the VM test declares at boot. Spans every resource but
  # `security_labels` (which needs a label provider), references by key and by
  # literal name, and per-secret `<attr>File` indirection: a resource
  # attribute (`password`), a required one (`conninfo`), and a map value
  # (`options.password`).
  main = {
    roles = {
      owner = { };
      readers = { };
      app = {
        login = true;
        passwordFile = "/etc/postgresql-app-password";
        # by key -> ordered after the managed role.
        roles = [ "readers" ];
        search_path = [
          "app"
          "public"
        ];
        connection_limit = 10;
      };
      # A login role for the subscription and the foreign server, both of
      # which connect back to this same server.
      replicator = {
        login = true;
        replication = true;
        superuser = true;
        password_woFile = "/etc/postgresql-replicator-password";
        password_wo_version = "1";
      };
    };

    databases = {
      app.owner = "owner";
      sub = { };
    };

    schemas.app = {
      database = "app";
      owner = "owner";
    };

    # In the provider's database, where the foreign server is.
    extensions.postgres_fdw = { };

    functions.answer = {
      database = "app";
      schema = "app";
      returns = "integer";
      language = "sql";
      body = "SELECT 42";
    };

    grants.readers_schema = {
      database = "app";
      role = "readers";
      schema = "app";
      object_type = "schema";
      privileges = [ "USAGE" ];
    };
    grants.readers_tables = {
      database = "app";
      role = "readers";
      schema = "app";
      object_type = "table";
      privileges = [ "SELECT" ];
    };

    # The member is a literal, unmanaged role: see the `grant_roles`
    # description.
    grant_roles.postgres_readers = {
      role = "postgres";
      grant_role = "readers";
    };

    default_privileges.readers_tables = {
      database = "app";
      owner = "owner";
      role = "readers";
      schema = "app";
      object_type = "table";
      privileges = [ "SELECT" ];
    };

    publications.app = {
      database = "app";
      all_tables = true;
    };

    replication_slots.app = {
      database = "app";
      plugin = "pgoutput";
    };

    physical_replication_slots.standby = { };

    # The subscription uses the slot above, as a subscription in the same
    # cluster as its publication cannot make its own slot.
    subscriptions.app = {
      database = "sub";
      publications = [ "app" ];
      create_slot = false;
      slot_name = "app";
      conninfoFile = "/etc/postgresql-conninfo";
    };

    # by key -> ordered after the extension that makes the wrapper.
    servers.loopback = {
      fdw_name = "postgres_fdw";
      options = {
        host = "127.0.0.1";
        dbname = "app";
      };
    };

    user_mappings.app_loopback = {
      server_name = "loopback";
      user_name = "app";
      options = {
        user = "replicator";
        passwordFile = "/etc/postgresql-replicator-password";
      };
    };
  };
}
