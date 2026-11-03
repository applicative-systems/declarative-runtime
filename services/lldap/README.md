# lldap pairing

Declaratively manage an [lldap](https://github.com/lldap/lldap) directory's
**runtime state** (users, groups, custom attributes and memberships) from
NixOS, on top of the upstream `services.lldap` module, through the
[`tasansga/lldap`][provider] provider.

[provider]: https://registry.terraform.io/providers/tasansga/lldap/latest/docs

## Installation

### Include the module

Add this flake as an input and import its `nixosModules.lldap` into your
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
          declarative-runtime.nixosModules.lldap
          ./host.nix
        ];
      };
    };
}
```

### Requirements

- **The admin password in a file**
  (`services.lldap.settings.ldap_user_pass_file`). The provider logs in as the
  admin user that lldap makes from its settings, with that same password, so
  there is no credential to mint.
- **`force_ldap_user_pass_reset = "always"`** is recommended. lldap otherwise
  reads the password file only when it makes the admin user, so a changed file
  (or a password changed in the web UI) gives a password that the provider
  cannot log in with.

## Configuration examples

Set `services.lldap.enable = true` (the module asserts it) and declare the
runtime state under `services.lldap.runtime`. Each entry's attributes are
**typed options** named after the upstream resource's snake_case attributes
(validated at `nix flake check`; an unknown name or wrong type is a build
error). A membership or an attribute value names a managed user, group or
attribute by its key, which resolves to a correctly ordered Terraform
reference.

Those options are **derived from the provider's own schema** rather than
hand-written, so they track the pinned provider exactly - see
[Provider updates](#provider-updates).

### Users and groups

```nix
services.lldap = {
  enable = true;
  settings = {
    ldap_base_dn = "dc=example,dc=com";
    ldap_user_pass_file = "/run/secrets/lldap-admin-password";
    force_ldap_user_pass_reset = "always";
  };
  runtime = {
    enable = true;
    users.alice = {
      email = "alice@example.com";
      display_name = "Alice Liddell";
      passwordFile = "/run/secrets/lldap-alice-password";
    };
    groups.developers = { };
    members.alice_developers = {
      user = "alice";
      group = "developers";
    };
  };
};
```

### Memberships

Three resources manage memberships, at different scopes:

- `members` adds one user to one group, and keeps all other memberships.
- `group_memberships` sets the full member list of a group.
- `user_memberships` sets the full group list of a user.

The last two remove memberships that are not in their list. Use them only for
groups and users whose memberships no other resource manages, else each apply
undoes the other.

```nix
services.lldap.runtime.group_memberships.ops = {
  group = "ops";
  users = [ "alice" "bob" ];
};
```

The built-in groups (`lldap_admin`, `lldap_password_manager`,
`lldap_strict_readonly`) are made by lldap and are not managed here. Refer to
one by its literal group id.

### Custom attributes

An attribute name takes only letters, digits and `-`.

```nix
services.lldap.runtime = {
  user_attributes.department = {
    attribute_type = "STRING";
    is_visible = true;
  };
  user_attribute_assignments.alice_department = {
    user = "alice";
    attribute = "department";
    value = [ "engineering" ];
  };
};
```

## Module options (`services.lldap.runtime`)

| Option      | Type        | Default                                 | Purpose                                                                            |
| ----------- | ----------- | --------------------------------------- | ---------------------------------------------------------------------------------- |
| `enable`    | bool        | `false`                                 | Turn on the reconciler.                                                            |
| `baseUrl`   | str         | `http://localhost:<settings.http_port>` | lldap web API base URL the provider targets.                                       |
| `ldapUrl`   | str         | `ldap://localhost:<settings.ldap_port>` | lldap LDAP URL. The provider uses it only to set user passwords.                   |
| `adminUser` | str         | `settings.ldap_user_dn`                 | User the provider logs in as. It must be in `lldap_admin`.                         |
| `baseDN`    | str         | `settings.ldap_base_dn`                 | Base DN of the directory.                                                          |
| `tokenFile` | null or str | `settings.ldap_user_pass_file`          | Host path to the password of `adminUser` (read via `LoadCredential=`, not stored). |

Plus one collection option per provider resource (next section).

## Resources

Every [`tasansga/lldap`][provider] resource is exposed as a collection keyed by
an arbitrary handle. What each collection accepts comes from the vendored
provider schema, not from this table: the authoritative option list is

```sh
nix build .#checks.x86_64-linux.lldap-options-doc     # every option, typed
nix build .#checks.x86_64-linux.lldap-schema-coverage # what is covered
```

| Option                        | `lldap_*` resource           | Key defaults   | Reference inputs                                 |
| ----------------------------- | ---------------------------- | -------------- | ------------------------------------------------ |
| `users`                       | `user`                       | `username`     | -                                                |
| `groups`                      | `group`                      | `display_name` | -                                                |
| `user_attributes`             | `user_attribute`             | `name`         | -                                                |
| `group_attributes`            | `group_attribute`            | `name`         | -                                                |
| `members`                     | `member`                     | -              | `user` -> user, `group` -> group                 |
| `group_memberships`           | `group_memberships`          | -              | `group` -> group, `users` -> users               |
| `user_memberships`            | `user_memberships`           | -              | `user` -> user, `groups` -> groups               |
| `user_attribute_assignments`  | `user_attribute_assignment`  | -              | `user` -> user, `attribute` -> user attribute    |
| `group_attribute_assignments` | `group_attribute_assignment` | -              | `group` -> group, `attribute` -> group attribute |

A reference names a managed entry by its key, or takes a literal user name,
group id or attribute name for one that is managed elsewhere.

## State

The reconciler runs as a systemd dynamic user of its own
(`declarative-lldap`) and keeps its Terraform state in
`/var/lib/declarative-lldap/declarative-terraform`. The state holds the
password of each user that sets one.

## Provider updates

The option surface is generated from `provider-schema.json`, a normalized dump
of the pinned provider's schema, committed next to `module.nix`. The
provider itself comes from nixpkgs, so it moves when the flake's `nixpkgs`
input does; after such a bump:

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

The secret-valued _resource_ attribute `password` (`users`) accepts a
`passwordFile` form that takes a **host file path** instead of the literal
value. The file is read at apply time via systemd `LoadCredential=` into a
sensitive Terraform variable and **never enters the Nix store**; the generated
`.tf.json` holds only a `${var....}` reference (the same mechanism that
protects the admin password). Setting `password` _literally_ still works, but
renders the value verbatim into the **world-readable** `.tf.json` store path.
`password` and `passwordFile` are mutually exclusive.
