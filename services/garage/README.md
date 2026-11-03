# Garage pairing

Declaratively manage a [Garage](https://garagehq.deuxfleurs.fr/) cluster's
**runtime state** (buckets, access keys and the permissions between them) from
NixOS, on top of the upstream `services.garage` module, through the
[`jkossis/garage`][provider] provider.

[provider]: https://registry.terraform.io/providers/jkossis/garage/latest/docs

## Installation

### Include the module

Add this flake as an input and import its `nixosModules.garage` into your
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
          declarative-runtime.nixosModules.garage
          ./host.nix
        ];
      };
    };
}
```

### Requirements

- **Garage 2.0 or later** (`services.garage.package = pkgs.garage_2`). The
  provider speaks the v2 admin API, which Garage 1.x does not serve; the module
  asserts the version.
- **The admin API** (`services.garage.settings.admin.api_bind_addr`). The
  reconciler uses Garage's own admin token
  (`services.garage.settings.admin.admin_token_file`) when there is one, and
  else a token that the module mints. See [Admin token](#admin-token).
- **A cluster layout.** The module makes it when you set `layout`. See
  [Cluster layout](#cluster-layout).
- **A single node.** The pairing is built and tested for a Garage cluster of
  one node. See [Single-node scope](#single-node-scope).

### Cluster layout

Garage stores no bucket or key, and reports itself unhealthy, until its layout
gives a role to a node. Set the role of this node:

```nix
services.garage.runtime.layout = {
  zone = "dc1";
  capacity = 100 * 1000 * 1000 * 1000; # 100 GB, in bytes
};
```

The `declarative-garage-layout` unit then gives this node that role and applies
the layout, before the reconciler runs. When the node already has that role,
the unit does nothing. When you change the role, the unit applies a new layout
version. The unit changes no other node.

With `layout = null` (the default), you make the layout yourself, after the
first start of `garage.service`:

```sh
# The node id is the part before the `@`.
garage node id
garage layout assign -z dc1 -c 1G <node id>
garage layout show   # examine the staged change
garage layout apply --version 1
```

Set the zone (`-z`) and the capacity (`-c`) for your host. Garage keeps the
layout in its metadata, so you do this one time only.

The reconciler waits up to two minutes for `/health` and then applies. If the
cluster has no layout at that time, the apply fails and `declarative-garage`
shows as failed. Make the layout, then run the reconciler again:

```sh
systemctl restart declarative-garage
```

### Admin token

When `tokenFile` is `null` (the default when Garage has no
`admin_token_file`), the `declarative-garage-token` unit mints the admin token
of the reconciler each time it starts, and deletes the token it minted before.
The token has only the scope of the admin API functions that the provider
calls. Garage keeps the token in the cluster, and the unit keeps it in
`/run/declarative-garage-token` only, so it is not on disk. Garage can mint a
token only when the cluster has a layout.

The layout and token units use `garage json-api`, which calls the admin API
through Garage's RPC as root. So they need no admin token of their own.

### Single-node scope

Use this pairing on a single-node Garage cluster. The VM test does not cover
more than one node. Also, the reconciler keeps its Terraform state locally on
each host. If you enable `services.garage.runtime` on more than one node of a
cluster, each node tries to own the same buckets and keys through the shared
admin API.

## Configuration examples

Set `services.garage.enable = true` (the module asserts it) and declare the
runtime state under `services.garage.runtime`. Each entry's attributes are
**typed options** named after the upstream resource's snake_case attributes
(validated at `nix flake check`; an unknown name or wrong type is a build
error). A permission names a managed bucket and key by their keys, which
resolve to correctly ordered Terraform references.

Those options are **derived from the provider's own schema** rather than
hand-written, so they track the pinned provider exactly - see
[Provider updates](#provider-updates).

### A bucket for an application

A bucket, a key that Garage generates, and a permission that lets the key read
and write the bucket:

```nix
services.garage.runtime = {
  enable = true;
  bucket.media = {
    max_size = 10737418240; # 10 GiB
  };
  key.media-app = { };
  bucket_permission.media-app = {
    bucket_id = "media";
    access_key_id = "media-app";
    read = true;
    write = true;
  };
};
```

The generated key's id and secret are in the Terraform state only; read them
with `garage key info --show-secret media-app`.

### Keys with a known secret

With both `id` and `secret_access_key` set, the provider imports the key with
those credentials rather than generating one, so a client can be configured
with credentials ahead of time. An id is `GK` followed by 24 hex digits; a
secret is 64 hex digits.

```nix
services.garage.runtime.key.backup = {
  id = "GK0123456789abcdef01234567";
  secret_access_keyFile = "/run/secrets/garage-backup-secret";
};
```

### A static website

```nix
services.garage.runtime.bucket.www = {
  website_enabled = true;
  website_index_document = "index.html";
  website_error_document = "404.html";
};
```

## Module options (`services.garage.runtime`)

| Option      | Type              | Default                                                   | Purpose                                                                                                             |
| ----------- | ----------------- | --------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------- |
| `enable`    | bool              | `false`                                                   | Turn on the reconciler.                                                                                             |
| `baseUrl`   | null or str       | `http://localhost:<port of settings.admin.api_bind_addr>` | Garage admin API base URL the provider targets.                                                                     |
| `tokenFile` | null or str       | `settings.admin.admin_token_file`                         | Host path to an admin API token (read via systemd `LoadCredential=`, never stored). `null`: the module mints one.   |
| `layout`    | null or submodule | `null`                                                    | Role of this node in the cluster layout: `zone`, `capacity` (bytes), `tags`. `null`: the operator makes the layout. |

Plus one collection option per provider resource (next section).

## Resources

Every [`jkossis/garage`][provider] resource is exposed as a collection keyed by
an arbitrary handle. What each collection accepts comes from the vendored
provider schema, not from this table: the authoritative option list is

```sh
nix build .#checks.x86_64-linux.garage-options-doc     # every option, typed
nix build .#checks.x86_64-linux.garage-schema-coverage # what is covered
```

| Option              | Key defaults   | Reference inputs                              |
| ------------------- | -------------- | --------------------------------------------- |
| `bucket`            | `global_alias` | -                                             |
| `key`               | `name`         | -                                             |
| `bucket_permission` | -              | `bucket_id` -> bucket, `access_key_id` -> key |

A reference names a managed entry by its key, or takes a literal bucket or
access key id for one that is managed elsewhere.

## State

The reconciler runs as a systemd dynamic user of its own
(`declarative-garage`) and keeps its Terraform state in
`/var/lib/declarative-garage/declarative-terraform`. The state holds the secret
of each key, generated or imported.

## Provider updates

The option surface is generated from `provider-schema.json`, a normalized
dump of the pinned provider's schema, committed next to `module.nix`. The
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

The secret-valued _resource_ attribute `secret_access_key` (`key`) accepts a
`secret_access_keyFile` form that takes a **host file path** instead of the
literal value. The file is read at apply time via systemd `LoadCredential=`
into a sensitive Terraform variable and **never enters the Nix store**; the
generated `.tf.json` holds only a `${var....}` reference (the same mechanism
that protects the admin token). Setting `secret_access_key` _literally_ still
works, but renders the value verbatim into the **world-readable** `.tf.json`
store path. `secret_access_key` and `secret_access_keyFile` are mutually
exclusive.
