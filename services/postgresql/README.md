# PostgreSQL pairing

Declaratively manage a [PostgreSQL](https://www.postgresql.org/) server's
**runtime state** (roles, databases, schemas, extensions, functions,
privileges, logical replication, foreign servers and user mappings) from NixOS,
on top of the upstream `services.postgresql` module, through the
[`cyrilgdn/postgresql`][provider] provider.

The upstream module can already make databases and roles
(`ensureDatabases`, `ensureUsers`), but it only adds: it does not set
passwords, owners, privileges or memberships, and it never removes what is no
longer declared. This pairing does all of that, with the usual Terraform state
semantics.

[provider]: https://registry.terraform.io/providers/cyrilgdn/postgresql/latest/docs

## Installation

### Include the module

Add this flake as an input and import its `nixosModules.postgresql` into your
host. Pointing the input's `nixpkgs` at your own keeps the provider build in
step with the rest of your system.

```nix
{
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

    # This repository.
    declarative-runtime.url = "github:youruser/declarative-runtime";
    declarative-runtime.inputs.nixpkgs.follows = "nixpkgs";
  };

  outputs =
    { nixpkgs, declarative-runtime, ... }:
    {
      nixosConfigurations.myhost = nixpkgs.lib.nixosSystem {
        system = "x86_64-linux";
        modules = [
          declarative-runtime.nixosModules.postgresql
          ./host.nix
        ];
      };
    };
}
```

### Requirements

- **Nothing to mint.** The module adds a superuser role,
  `declarative_postgresql`, through `services.postgresql.ensureUsers`. A
  oneshot (`declarative-postgresql-password.service`) gives it a random
  password, kept in `/var/lib/declarative-postgresql/admin-password` and
  readable by `postgres` only. The provider logs in with it over TCP on
  `127.0.0.1`, so the module puts `host` lines for that role first in
  `services.postgresql.authentication`. Do not declare that role yourself.
- **`wal_level = "logical"`** (`services.postgresql.settings.wal_level`) for
  publications, logical replication slots and subscriptions.

## Configuration examples

Set `services.postgresql.enable = true` (the module asserts it) and declare the
runtime state under `services.postgresql.runtime`. Each entry's attributes are
**typed options** named after the upstream resource's snake_case attributes
(validated at `nix flake check`; an unknown name or wrong type is a build
error). An owner, a grantee, a database or a schema names a managed entry by
its key, which resolves to a correctly ordered Terraform reference, or takes a
literal name for an object that is managed elsewhere (`postgres`, `public`).

Those options are **derived from the provider's own schema** rather than
hand-written, so they track the pinned provider exactly - see
[Provider updates](#provider-updates).

### A database for an application

```nix
services.postgresql = {
  enable = true;
  runtime = {
    enable = true;
    roles.app = {
      login = true;
      passwordFile = "/run/secrets/postgresql-app-password";
    };
    databases.app.owner = "app";
  };
};
```

### Read-only access

A group role that can read every table in a schema, now and later:

```nix
services.postgresql.runtime = {
  roles.readers = { };
  roles.alice = {
    login = true;
    roles = [ "readers" ];
  };
  grants.readers_usage = {
    database = "app";
    schema = "public";
    role = "readers";
    object_type = "schema";
    privileges = [ "USAGE" ];
  };
  grants.readers_tables = {
    database = "app";
    schema = "public";
    role = "readers";
    object_type = "table";
    privileges = [ "SELECT" ];
  };
  default_privileges.readers_tables = {
    database = "app";
    schema = "public";
    owner = "app";
    role = "readers";
    object_type = "table";
    privileges = [ "SELECT" ];
  };
};
```

### Role memberships

A role's `roles` list is its complete list of memberships: the provider reads
all memberships back and removes the ones that are not in the list. Use
`grant_roles` only to add a membership to a role that this module does not
manage (such as `postgres`), else each apply undoes the other.

### Write-only passwords

`password` is kept in the Terraform state. `password_wo` is not: OpenTofu sends
it to the provider, but never stores it. The provider sets it again only when
`password_wo_version` changes, so change that value together with the file.

```nix
services.postgresql.runtime.roles.backup = {
  login = true;
  password_woFile = "/run/secrets/postgresql-backup-password";
  password_wo_version = "1";
};
```

## Module options (`services.postgresql.runtime`)

| Option   | Type | Default                             | Purpose                                                 |
| -------- | ---- | ----------------------------------- | ------------------------------------------------------- |
| `enable` | bool | `false`                             | Turn on the reconciler.                                 |
| `port`   | port | `services.postgresql.settings.port` | Port of the local server that the provider connects to. |

Plus one collection option per provider resource (next section).

## Resources

Every [`cyrilgdn/postgresql`][provider] resource is exposed as a collection
keyed by an arbitrary handle. What each collection accepts comes from the
vendored provider schema, not from this table: the authoritative option list
is

```sh
nix build .#checks.x86_64-linux.postgresql-options-doc     # every option, typed
nix build .#checks.x86_64-linux.postgresql-schema-coverage # what is covered
```

| Option                       | `postgresql_*` resource     | Key defaults  | Reference inputs                                                            |
| ---------------------------- | --------------------------- | ------------- | --------------------------------------------------------------------------- |
| `roles`                      | `role`                      | `name`        | `roles` -> roles, `assume_role` -> role                                     |
| `databases`                  | `database`                  | `name`        | `owner` -> role                                                             |
| `schemas`                    | `schema`                    | `name`        | `database` -> database, `owner` -> role                                     |
| `extensions`                 | `extension`                 | `name`        | `database` -> database, `schema` -> schema                                  |
| `functions`                  | `function`                  | `name`        | `database` -> database, `schema` -> schema                                  |
| `grants`                     | `grant`                     | -             | `database` -> database, `role` -> role, `schema` -> schema                  |
| `grant_roles`                | `grant_role`                | -             | `role` -> role, `grant_role` -> role                                        |
| `default_privileges`         | `default_privileges`        | -             | `database` -> database, `owner` -> role, `role` -> role, `schema` -> schema |
| `publications`               | `publication`               | `name`        | `database` -> database, `owner` -> role                                     |
| `subscriptions`              | `subscription`              | `name`        | `database` -> database, `publications` -> publications, `slot_name` -> slot |
| `replication_slots`          | `replication_slot`          | `name`        | `database` -> database                                                      |
| `physical_replication_slots` | `physical_replication_slot` | `name`        | -                                                                           |
| `servers`                    | `server`                    | `server_name` | `fdw_name` -> extension, `server_owner` -> role                             |
| `user_mappings`              | `user_mapping`              | -             | `server_name` -> server, `user_name` -> role                                |
| `security_labels`            | `security_label`            | -             | -                                                                           |

A database-scoped entry without `database` goes into the database that the
provider connects to, `postgres`. A foreign server is always there, so give
its foreign data wrapper extension no `database` either.

A subscription to a publication on this same server must use
`create_slot = false` and name a managed replication slot, because
`CREATE SUBSCRIPTION` cannot make a slot on the server that it runs on.

## State

The reconciler runs as `postgres` and keeps its Terraform state in
`/var/lib/declarative-postgresql/declarative-terraform`. The state holds each
`password` that a role sets, each secret option of a user mapping and each
subscription's `conninfo`, but no `password_wo`.

## Provider updates

The option surface is generated from `provider-schema.json`, a normalized dump
of the provider's schema. The provider comes from nixpkgs
(`pkgs.terraform-providers.cyrilgdn_postgresql`), so a nixpkgs bump can move
it. Then:

```sh
nix run .#update-provider-schemas
nix flake check
```

The check names every difference the bump introduces: resources added or
removed, attributes added, removed or retyped, and any correction in `lib.nix`
that no longer matches the schema. A new resource must either be modelled or
listed in the pairing's `unsupported` set with a reason - it cannot be ignored.

An upstream attribute that becomes **required** turns into a required option,
which fails evaluation for configurations that never set it. That is usually the
right signal, but `forceOptional` in the collection's overlay is the release
valve when it is not.

## Security note

The secret-valued _resource_ attributes (`password` and `password_wo` of
`roles`, `conninfo` of `subscriptions`, and each key of a user mapping's
`options`, such as `password`) accept a `<attr>File` form that takes a **host file path** instead
of the literal value. The file is read at apply time via systemd
`LoadCredential=` into a sensitive Terraform variable and **never enters the
Nix store**; the generated `.tf.json` holds only a `${var....}` reference (the
same mechanism that protects the admin password). Setting the attribute
_literally_ still works, but renders the value verbatim into the
**world-readable** `.tf.json` store path. An attribute and its `<attr>File`
form are mutually exclusive.
