# incus pairing

Declaratively manage the **runtime state** of an
[incus](https://linuxcontainers.org/incus/) host (networks, storage pools,
profiles, projects, server configuration, trusted certificates and more) from
NixOS, on top of the upstream `virtualisation.incus` module, through the
[`lxc/incus`][provider] provider.

[provider]: https://registry.terraform.io/providers/lxc/incus/latest/docs

The options are under `virtualisation.incus.runtime`, not
`services.incus.runtime`, because the upstream module is
`virtualisation.incus`.

## Installation

### Include the module

Add this flake as an input and import its `nixosModules.incus` into your host.
Pointing the input's `nixpkgs` at your own keeps the provider build in step
with the rest of your system.

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
          declarative-runtime.nixosModules.incus
          ./host.nix
        ];
      };
    };
}
```

### Requirements

- **`virtualisation.incus.enable = true`** (the module asserts it).
- Nothing else: the reconciler runs as root and talks to the local daemon over
  its unix socket, so there is no credential to bootstrap.

## Configuration examples

Declare the runtime state under `virtualisation.incus.runtime`. Each entry's
attributes are **typed options** named after the upstream resource's
snake_case attributes (validated at `nix flake check`; an unknown name or
wrong type is a build error). A `project`, `network`, `pool` or similar
attribute names a managed entry by its key, which resolves to a correctly
ordered Terraform reference, or takes a literal name for an object that is
managed elsewhere.

Those options are **derived from the provider's own schema** rather than
hand-written, so they track the pinned provider exactly - see [Provider
updates](#provider-updates).

```nix
{
  virtualisation.incus.runtime = {
    enable = true;

    networks.incusbr0 = {
      type = "bridge";
      config = {
        "ipv4.address" = "10.0.100.1/24";
        "ipv4.nat" = "true";
        "ipv6.address" = "none";
        "dns.domain" = "incus.internal";
      };
    };

    storage_pools.default.driver = "dir";

    # incus makes the `default` profile itself. The provider changes it in
    # place.
    profiles.default.device = [
      {
        name = "eth0";
        type = "nic";
        properties.network = "incusbr0";
      }
      {
        name = "root";
        type = "disk";
        properties = {
          path = "/";
          pool = "default";
        };
      }
    ];

    servers.main.config."core.https_address" = ":8443";

    # A client certificate that the host mints at runtime.
    certificates.metrics = {
      type = "metrics";
      certificateFile = "/var/lib/metrics/client.crt";
    };
  };
}
```

## Preseed and reconciler

The upstream module has a preseed (`virtualisation.incus.preseed`), which can
set up the same objects. The two work differently:

|                           | Preseed                                  | Reconciler                                    |
| ------------------------- | ---------------------------------------- | --------------------------------------------- |
| When                      | On each start of incus (`incus-preseed`) | After the preseed (`declarative-incus`)       |
| Creates, updates          | Yes                                      | Yes                                           |
| Removes undeclared things | No                                       | Yes                                           |
| State                     | None                                     | Terraform state                               |
| Failure                   | Rare: it only sends the YAML to the API  | Possible: it can fail on any one resource     |
| References                | Literal names                            | Ordered references between managed objects    |
| Runtime files             | No: the YAML is in the store             | Yes: `certificateFile` and other `<attr>File` |

A host can use one of the two, or split the objects between them:

- **Reconciler only.** Simplest. But when the reconciler fails, a fresh host
  has no network or pool, so other services that need them (a resolver or a
  cache on the bridge address, say) fail too.
- **Preseed for the base, reconciler for the rest.** The preseed makes the
  objects that other services need at boot, with only the keys they need. The
  reconciler takes those objects over with `adopt = true` and declares the
  other keys and objects. If the reconciler fails, the base still works.

When you split, keep the two in agreement:

- **Declare the same values in both.** The preseed applies its keys again on
  each start of incus. If the reconciler sets a different value for a key that
  the preseed sets, the two change the key back and forth.
- **Set `adopt = true` on each object that the preseed makes.** The provider
  cannot create an object that exists. `adopt` renders an `import` block, so
  the first apply reads the object into the state instead. An `import` block
  of an object that is already in the state does nothing, so `adopt` can stay
  set.
- **Do not set `adopt` on the `default` profile.** incus makes it, and the
  provider changes it in place when it creates it.
- **Do not put certificates in the preseed.** Certificates can not be adopted:
  the provider identifies a certificate by its fingerprint, and the
  fingerprint of a certificate that the host mints at runtime is not known at
  evaluation. A host that moves a certificate from the preseed (or from a
  `incus config trust add`) to the reconciler must remove the trust entry
  once, before the first apply, so that the reconciler can create it again.

## Module options (`virtualisation.incus.runtime`)

| Option      | Type | Default                             | Purpose                                                                                                                           |
| ----------- | ---- | ----------------------------------- | --------------------------------------------------------------------------------------------------------------------------------- |
| `enable`    | bool | `false`                             | Turn on the reconciler.                                                                                                           |
| `configDir` | str  | `/var/lib/declarative-incus/client` | Directory of the provider's client configuration. With no `config.yml` in it, the provider uses the local daemon over its socket. |

Plus one collection option per provider resource (next section).

## Resources

Every [`lxc/incus`][provider] resource but three is exposed as a collection
keyed by an arbitrary handle. What each collection accepts comes from the
vendored provider schema, not from this table: the authoritative option list
is

```sh
nix build .#checks.x86_64-linux.incus-options-doc     # every option, typed
nix build .#checks.x86_64-linux.incus-schema-coverage # what is covered
```

| Option                 | `incus_*` resource    | Key defaults | Reference inputs                                                                                     | `adopt` |
| ---------------------- | --------------------- | ------------ | ---------------------------------------------------------------------------------------------------- | ------- |
| `certificates`         | `certificate`         | `name`       | `projects` -> projects                                                                               | -       |
| `cluster_groups`       | `cluster_group`       | `name`       | -                                                                                                    | -       |
| `networks`             | `network`             | `name`       | `project` -> project                                                                                 | yes     |
| `network_acls`         | `network_acl`         | `name`       | `project` -> project                                                                                 | -       |
| `network_address_sets` | `network_address_set` | `name`       | `project` -> project                                                                                 | -       |
| `network_forwards`     | `network_forward`     | -            | `project` -> project, `network` -> network                                                           | -       |
| `network_integrations` | `network_integration` | `name`       | `project` -> project                                                                                 | -       |
| `network_lbs`          | `network_lb`          | -            | `project` -> project, `network` -> network                                                           | -       |
| `network_peers`        | `network_peer`        | `name`       | `project` -> project, `network` -> network, `target_network` -> network, `target_project` -> project | -       |
| `network_zones`        | `network_zone`        | `name`       | `project` -> project                                                                                 | -       |
| `network_zone_records` | `network_zone_record` | `name`       | `project` -> project, `zone` -> network zone                                                         | -       |
| `profiles`             | `profile`             | `name`       | `project` -> project                                                                                 | yes     |
| `projects`             | `project`             | `name`       | -                                                                                                    | yes     |
| `servers`              | `server`              | -            | -                                                                                                    | -       |
| `storage_pools`        | `storage_pool`        | `name`       | `project` -> project                                                                                 | yes     |
| `storage_buckets`      | `storage_bucket`      | `name`       | `project` -> project, `pool` -> storage pool                                                         | -       |
| `storage_bucket_keys`  | `storage_bucket_key`  | `name`       | `project` -> project, `pool` -> storage pool, `storage_bucket` -> storage bucket                     | -       |
| `storage_volumes`      | `storage_volume`      | `name`       | `project` -> project, `pool` -> storage pool                                                         | -       |

Not modelled: `incus_instance`, `incus_instance_snapshot` and `incus_image`.
Instances are workloads with a lifecycle of their own, not configuration of
the host.

Some limits of the provider and of the references:

- **`servers` takes one entry at most** (the module asserts it). It manages
  only the keys in its `config`, and keeps other server keys.
- **Computed keys are kept.** A network keeps keys such as `ipv4.address` that
  incus computes when they are not set, a dir pool keeps `source`, and a
  project keeps its `features.*` keys. Other keys that are not in `config` are
  removed.
- **Profile devices name their networks and pools literally.** A device's
  properties are a map, so OpenTofu does not know that a profile depends on
  the network or pool that its devices name. When one apply creates both, the
  profile can come first and fail; the next apply then succeeds. A profile
  that uses a network and pool that exist already is not affected.

## State

The reconciler runs as root (access to the incus socket is root access in any
case) and keeps its Terraform state in
`/var/lib/declarative-incus/declarative-terraform`. The state holds the access
and secret keys of each `storage_bucket_keys` entry.

## Provider updates

The option surface is generated from `provider-schema.json`, a normalized dump
of the pinned provider's schema, committed next to `module.nix`. The provider
itself comes from nixpkgs (`terraform-providers.lxc_incus`), so it moves when
the flake's `nixpkgs` input does; after such a bump:

```sh
nix run .#update-provider-schemas
nix flake check
```

The check names every difference the bump introduces: resources added or
removed, attributes added, removed or retyped, and any correction in `lib.nix`
that no longer matches the schema. A new resource must either be modelled or
listed in the pairing's `unsupported` set with a reason - it cannot be
ignored.

## Security note

The `certificate` attribute (`certificates`) accepts a `certificateFile` form
that takes a **host file path** instead of the PEM. The certificate is public,
but a host often mints it at runtime, so it is not known at evaluation. The
file is read at apply time via systemd `LoadCredential=` into a Terraform
variable; the generated `.tf.json` holds only a `${var....}` reference.
