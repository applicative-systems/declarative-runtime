# Example: declarative VM on a declarative Proxmox VE

This example boots a NixOS host that **is** a Proxmox VE hypervisor (via
[SaumonNet/proxmox-nixos][proxmox-nixos]) and whose guest VM is declared
entirely in Nix and reconciled through the `proxmox-ve` pairing in this repo
(the [`bpg/proxmox`][bpg] OpenTofu provider).

It ties the two projects together:

- **proxmox-nixos** makes the hypervisor itself declarative (`services.proxmox-ve.enable`).
- **this repo** makes the hypervisor's _runtime state_ declarative
  (`services.proxmox-ve.runtime.*`) — the piece proxmox-nixos explicitly leaves
  to "two sources of truth".

[proxmox-nixos]: https://github.com/SaumonNet/proxmox-nixos
[bpg]: https://registry.terraform.io/providers/bpg/proxmox/latest/docs

## What it declares

At boot, with no manual clicking in the Proxmox UI, `declarative-proxmox-ve.service`:

1. downloads a Debian 12 cloud image to the node's `local` datastore (server-side
   download via the API — no SSH);
2. creates a `lab` resource pool;
3. creates a cloud-init VM `declarative-guest` that imports that image, joins the
   `lab` pool (a resolved cross-resource reference), gets a virtio NIC on
   `vmbr0`, and a cloud-init `admin` user whose password comes from a host file
   (never the world-readable store).

See [`configuration.nix`](./configuration.nix) for the full host config.

## Run it

```sh
nix run .#proxmox-vm
```

This launches the hypervisor as a QEMU VM. Log in on the console as `root`
(password `hackme`, demo-only). The Proxmox API/UI is forwarded to
<https://localhost:8006> (log in with `root` / `hackme`, realm "Linux PAM").

Watch the reconciler converge:

```sh
journalctl -u declarative-proxmox-ve.service -f
# then, once it has applied:
pvesh get /pools/lab
qm list
```

## Requirements & caveats

This example is only built/run for **x86_64-linux** — proxmox-nixos supports
only that architecture.

- **Binary cache.** Building Proxmox VE from source is expensive. Add the
  proxmox-nixos cache before running:

  ```
  nix.settings.substituters = [ "https://cache.saumon.network/proxmox-nixos" ];
  nix.settings.trusted-public-keys = [ "proxmox-nixos:D9RYSWpQQC/msZUWphOY2I5RLH5Dd6yQcaHIuug7dWM=" ];
  ```

- **Nested virtualization.** The declarative wiring (download, pool, VM
  definition) is applied purely through the API and works in the QEMU VM as-is.
  Actually _booting_ the inner guest requires nested KVM on your host
  (`kvm-intel nested=1` / `kvm-amd nested=1`).

- **Datastore for VM disks.** The example imports the disk onto `local-lvm`,
  the conventional Proxmox default. A fresh proxmox-nixos VM may not have a
  storage that accepts VM images; create/point one (`local-lvm`, a ZFS pool, a
  directory storage with the `images` content type, ...) to match your host.
  This is host storage layout, outside the pairing's scope.

- **Network reachability.** The reconciler needs outbound network to fetch the
  cloud image; the QEMU user-mode network provides it. `vmbr0` is a member-less
  bridge here (so it does not disturb the outer VM's own networking); on real
  hardware you would enslave your uplink to it.

The credentials in this example (`hackme`) are demonstration stand-ins for
host-file secrets that real deployments source from sops-nix / agenix.
