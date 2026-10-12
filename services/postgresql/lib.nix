# cyrilgdn/postgresql provider specifics: executor, resource surface, provider
# block.
#
# The resource surface is *derived* from the vendored provider schema
# (./provider-schema.json, parsed by ./schema.nix) via
# ../../modules/lib/tf-schema.nix. What stays hand-written is only what a schema
# cannot state: the reference graph between collections and the odd description
# that adds a fact. A provider bump that adds, removes or retypes anything is
# then an eval-time error rather than an apply-time surprise.
#
# Shared helpers (option helpers, renderer, reconciler) live in modules/lib.
{ pkgs, nix-tf-schema }:
let
  genlib = import ../../modules/lib { inherit pkgs; };
  tfSchema = import ../../modules/lib/tf-schema.nix { inherit pkgs nix-tf-schema; };

  provider = pkgs.terraform-providers.cyrilgdn_postgresql;
  providerVersion = provider.version;
  # provider source address; also keys the vendored provider schema.
  providerSource = "cyrilgdn/postgresql";
  runtimePrefix = "services.postgresql.runtime";
  # the password of the role that the provider logs in as.
  tokenVar = "postgresql_password";
  # the role that the provider logs in as. The module makes it.
  adminUser = "declarative_postgresql";
  executor = pkgs.opentofu.withPlugins (_: [ provider ]);

  # A reference to a role, a database, a schema or a foreign server takes the
  # key of a managed entry or a literal name, so objects that PostgreSQL makes
  # itself (the `postgres` database, the `public` schema, the `public`
  # pseudo-role) stay reachable.
  ref =
    type: field: attrs:
    {
      targets = [ { inherit type field; } ];
      managedOnly = false;
    }
    // attrs;
  roleRef = ref "role" "name";
  databaseRef = ref "database" "name";
  schemaRef = ref "schema" "name";
  serverRef = ref "server" "server_name";

  optionalDatabase = databaseRef {
    description = "Database. Null is the database that the provider connects to (`postgres`).";
  };
  optionalOwner = roleRef {
    description = "Owner. Null is the role that the provider connects as.";
  };
  # `public` is a pseudo-role for all roles.
  grantee = roleRef {
    description = "Role that gets the privileges (`public` for all roles).";
  };

  # The cyrilgdn/postgresql resource surface. Each key names a provider
  # resource without its `postgresql_` prefix and becomes the collection
  # `services.postgresql.runtime.<plural>` (`role` -> `roles`). Per resource,
  # only the facts the schema does not carry (see modules/lib/tf-schema.nix for
  # the full overlay vocabulary):
  #   nameAttr     attribute the collection key fills in, where it is not `name`
  #   refs         parent links resolved to references against managed siblings
  #   description  replaces the generated description, only to add a fact
  generated = tfSchema.mkResourceTypes {
    schema = import ./schema.nix;
    inherit provider runtimePrefix;
    source = providerSource;
    # the sdk/v2 synthetic `id` is computed.
    omitEverywhere = [ "id" ];
    resources = {
      role = {
        refs = {
          roles = roleRef {
            description = "Roles that this role is a member of. The list is complete: memberships not in it are revoked.";
          };
          assume_role = roleRef { };
        };
        description = "PostgreSQL roles (users and groups).";
      };
      database.refs.owner = optionalOwner;
      schema.refs = {
        database = optionalDatabase;
        owner = optionalOwner;
      };
      extension = {
        refs = {
          database = optionalDatabase;
          schema = schemaRef { };
        };
        description = "PostgreSQL extensions. The PostgreSQL package must contain the extension (`services.postgresql.extensions`).";
      };
      function.refs = {
        database = databaseRef { };
        schema = schemaRef { };
      };
      grant = {
        refs = {
          database = databaseRef { };
          role = grantee;
          schema = schemaRef { };
        };
        description = "Privileges of a role on a database, a schema or objects. The list of privileges is complete: privileges of that role on that object type that are not in it are revoked.";
      };
      grant_role = {
        refs = {
          role = roleRef {
            description = "Role that gets the membership.";
          };
          grant_role = roleRef { };
        };
        description = "Role memberships. Each adds one membership and keeps all others. For a member role in `roles`, use `roles.<name>.roles` instead: that list is complete, so each apply revokes a membership from here and the next apply grants it again.";
      };
      default_privileges = {
        refs = {
          database = databaseRef { };
          owner = roleRef {
            description = "Role whose new objects get the privileges.";
          };
          role = grantee;
          schema = schemaRef { };
        };
        description = "Default privileges on objects that a role makes in the future.";
      };
      publication = {
        refs = {
          database = optionalDatabase;
          owner = optionalOwner;
        };
        description = "Logical replication publications. Requires `services.postgresql.settings.wal_level = \"logical\"`.";
      };
      subscription = {
        refs = {
          database = optionalDatabase;
          publications = ref "publication" "name" {
            description = "Publications to subscribe to. When the publisher is not this server, use literal names of publications on the server in `conninfo`.";
          };
          slot_name = ref "replication_slot" "name" {
            description = "Replication slot on the publisher. When the publisher is not this server, use a literal slot name. Null lets the subscription make a slot named after it.";
          };
        };
        description = "Logical replication subscriptions. When the publisher is this server, set `create_slot = false` and name a managed replication slot, as `CREATE SUBSCRIPTION` cannot make a slot on its own server.";
      };
      replication_slot = {
        refs.database = optionalDatabase;
        description = "Logical replication slots. Requires `services.postgresql.settings.wal_level = \"logical\"`.";
      };
      physical_replication_slot = { };
      server = {
        nameAttr = "server_name";
        refs = {
          fdw_name = ref "extension" "name" {
            description = "Foreign-data wrapper. A managed extension must make a wrapper of the same name (such as `postgres_fdw`).";
          };
          server_owner = roleRef {
            description = "Owner of the server. Null is the role that the provider connects as.";
          };
        };
        description = "Foreign servers. A server is in the database that the provider connects to (`postgres`), so the extension that makes its wrapper must be there too.";
      };
      user_mapping = {
        refs = {
          server_name = serverRef { };
          user_name = roleRef { };
        };
        description = "User mappings for foreign servers. An option value can come from a file: `options.passwordFile` in place of `options.password`.";
      };
      security_label.description = "Security labels. The label provider must be loaded, for example through `services.postgresql.settings.shared_preload_libraries`.";
    };
  };
  inherit (generated) resourceTypes;

  postgresqlTfConfig = genlib.mkTfConfig {
    inherit
      resourceTypes
      providerVersion
      providerSource
      runtimePrefix
      tokenVar
      ;
    providerName = "postgresql";
    providerBlock = cfg: {
      # TCP and not the socket: the provider puts the host into a connection
      # URL, which cannot hold a socket path.
      host = "127.0.0.1";
      inherit (cfg) port;
      database = "postgres";
      username = adminUser;
      password = "\${var.${tokenVar}}";
      sslmode = "disable";
      # The role is a superuser, but with `superuser = true` the provider reads
      # each role password back from `pg_authid`. A SCRAM hash then differs
      # from the declared password, and every apply changes the role.
      superuser = false;
    };
  };
in
{
  inherit
    provider
    providerSource
    adminUser
    resourceTypes
    postgresqlTfConfig
    ;
  # the generator's drift assertions and coverage data, for the pairing's checks
  # to force independently of any particular configuration.
  inherit (generated) checks coverage;
  resourceOptions = genlib.resourceOptions resourceTypes;
  mkReconcileService = args: genlib.mkReconcileService (args // { inherit executor tokenVar; });
}
