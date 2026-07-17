# Proxmox VE

Declaratively manage the **runtime state** of a [Proxmox VE][pve] host from
NixOS: virtual machines, downloaded images and uploaded files, resource pools,
and access control (roles, groups, users, ACLs, API tokens).

Proxmox VE itself is not in Nixpkgs; the "upstream" service is the one from
[SaumonNet/proxmox-nixos][proxmox-nixos] (`services.proxmox-ve.enable`, whose API
is served by `pveproxy.service` on port 8006). That project makes the hypervisor
_installable_ declaratively, but — as its own README notes — VM/guest state has
"essentially two sources of truth (the NixOS configuration and the Proxmox web
interface)". This pairing closes that gap: you declare the desired runtime state
under `services.proxmox-ve.runtime.*`, and a run-once reconciler applies it via
OpenTofu and the [`bpg/proxmox`][bpg] provider after the API comes up.

[pve]: https://www.proxmox.com/en/products/proxmox-virtual-environment/overview
[proxmox-nixos]: https://github.com/SaumonNet/proxmox-nixos
[bpg]: https://registry.terraform.io/providers/bpg/proxmox/latest/docs

## Installation

### Include the modules

The pairing targets the Proxmox VE **API**, so it works both on a local
proxmox-nixos node and against a remote Proxmox VE host. For the local case,
import this pairing alongside the proxmox-nixos module:

```nix
{
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    proxmox-nixos.url = "github:SaumonNet/proxmox-nixos";

    # This repository.
    declarative-runtime.url = "github:youruser/declarative-runtime";
    declarative-runtime.inputs.nixpkgs.follows = "nixpkgs";
  };

  outputs =
    { nixpkgs, proxmox-nixos, declarative-runtime, ... }:
    {
      nixosConfigurations.pve = nixpkgs.lib.nixosSystem {
        system = "x86_64-linux";
        modules = [
          proxmox-nixos.nixosModules.proxmox-ve
          declarative-runtime.nixosModules.proxmox-ve
          { nixpkgs.overlays = [ proxmox-nixos.overlays.x86_64-linux ]; }
          ./host.nix
        ];
      };
    };
}
```

To manage a **remote** Proxmox VE host from an ordinary NixOS machine, import
only `declarative-runtime.nixosModules.proxmox-ve` and point
`services.proxmox-ve.runtime.endpoint` at that host — proxmox-nixos is not
needed there.

### Provide a credential

The Proxmox API credential cannot be self-bootstrapped (the root password is set
by the OS install; an API token is minted by an admin), so one must be supplied
as a **host file path** (e.g. via sops-nix or agenix — never a store path):

- **API token** (recommended): set `apiTokenFile` to a file holding
  `user@realm!tokenid=uuid`. Note Proxmox rejects a few privileged operations
  for token auth (some `root`-only VM options, privileged containers).
- **Username / password**: leave `apiTokenFile` unset, set `username` (default
  `root@pam`) and `passwordFile`. Full API coverage; also lets the optional SSH
  block reuse the password.

## Configuration examples

Declare desired state under `services.proxmox-ve.runtime`. Each entry's
attributes are **typed options** named after the provider's snake_case schema.

### A cloud-init VM from a downloaded image

```nix
{
  services.proxmox-ve.runtime = {
    enable = true;
    endpoint = "https://localhost:8006/";
    passwordFile = "/run/secrets/proxmox-root-password";

    # Fetch a cloud image to the node (server-side download, no SSH).
    download_files.debian12 = {
      node_name = "pve";
      datastore_id = "local";
      content_type = "iso";
      url = "https://cloud.debian.org/images/cloud/bookworm/latest/debian-12-genericcloud-amd64.qcow2";
      file_name = "debian-12-genericcloud-amd64.img";
    };

    pools.lab.comment = "Lab guests";

    vms.web = {
      node_name = "pve";
      pool = "lab"; # reference to the managed pool above
      cpu = {
        cores = 2;
        type = "host";
      };
      memory.dedicated = 2048;

      disk = [
        {
          interface = "scsi0";
          datastore_id = "local-lvm";
          # Import the downloaded image via the API (no SSH). Use the
          # deterministic "<datastore>:<content>/<file_name>" id.
          import_from = "local:iso/debian-12-genericcloud-amd64.img";
          size = 20;
        }
      ];

      network_device = [
        {
          bridge = "vmbr0";
          model = "virtio";
        }
      ];

      initialization = {
        ip_config = [ { ipv4.address = "dhcp"; } ];
        user_account = {
          username = "admin";
          # Keep the password out of the world-readable store.
          passwordFile = "/run/secrets/guest-password";
          keys = [ "ssh-ed25519 AAAA... admin@laptop" ];
        };
      };

      agent.enabled = true;
      started = true;
    };
  };
}
```

The VM does not hold a Terraform-level dependency on the download (the image id
is a literal in a nested disk block), so on the very first apply the VM may be
created before the image finishes downloading. The reconciler retries the apply
(`applyRetries`), and `tofu apply` is idempotent, so it converges within a few
attempts.

### Access control (roles, groups, users, ACLs)

```nix
{
  services.proxmox-ve.runtime = {
    enable = true;
    apiTokenFile = "/run/secrets/proxmox-token";

    roles.deployer.privileges = [
      "VM.Allocate"
      "VM.Config.Disk"
      "VM.Config.CPU"
      "VM.Config.Memory"
      "Datastore.AllocateSpace"
    ];

    groups.ops.comment = "Operations";

    users."svc@pve" = {
      comment = "Deployment service account";
      enabled = true;
      groups = [ "ops" ]; # reference to the managed group
      passwordFile = "/run/secrets/svc-password";
    };

    # Bind the role to the user at a path (references resolve the ids).
    acls.svc_root = {
      path = "/";
      role = "deployer";
      user = "svc@pve";
      propagate = true;
    };

    # An API token owned by the managed user; its secret lands in Terraform
    # state only (never read back into config).
    user_tokens.ci = {
      user = "svc@pve";
      comment = "CI token";
    };
  };
}
```

### A remote host

```nix
services.proxmox-ve.runtime = {
  enable = true;
  endpoint = "https://pve.example.com:8006/";
  insecure = false; # once the endpoint presents a trusted certificate
  apiTokenFile = "/run/secrets/proxmox-token";

  pools.tenants.comment = "Customer pool";
};
```

## Module options (`services.proxmox-ve.runtime`)

| Option         | Type            | Default                   | Purpose                                                                   |
| -------------- | --------------- | ------------------------- | ------------------------------------------------------------------------- |
| `enable`       | bool            | `false`                   | Turn on the reconciler.                                                   |
| `endpoint`     | str             | `https://localhost:8006/` | Proxmox VE API base URL (local node or a remote host).                    |
| `insecure`     | bool            | `true`                    | Skip TLS verification (Proxmox ships a self-signed cert by default).      |
| `apiTokenFile` | null or str     | `null`                    | Host path to an API token `user@realm!tokenid=uuid`.                      |
| `username`     | str             | `root@pam`                | Account for password auth (when `apiTokenFile` is unset).                 |
| `passwordFile` | null or str     | `null`                    | Host path to the `username` password. Required unless `apiTokenFile` set. |
| `ssh`          | null or submod. | `null`                    | Optional SSH access (only for snippets / `source_file.path` / idmap).     |

Exactly one of `apiTokenFile` / `passwordFile` must be set. Plus one collection
option per modelled resource (next section).

## Resources

Modelled surface (the collection option → `bpg/proxmox` resource):

| Option           | Resource type                       | Key defaults | Reference inputs                              |
| ---------------- | ----------------------------------- | ------------ | --------------------------------------------- |
| `vms`            | `proxmox_virtual_environment_vm`    | `name`       | `pool` → pool                                 |
| `download_files` | `proxmox_download_file`             | —            | —                                             |
| `files`          | `proxmox_virtual_environment_file`  | —            | —                                             |
| `pools`          | `proxmox_virtual_environment_pool`  | `pool_id`    | —                                             |
| `roles`          | `proxmox_virtual_environment_role`  | `role_id`    | —                                             |
| `groups`         | `proxmox_virtual_environment_group` | `group_id`   | —                                             |
| `users`          | `proxmox_virtual_environment_user`  | `user_id`    | `groups` → groups                             |
| `acls`           | `proxmox_acl`                       | —            | `role` → role, `user` → user, `group` → group |
| `user_tokens`    | `proxmox_user_token`                | `token_name` | `user` → user                                 |

Notes:

- **Resource names track bpg's SDKv2→Plugin-Framework migration.** Each resource
  uses the name that is _not_ deprecated in the pinned provider: the short
  `proxmox_*` name where the long one is already deprecated (`download_file`,
  `acl`, `user_token`), the long `proxmox_virtual_environment_*` name otherwise
  (the VM's `proxmox_vm` rewrite is not yet feature-complete). The schemas are
  identical; only the type string differs.
- **The VM is modelled in full**: every settable attribute plus every nested
  block (`cpu`, `memory`, `disk` incl. `speed`, `network_device`, `agent`,
  `initialization` incl. cloud-init `ip_config`/`dns`/`user_account`, `cdrom`,
  `efi_disk`, `tpm_state`, `hostpci`, `usb`, `numa`, `rng`, `smbios`, ...).
- **References** name the _key_ of another managed resource and are resolved to a
  `${type.label.field}` interpolation, which both fills the id the user cannot
  know and orders `tofu apply`. A literal id is also accepted (for a resource
  managed elsewhere). Nested ids (e.g. a disk's `import_from`/`file_id`) are not
  references — pass the literal `datastore:content/file` id.
- **Not yet modelled**: storage, SDN, Ceph, HA, ACME, firewall, realms, metrics,
  hardware mappings, and containers (`proxmox_virtual_environment_container`).
  The renderer is generic, so each is purely another `resourceTypes` entry.
- The reconciler keeps its Terraform state under
  `/var/lib/declarative-proxmox-ve`, owned by a dedicated `declarative-proxmox-ve`
  system user, and runs (softly) after `pveproxy.service`.

## Security note

The API credential always flows through systemd `LoadCredential=` into the
sensitive `proxmox_token` Terraform variable — the generated `.tf.json` holds
only a `${var.proxmox_token}` reference, never the literal.

Per-resource secrets support an `<attr>File` form that takes a **host file
path** instead of the literal value: the top-level `users.<u>.passwordFile`, the
nested cloud-init `vms.<v>.initialization.user_account.passwordFile`, and the
inline `files.<f>.source_raw.dataFile`. Each is read at apply time via
`LoadCredential=` into its own sensitive variable and **never enters the Nix
store**; the generated `.tf.json` holds only a `${var.…}` reference. The literal
and its `*File` form are mutually exclusive — prefer the `*File` form for any
real secret. Setting a literal renders it verbatim into the **world-readable**
`.tf.json` store path; use it only for throwaway values.

Generated API-token secrets (`user_tokens.<t>`) are computed by Proxmox and live
only in the local Terraform state under `/var/lib/declarative-proxmox-ve` — back
that directory up accordingly.
