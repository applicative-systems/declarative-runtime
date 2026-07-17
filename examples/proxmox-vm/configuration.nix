# Example: a NixOS host running Proxmox VE (via SaumonNet/proxmox-nixos) whose
# guest VM is declared entirely in Nix and reconciled by the proxmox-ve pairing
# (bpg/proxmox provider). `nix run .#proxmox-vm` boots this as a QEMU VM.
#
# The flake wires in proxmox-nixos.nixosModules.proxmox-ve + its overlay and
# declarative-runtime.nixosModules.default; this file is just the host config.
#
# What converges at boot, with no manual clicking in the Proxmox UI:
#   * pveproxy comes up (the Proxmox API on :8006);
#   * declarative-proxmox-ve.service downloads a Debian cloud image to the node,
#     creates a resource pool, and creates a cloud-init VM that imports that
#     image — all through the API.
#
# Actually *booting* the inner guest needs nested KVM on the host you run this
# on, and a datastore that can hold VM disks (see README). The declarative
# wiring is exercised regardless.
{
  pkgs,
  modulesPath,
  ...
}:
let
  nodeName = "pve";
in
{
  imports = [ "${modulesPath}/virtualisation/qemu-vm.nix" ];

  networking.hostName = nodeName;
  networking.firewall.enable = false;

  # this is also the proxmox login, cf. `root@pam`
  services.getty.autologinUser = "root";
  users.users.root.password = "hackme";

  environment.systemPackages = with pkgs; [
    curl
    jq
  ];

  # Demo-only stand-ins for host-file secrets (real deployments: sops-nix /
  # agenix). Never the world-readable nix store.
  environment.etc = {
    "secrets/proxmox-root-password".text = "hackme";
    "secrets/guest-password".text = "hackme";
  };

  # --- Proxmox VE (the "upstream" service, from proxmox-nixos) ----------------
  services.proxmox-ve = {
    enable = true;
    # Reachable IP recorded in /etc/hosts. 10.0.2.15 is the default address the
    # QEMU user-mode network hands the guest.
    ipAddress = "10.0.2.15";
    # Make the bridge the declared VM attaches to visible in Proxmox.
    bridges = [ "vmbr0" ];
  };

  # A standalone bridge for guests. On real hardware you would enslave your
  # uplink here; kept member-less so it does not disturb the example VM's own
  # QEMU user-mode networking.
  networking.bridges.vmbr0.interfaces = [ ];
  networking.interfaces.vmbr0.ipv4.addresses = [
    {
      address = "10.10.10.1";
      prefixLength = 24;
    }
  ];

  # --- Declarative runtime state (this repo's pairing) -----------------------
  services.proxmox-ve.runtime = {
    enable = true;
    endpoint = "https://localhost:8006/";
    # self-signed cert on localhost (the default), so insecure stays true.
    username = "root@pam";
    passwordFile = "/etc/secrets/proxmox-root-password";

    # Server-side download of a cloud image to the node (uses the API, no SSH).
    download_files.debian12 = {
      node_name = nodeName;
      datastore_id = "local";
      content_type = "iso";
      url = "https://cloud.debian.org/images/cloud/bookworm/latest/debian-12-genericcloud-amd64.qcow2";
      file_name = "debian-12-genericcloud-amd64.img";
    };

    # A resource pool the VM joins (demonstrates a cross-resource reference).
    pools.lab.comment = "Lab guests";

    vms.declarative-guest = {
      node_name = nodeName;
      pool = "lab"; # -> ${proxmox_virtual_environment_pool.pool_lab.pool_id}
      description = "Declared entirely in Nix; reconciled by OpenTofu at boot.";
      tags = [ "declarative" ];

      cpu = {
        cores = 2;
        type = "host";
      };
      memory.dedicated = 2048;

      disk = [
        {
          interface = "scsi0";
          datastore_id = "local-lvm";
          # Import the downloaded image via the API. The id is the deterministic
          # "<datastore>:<content>/<file_name>" of the download above.
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

      # cloud-init: DHCP on the guest NIC + a default user whose password comes
      # from a host file (kept out of the generated .tf.json).
      initialization = {
        ip_config = [ { ipv4.address = "dhcp"; } ];
        user_account = {
          username = "admin";
          passwordFile = "/etc/secrets/guest-password";
        };
      };

      agent.enabled = true;
      started = true;
    };
  };

  virtualisation = {
    # Proxmox VE + an inner guest are heavy; size the outer VM accordingly.
    memorySize = 6144;
    diskSize = 16384;
    cores = 4;
    graphics = false;
    # Forward the Proxmox web UI / API to the host for poking around.
    forwardPorts = [
      {
        from = "host";
        host.port = 8006;
        guest.port = 8006;
      }
      {
        from = "host";
        host.port = 2222;
        guest.port = 22;
      }
    ];
  };

  system.stateVersion = "26.05";
}
