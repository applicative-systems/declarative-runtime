# Garage pairing

Declaratively manage a [Garage](https://garagehq.deuxfleurs.fr/) cluster's
**runtime state** (buckets, access keys and the permissions between them) from
NixOS, on top of the upstream `services.garage` module, through the
[`arsolitt/garagehq`][provider] provider.

[provider]: https://registry.terraform.io/providers/arsolitt/garagehq/latest/docs

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
- **One reconciler per cluster.** On a cluster of more than one node, enable
  the pairing on one node only. See [Multiple nodes](#multiple-nodes).

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
version. The unit does not remove a node from the layout.

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

### Multiple nodes

Enable `services.garage.runtime` and set `layout` on one node of a cluster
only. There are two reasons:

- The reconciler keeps its Terraform state locally on its host. If more than
  one node has the reconciler, each node tries to own the same buckets and keys.
- Garage keeps a layout version only from the first node that applies it. If
  two nodes apply the same version with different roles, the cluster is broken
  until a later version replaces it.

The other nodes need `services.garage` only, with the same `rpc_secret` and the
same `replication_factor`. Each node needs an `rpc_public_addr` that the other
nodes can reach.

Deploy the other nodes first, and read their ids:

```sh
# The node id is the part before the `@`.
garage node id
```

Then tell the reconciler node how to connect to them, and give them their roles
through `layout.peers`:

```nix
services.garage = {
  settings.bootstrap_peers = [
    "<id of node 2>@node2.example.org:3901"
    "<id of node 3>@node3.example.org:3901"
  ];
  runtime.layout = {
    zone = "dc1";
    capacity = 100 * 1000 * 1000 * 1000;
    peers = [
      {
        id = "<id of node 2>";
        zone = "dc2";
        capacity = 100 * 1000 * 1000 * 1000;
      }
      {
        id = "<id of node 3>";
        zone = "dc3";
        capacity = 100 * 1000 * 1000 * 1000;
      }
    ];
  };
};
```

The nodes need `bootstrap_peers` on this node only, because Garage gives each
node the addresses of its peers. The unit assigns all these roles in one layout
version, and it makes a new version only when a role is different.

The cluster must have the quorum that its `replication_factor` needs before the
token unit can mint a token and the reconciler can apply. Each waits up to two
minutes. If the other nodes start later than that, the unit shows as failed.
Restart it when they are available:

```sh
systemctl restart declarative-garage
```

If you remove a node from `peers`, the node keeps its role. Remove it with
`garage layout remove` and `garage layout apply`.

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
  buckets.media = {
    max_size = 10737418240; # 10 GiB
  };
  keys.media-app = { };
  bucket_keys.media-app = {
    bucket = "media";
    access_key = "media-app";
    read = true;
    write = true;
    owner = false;
  };
};
```

The generated key's id and secret are in the Terraform state only; read them
with `garage key info --show-secret media-app`.

### Keys with a known secret

With both `access_key_id` and `secret_access_key` set, the provider imports the key with
those credentials rather than generating one, so a client can be configured
with credentials ahead of time. An id is `GK` followed by 24 hex digits; a
secret is 64 hex digits.

```nix
services.garage.runtime.keys.backup = {
  access_key_id = "GK0123456789abcdef01234567";
  secret_access_keyFile = "/run/secrets/garage-backup-secret";
};
```

### A static website

```nix
services.garage.runtime.buckets.www = {
  website_access = {
    enabled = true;
    index_document = "index.html";
    error_document = "404.html";
  };
};
```

To stop serving a bucket as a website, remove `website_access`. Do not set
`enabled = false`: provider 1.3.1 then reports a change on each apply.

## Module options (`services.garage.runtime`)

| Option      | Type              | Default                                                   | Purpose                                                                                                                                                         |
| ----------- | ----------------- | --------------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `enable`    | bool              | `false`                                                   | Turn on the reconciler.                                                                                                                                         |
| `baseUrl`   | null or str       | `http://localhost:<port of settings.admin.api_bind_addr>` | Garage admin API base URL the provider targets.                                                                                                                 |
| `tokenFile` | null or str       | `settings.admin.admin_token_file`                         | Host path to an admin API token (read via systemd `LoadCredential=`, never stored). `null`: the module mints one.                                               |
| `layout`    | null or submodule | `null`                                                    | Role of this node in the cluster layout: `zone`, `capacity` (bytes), `tags`, plus `peers`, the roles of the other nodes. `null`: the operator makes the layout. |

Plus one collection option per provider resource (next section).

## Resources

The [`arsolitt/garagehq`][provider] bucket, key and permission resources are
exposed as collections keyed by an arbitrary handle. What each collection accepts comes from the vendored
provider schema, not from this table: the authoritative option list is

```sh
nix build .#checks.x86_64-linux.garage-options-doc     # every option, typed
nix build .#checks.x86_64-linux.garage-schema-coverage # what is covered
```

| Option        | `garage_*` resource | Key defaults   | Reference inputs                        |
| ------------- | ------------------- | -------------- | --------------------------------------- |
| `buckets`     | `bucket`            | `global_alias` | -                                       |
| `keys`        | `key`               | `name`         | -                                       |
| `bucket_keys` | `bucket_key`        | -              | `bucket` -> bucket, `access_key` -> key |

`garage_admin_token` and `garage_cluster_layout` are not modelled:
`declarative-garage-token` makes the token of the reconciler, and
`declarative-garage-layout` must assign the layout before the reconciler runs.

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
provider itself is vendored in `pkg.nix`; after a bump there:

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

The secret-valued _resource_ attribute `secret_access_key` (`keys`) accepts a
`secret_access_keyFile` form that takes a **host file path** instead of the
literal value. The file is read at apply time via systemd `LoadCredential=`
into a sensitive Terraform variable and **never enters the Nix store**; the
generated `.tf.json` holds only a `${var....}` reference (the same mechanism
that protects the admin token). Setting `secret_access_key` _literally_ still
works, but renders the value verbatim into the **world-readable** `.tf.json`
store path. `secret_access_key` and `secret_access_keyFile` are mutually
exclusive.
