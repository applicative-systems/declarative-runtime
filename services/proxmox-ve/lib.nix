# bpg/proxmox provider specifics: executor, resource types, provider block.
# Shared helpers (option helpers, renderer, reconciler) live in modules/lib.
#
# The whole managed bpg/proxmox surface is modelled below as strictly typed
# option collections (no freeformType), derived from the provider schema
# (`tofu providers schema -json`); computed/output-only attributes are omitted.
# bpg is mid-migration from the legacy SDKv2 (long `proxmox_virtual_environment_*`
# names) to the Plugin Framework (short `proxmox_*` names) for its v1.0. Each
# resource uses whichever name is NOT deprecated in the pinned provider: the
# long name for most (their short form does not exist yet, or the long form is
# still current, e.g. the VM — its `proxmox_vm` rewrite is not yet
# feature-complete), and the short name where the long one is already deprecated
# (download_file, acl, user_token). The schemas are identical either way.
#
# Scope: guest lifecycle (VMs), image/file provisioning (download_file, file)
# and access control (pools, roles, users, groups, ACLs, API tokens). Storage,
# SDN, Ceph, HA, ACME, firewall, realms, metrics and hardware mappings are not
# yet modelled (see README) — the renderer is generic, so adding them is purely
# more `resourceTypes` entries.
{ pkgs }:
let
  genlib = import ../../modules/lib { inherit pkgs; };
  inherit (genlib)
    oStr
    oBool
    oInt
    oListStr
    oSub
    oListSub
    rStr
    rListStr
    ;
  inherit (pkgs) lib;
  ty = lib.types;

  # required int option (no `r*` int helper in the shared lib).
  rInt =
    description:
    lib.mkOption {
      type = ty.int;
      inherit description;
    };

  provider = pkgs.terraform-providers.bpg_proxmox;
  providerVersion = provider.version;

  # Single sensitive tf variable. Carries the API token when the operator
  # supplies `apiTokenFile`, otherwise the `username` account's password. The
  # provider block references whichever field matches the auth mode; the
  # variable is always fed from LoadCredential as TF_VAR_proxmox_token.
  tokenVar = "proxmox_token";

  executor = pkgs.opentofu.withPlugins (_: [ provider ]);

  # -- references (top-level, resolved against managed siblings) --------------

  # VM -> resource pool. Names a managed pool (its pool_id is interpolated) or a
  # literal pool id for a pool managed elsewhere; also orders the VM after it.
  poolRef = {
    attr = "pool_id";
    targets = [
      {
        collection = "pools";
        field = "pool_id";
      }
    ];
    managedOnly = false;
    required = false;
    description = "Resource pool for the VM: the key of a managed pool (services.proxmox-ve.runtime.pools.<name>), or a literal pool id.";
  };

  # ACL -> role. The role granted at `path`; a managed role or a literal id.
  aclRoleRef = {
    attr = "role_id";
    targets = [
      {
        collection = "roles";
        field = "role_id";
      }
    ];
    managedOnly = false;
    required = true;
    description = "Role granted by this ACL entry: the key of a managed role (services.proxmox-ve.runtime.roles.<name>), or a literal role id.";
  };

  # ACL -> user (subject). Exactly one of user/group/token_id must be set.
  aclUserRef = {
    attr = "user_id";
    targets = [
      {
        collection = "users";
        field = "user_id";
      }
    ];
    managedOnly = false;
    required = false;
    description = "Grant the role to this user: the key of a managed user (services.proxmox-ve.runtime.users.<name>), or a literal user id (\"user@realm\"). Exactly one of user/group/token_id.";
  };

  # ACL -> group (subject).
  aclGroupRef = {
    attr = "group_id";
    targets = [
      {
        collection = "groups";
        field = "group_id";
      }
    ];
    managedOnly = false;
    required = false;
    description = "Grant the role to this group: the key of a managed group (services.proxmox-ve.runtime.groups.<name>), or a literal group id. Exactly one of user/group/token_id.";
  };

  # user -> groups (set). Each entry a managed group key or a literal group id.
  userGroupsRef = {
    attr = "groups";
    list = true;
    targets = [
      {
        collection = "groups";
        field = "group_id";
      }
    ];
    managedOnly = false;
    required = false;
    description = "Groups the user belongs to: each a managed group key (services.proxmox-ve.runtime.groups.<name>) or a literal group id.";
  };

  # API token -> owning user. A managed user key or a literal user id.
  tokenUserRef = {
    attr = "user_id";
    targets = [
      {
        collection = "users";
        field = "user_id";
      }
    ];
    managedOnly = false;
    required = true;
    description = "User the token belongs to: the key of a managed user (services.proxmox-ve.runtime.users.<name>), or a literal user id (\"user@realm\").";
  };

  # -- VM nested option groups -----------------------------------------------
  # MaxItems:1 provider blocks are single submodules (`oSub`) listed in
  # `blockAttrs` so the renderer wraps them to a one-element list; unbounded
  # blocks are `oListSub`; `network_device` is a list-of-object *attribute*.

  networkDeviceOpts = {
    bridge = oStr "Network bridge the interface is attached to (e.g. \"vmbr0\").";
    disconnected = oBool "Whether to disconnect the interface (link down).";
    enabled = oBool "Whether the interface is enabled.";
    firewall = oBool "Whether the Proxmox firewall is enabled on the interface.";
    mac_address = oStr "MAC address; generated by Proxmox when unset.";
    model = oStr "Device model (\"virtio\", \"e1000\", \"rtl8139\", \"vmxnet3\").";
    mtu = oInt "Interface MTU.";
    queues = oInt "Number of packet queues (virtio only).";
    rate_limit = oInt "Rate limit in megabytes per second.";
    trunks = oStr "VLAN trunks passed through to the guest (\";\"-separated VLAN ids).";
    vlan_id = oInt "VLAN tag for the interface.";
  };

  vmDiskOpts = {
    aio = oStr "Async I/O mode (\"native\", \"threads\", \"io_uring\").";
    backup = oBool "Whether the disk is included in backups.";
    cache = oStr "Cache mode (\"none\", \"writethrough\", \"writeback\", \"unsafe\", \"directsync\").";
    datastore_id = oStr "Datastore (storage) the disk lives on (e.g. \"local-lvm\").";
    discard = oStr "Discard/TRIM behaviour (\"on\", \"ignore\").";
    file_format = oStr "Disk image format (\"raw\", \"qcow2\", \"vmdk\").";
    file_id = oStr "File id of an image to use as the disk (imports via the API).";
    import_from = oStr "Datastore volume id of an image to import as the disk (via the API, no SSH).";
    interface = rStr "Disk interface and index (e.g. \"scsi0\", \"virtio0\", \"sata0\").";
    iothread = oBool "Whether a dedicated I/O thread backs the disk (virtio-scsi/virtio-blk).";
    queues = oInt "Number of queues (virtio-scsi single).";
    replicate = oBool "Whether the disk is included in replication jobs.";
    serial = oStr "Disk serial number exposed to the guest.";
    size = oInt "Disk size in gigabytes.";
    ssd = oBool "Whether the disk is presented to the guest as an SSD.";
    speed = oSub {
      iops_read = oInt "Maximum read I/O operations per second.";
      iops_read_burstable = oInt "Maximum burstable read IOPS.";
      iops_write = oInt "Maximum write I/O operations per second.";
      iops_write_burstable = oInt "Maximum burstable write IOPS.";
      read = oInt "Maximum read speed in megabytes per second.";
      read_burstable = oInt "Maximum burstable read speed (MB/s).";
      write = oInt "Maximum write speed in megabytes per second.";
      write_burstable = oInt "Maximum burstable write speed (MB/s).";
    } "Per-disk I/O throttling limits.";
  };

  vmInitializationOpts = {
    datastore_id = oStr "Datastore the cloud-init drive is created on.";
    file_format = oStr "Cloud-init drive format.";
    interface = oStr "Interface the cloud-init drive is attached to (e.g. \"ide2\").";
    meta_data_file_id = oStr "File id of a cloud-init meta-data snippet.";
    network_data_file_id = oStr "File id of a cloud-init network-data snippet.";
    user_data_file_id = oStr "File id of a cloud-init user-data snippet.";
    vendor_data_file_id = oStr "File id of a cloud-init vendor-data snippet.";
    type = oStr "Cloud-init provider (\"nocloud\", \"configdrive2\").";
    upgrade = oBool "Whether cloud-init runs a package upgrade on first boot.";
    dns = oSub {
      domain = oStr "DNS search domain.";
      servers = oListStr "DNS server addresses.";
    } "Cloud-init DNS configuration.";
    ip_config = oListSub {
      ipv4 = oSub {
        address = oStr "IPv4 address in CIDR notation, or \"dhcp\".";
        gateway = oStr "IPv4 default gateway.";
      } "IPv4 configuration for this interface.";
      ipv6 = oSub {
        address = oStr "IPv6 address in CIDR notation, or \"dhcp\"/\"auto\".";
        gateway = oStr "IPv6 default gateway.";
      } "IPv6 configuration for this interface.";
    } "Per-interface cloud-init IP configuration (index matches network_device order).";
    user_account = oSub {
      keys = oListStr "SSH public keys authorised for the default user.";
      username = oStr "Default user created by cloud-init.";
      password = oStr "Password for the default user. Prefer `passwordFile` to keep it out of the world-readable store.";
      passwordFile = oStr "Runtime path to a file holding the cloud-init user password (loaded via systemd LoadCredential=; never copied to the store). Mutually exclusive with `password`.";
    } "Cloud-init default user account.";
  };

  vmResourceType = {
    type = "proxmox_virtual_environment_vm";
    prefix = "vm";
    nameAttr = "name";
    refs.pool = poolRef;
    description = "Proxmox QEMU/KVM virtual machines, keyed by VM name.";
    # MaxItems:1 blocks wrapped to a one-element list for Terraform-JSON.
    blockAttrs = [
      "agent"
      "agent.wait_for_ip"
      "amd_sev"
      "audio_device"
      "cdrom"
      "clone"
      "cpu"
      "disk.speed"
      "efi_disk"
      "initialization"
      "initialization.dns"
      "initialization.ip_config.ipv4"
      "initialization.ip_config.ipv6"
      "initialization.user_account"
      "memory"
      "operating_system"
      "smbios"
      "startup"
      "tpm_state"
      "vga"
      "watchdog"
    ];
    attrs = {
      node_name = rStr "Cluster node the VM runs on.";
      name = oStr "VM name. Defaults to the attribute key.";
      vm_id = oInt "Numeric VM id; allocated by Proxmox when unset.";
      description = oStr "Free-form description shown in the UI.";
      tags = oListStr "Tags attached to the VM.";
      acpi = oBool "Whether ACPI is enabled.";
      bios = oStr "Firmware (\"seabios\" or \"ovmf\").";
      boot_order = oListStr "Boot device order (disk/interface ids, e.g. [ \"scsi0\" \"net0\" ]).";
      keyboard_layout = oStr "Keyboard layout (e.g. \"en-us\").";
      kvm_arguments = oStr "Extra raw arguments passed to KVM.";
      machine = oStr "QEMU machine type (e.g. \"q35\", \"pc\").";
      hotplug = oStr "Comma-separated hotplug features (e.g. \"network,disk,usb\").";
      mac_addresses = oListStr "MAC addresses for the network interfaces (index-aligned).";
      migrate = oBool "Whether to migrate the VM on apply instead of recreating it.";
      on_boot = oBool "Whether the VM starts automatically on node boot.";
      protection = oBool "Whether deletion/disk-removal protection is enabled.";
      reboot = oBool "Whether to reboot the VM after creation.";
      reboot_after_update = oBool "Whether to reboot the VM after an in-place config update.";
      scsi_hardware = oStr "SCSI controller model (e.g. \"virtio-scsi-single\").";
      started = oBool "Whether the VM should be running.";
      stop_on_destroy = oBool "Whether to hard-stop (vs. shut down) the VM on destroy.";
      tablet_device = oBool "Whether a USB tablet pointer is attached.";
      template = oBool "Whether the VM is a template.";
      delete_unreferenced_disks_on_destroy = oBool "Whether to delete disks no longer referenced by config on destroy.";
      purge_on_destroy = oBool "Whether to purge the VM from all cluster configs on destroy.";
      hook_script_file_id = oStr "File id of a hook script run on VM lifecycle events.";
      timeout_create = oInt "Timeout (seconds) for creating the VM.";
      timeout_clone = oInt "Timeout (seconds) for cloning the VM.";
      timeout_migrate = oInt "Timeout (seconds) for migrating the VM.";
      timeout_move_disk = oInt "Timeout (seconds) for moving a disk.";
      timeout_reboot = oInt "Timeout (seconds) for rebooting the VM.";
      timeout_shutdown_vm = oInt "Timeout (seconds) for shutting the VM down.";
      timeout_start_vm = oInt "Timeout (seconds) for starting the VM.";
      timeout_stop_vm = oInt "Timeout (seconds) for stopping the VM.";
      network_device = oListSub networkDeviceOpts "Network interfaces, in order (net0, net1, ...).";
      disk = oListSub vmDiskOpts "Disks attached to the VM.";
      cdrom = oSub {
        enabled = oBool "Whether the CD-ROM drive is enabled.";
        file_id = oStr "File id of the ISO to mount (or \"cdrom\"/\"none\").";
        interface = oStr "Interface the CD-ROM is attached to (e.g. \"ide3\").";
      } "Optional CD-ROM drive.";
      cpu = oSub {
        affinity = oStr "Host CPU cores the VM is pinned to (e.g. \"0-3\").";
        architecture = oStr "CPU architecture (\"x86_64\", \"aarch64\"; root-only).";
        cores = oInt "Number of cores per socket.";
        flags = oListStr "CPU flags (e.g. [ \"+aes\" ]).";
        hotplugged = oInt "Number of hotplugged vCPUs.";
        limit = oInt "CPU limit (percent of one core; 0 = unlimited).";
        numa = oBool "Whether NUMA is enabled.";
        sockets = oInt "Number of CPU sockets.";
        type = oStr "CPU type (\"host\", \"kvm64\", \"x86-64-v2-AES\", ...).";
        units = oInt "CPU weight for the scheduler.";
      } "CPU configuration.";
      memory = oSub {
        dedicated = oInt "Dedicated memory in megabytes.";
        floating = oInt "Floating (ballooning minimum) memory in megabytes.";
        shared = oInt "Shared memory in megabytes.";
        hugepages = oStr "Hugepage size (\"2\", \"1024\", \"any\").";
        keep_hugepages = oBool "Whether to keep hugepages after VM shutdown.";
      } "Memory configuration.";
      agent = oSub {
        enabled = oBool "Whether the QEMU guest agent is expected to run.";
        timeout = oStr "Timeout for agent operations (Go duration, e.g. \"15m\").";
        trim = oBool "Whether to run fstrim after clone/migrate.";
        type = oStr "Agent communication channel (\"virtio\", \"isa\").";
        wait_for_ip = oSub {
          disabled = oBool "Whether to skip waiting for an IP address.";
          ipv4 = oBool "Whether to wait for an IPv4 address.";
          ipv6 = oBool "Whether to wait for an IPv6 address.";
        } "Behaviour when waiting for the agent to report an IP.";
      } "QEMU guest agent configuration.";
      initialization = oSub vmInitializationOpts "Cloud-init configuration.";
      operating_system = oSub {
        type = oStr "Guest OS type hint (\"l26\", \"win11\", \"other\", ...).";
      } "Operating-system hints.";
      vga = oSub {
        clipboard = oStr "Clipboard mode (\"vnc\").";
        memory = oInt "Video memory in megabytes.";
        type = oStr "Display type (\"std\", \"qxl\", \"virtio\", \"serial0\", ...).";
      } "Display adapter configuration.";
      efi_disk = oSub {
        datastore_id = oStr "Datastore the EFI vars disk lives on.";
        file_format = oStr "EFI vars disk format.";
        pre_enrolled_keys = oBool "Whether Secure Boot keys are pre-enrolled.";
        type = oStr "OVMF EFI type (\"2m\", \"4m\").";
      } "OVMF EFI variables disk (required for OVMF/Secure Boot).";
      tpm_state = oSub {
        datastore_id = oStr "Datastore the TPM state disk lives on.";
        version = oStr "TPM version (\"v1.2\", \"v2.0\").";
      } "Virtual TPM state disk.";
      smbios = oSub {
        family = oStr "SMBIOS system family.";
        manufacturer = oStr "SMBIOS manufacturer.";
        product = oStr "SMBIOS product name.";
        serial = oStr "SMBIOS serial number.";
        sku = oStr "SMBIOS SKU.";
        uuid = oStr "SMBIOS UUID; generated by Proxmox when unset.";
        version = oStr "SMBIOS version.";
      } "SMBIOS (type 1) settings.";
      startup = oSub {
        order = oInt "Startup order (lower boots first).";
        up_delay = oInt "Delay (seconds) after this VM before starting the next.";
        down_delay = oInt "Delay (seconds) after shutting this VM down.";
      } "Boot/shutdown ordering.";
      watchdog = oSub {
        action = oStr "Action on watchdog timeout (\"reset\", \"poweroff\", \"pause\", ...).";
        enabled = oBool "Whether the watchdog device is enabled.";
        model = oStr "Watchdog model (\"i6300esb\", \"ib700\").";
      } "Hardware watchdog device.";
      audio_device = oSub {
        device = oStr "Audio device model (\"intel-hda\", \"AC97\", \"ich9-intel-hda\").";
        driver = oStr "Backend driver (\"spice\", \"none\").";
        enabled = oBool "Whether the audio device is enabled.";
      } "Emulated audio device.";
      amd_sev = oSub {
        type = oStr "SEV type (\"std\", \"es\", \"snp\").";
        allow_smt = oBool "Whether SMT is allowed with SEV-SNP.";
        kernel_hashes = oBool "Whether to add kernel hashes to the measurement.";
        no_debug = oBool "Whether to disable debugging of the guest.";
        no_key_sharing = oBool "Whether to disable key sharing with other guests.";
      } "AMD SEV memory encryption.";
      serial_device = oListSub {
        device = oStr "Serial device backend (\"socket\", or a host tty path).";
      } "Serial devices (serial0..serial3).";
      usb = oListSub {
        host = oStr "Host USB device (\"vendor:product\" or bus-port), or \"spice\".";
        mapping = oStr "Name of a mapped USB device to pass through.";
        usb3 = oBool "Whether the device is attached as USB 3.";
      } "USB passthrough devices.";
      hostpci = oListSub {
        device = rStr "PCI(e) device slot in the VM (e.g. \"hostpci0\").";
        id = oStr "Host PCI device id (\"0000:01:00.0\"), or empty when using `mapping`.";
        mapping = oStr "Name of a mapped PCI device to pass through.";
        mdev = oStr "Mediated device type for vGPU passthrough.";
        pcie = oBool "Whether to expose the device as PCIe (q35 only).";
        rombar = oBool "Whether the ROM BAR is visible to the guest.";
        rom_file = oStr "ROM file (relative to /usr/share/kvm) for the device.";
        xvga = oBool "Whether the device is the primary VGA (vGPU).";
      } "PCI(e) passthrough devices.";
      virtiofs = oListSub {
        mapping = rStr "Name of a mapped directory to share.";
        cache = oStr "Cache mode (\"auto\", \"always\", \"never\", \"metadata\").";
        direct_io = oBool "Whether to use direct I/O.";
        expose_acl = oBool "Whether to expose POSIX ACLs to the guest.";
        expose_xattr = oBool "Whether to expose extended attributes to the guest.";
      } "virtio-fs directory shares.";
      numa = oListSub {
        cpus = rStr "Guest vCPUs in this NUMA node (e.g. \"0-3\").";
        device = rStr "NUMA device name (e.g. \"numa0\").";
        memory = rInt "Memory in megabytes for this NUMA node.";
        hostnodes = oStr "Host NUMA nodes the memory is bound to.";
        policy = oStr "Memory allocation policy (\"preferred\", \"bind\", \"interleave\").";
      } "Custom NUMA topology.";
      rng = oListSub {
        source = rStr "Entropy source device (\"/dev/urandom\", \"/dev/random\", \"/dev/hwrng\").";
        max_bytes = oInt "Max bytes injected per period.";
        period = oInt "Injection period in milliseconds.";
      } "VirtIO RNG (entropy) devices.";
      clone = oSub {
        vm_id = rInt "Source VM/template id to clone from.";
        datastore_id = oStr "Target datastore for the clone's disks.";
        full = oBool "Whether to make a full (vs. linked) clone.";
        node_name = oStr "Source node when cloning across nodes.";
        retries = oInt "Number of clone retries.";
      } "Clone the VM from an existing VM or template.";
    };
  };

  # -- resource surface -------------------------------------------------------
  # Per resource:
  #   type            the `proxmox_virtual_environment_*` resource type
  #   prefix          unique Terraform label prefix
  #   nameAttr        attribute defaulted from the collection key (or null)
  #   refs            parent links resolved against managed siblings
  #   secrets         top-level secret attrs gaining an `<attr>File` form
  #   requiredAttrs   collection attrs that must be present and non-empty
  #   blockAttrs      MaxItems:1 blocks to wrap as one-element lists
  #   attrs           the settable attributes, each a typed option (no freeform)
  resourceTypes = {
    vms = vmResourceType;

    download_files = {
      type = "proxmox_download_file";
      prefix = "download";
      nameAttr = null;
      refs = { };
      description = "Files (ISOs, cloud images, container templates) downloaded by the node to a datastore, keyed by an arbitrary label. Uses the Proxmox API — no SSH.";
      attrs = {
        content_type = rStr "Datastore content type (\"iso\", \"vztmpl\", \"import\").";
        datastore_id = rStr "Datastore the file is downloaded to (e.g. \"local\").";
        node_name = rStr "Node that performs the download.";
        url = rStr "URL the file is fetched from.";
        file_name = oStr "Name the file is stored under (derived from the URL when unset).";
        checksum = oStr "Expected checksum of the downloaded file.";
        checksum_algorithm = oStr "Checksum algorithm (\"md5\", \"sha1\", \"sha256\", \"sha512\", ...).";
        decompression_algorithm = oStr "Decompress the download with this algorithm (\"gz\", \"lzo\", \"zst\", \"bz2\").";
        overwrite = oBool "Whether to re-download when the local checksum mismatches.";
        overwrite_unmanaged = oBool "Whether to overwrite a pre-existing file of the same name not managed here.";
        upload_timeout = oInt "Download timeout in seconds.";
        verify = oBool "Whether to verify the TLS certificate of the download URL.";
      };
    };

    files = {
      type = "proxmox_virtual_environment_file";
      prefix = "file";
      nameAttr = null;
      refs = { };
      blockAttrs = [
        "source_file"
        "source_raw"
      ];
      description = "Files uploaded to a datastore, keyed by an arbitrary label. Note: snippets and `source_file.path` uploads require the provider's SSH block (see README).";
      attrs = {
        datastore_id = rStr "Datastore the file is uploaded to.";
        node_name = rStr "Node the file is uploaded to.";
        content_type = oStr "Content type (\"iso\", \"vztmpl\", \"snippets\", \"import\"). Inferred from the file name when unset.";
        file_mode = oStr "File mode (octal string, e.g. \"0700\") for snippet uploads.";
        overwrite = oBool "Whether to overwrite an existing file of the same name.";
        timeout_upload = oInt "Upload timeout in seconds.";
        upload_mode = oStr "Upload mechanism (\"pve\" for the API, \"pve-scp\").";
        source_file = oSub {
          path = rStr "Local or remote path of the source file.";
          checksum = oStr "Expected checksum of the source file.";
          file_name = oStr "Name the file is stored under.";
          changed = oBool "Force re-upload by toggling this when the source changes out of band.";
          insecure = oBool "Whether to skip TLS verification when the path is an https URL.";
          min_tls = oStr "Minimum TLS version when the path is an https URL.";
        } "Upload from an existing file (path or URL).";
        source_raw = oSub {
          file_name = rStr "Name the file is stored under.";
          data = oStr "Inline file contents. Prefer `dataFile` when the content embeds secrets.";
          dataFile = oStr "Runtime path to a file whose contents become `data` (loaded via systemd LoadCredential=; never copied to the store). Mutually exclusive with `data`.";
          resize = oInt "Resize the created volume to this many bytes.";
        } "Upload inline content generated in Nix.";
      };
    };

    pools = {
      type = "proxmox_virtual_environment_pool";
      prefix = "pool";
      nameAttr = "pool_id";
      refs = { };
      description = "Resource pools, keyed by pool id.";
      attrs = {
        pool_id = oStr "Pool identifier. Defaults to the attribute key.";
        comment = oStr "Free-form comment.";
      };
    };

    roles = {
      type = "proxmox_virtual_environment_role";
      prefix = "role";
      nameAttr = "role_id";
      refs = { };
      requiredAttrs = [ "privileges" ];
      description = "Access-control roles, keyed by role id.";
      attrs = {
        role_id = oStr "Role identifier. Defaults to the attribute key.";
        privileges = rListStr "Privileges granted by the role (e.g. [ \"VM.Allocate\" \"Datastore.AllocateSpace\" ]).";
      };
    };

    groups = {
      type = "proxmox_virtual_environment_group";
      prefix = "group";
      nameAttr = "group_id";
      refs = { };
      description = "Access-control groups, keyed by group id.";
      attrs = {
        group_id = oStr "Group identifier. Defaults to the attribute key.";
        comment = oStr "Free-form comment.";
      };
    };

    users = {
      type = "proxmox_virtual_environment_user";
      prefix = "user";
      nameAttr = "user_id";
      refs.groups = userGroupsRef;
      secrets = [ "password" ];
      description = "Access-control users, keyed by user id (\"user@realm\").";
      attrs = {
        user_id = oStr "User identifier (\"user@realm\"). Defaults to the attribute key.";
        password = oStr "User password. Prefer `passwordFile` to keep it out of the world-readable store.";
        comment = oStr "Free-form comment.";
        email = oStr "Email address.";
        enabled = oBool "Whether the account is enabled.";
        expiration_date = oStr "Account expiry as an RFC 3339 timestamp.";
        first_name = oStr "First name.";
        last_name = oStr "Last name.";
        keys = oStr "Two-factor authentication keys.";
      };
    };

    acls = {
      type = "proxmox_acl";
      prefix = "acl";
      nameAttr = null;
      refs = {
        role = aclRoleRef;
        user = aclUserRef;
        group = aclGroupRef;
      };
      description = "Access-control list entries binding a role to a user/group/token at a path, keyed by an arbitrary label.";
      attrs = {
        path = rStr "Access-control path the entry applies to (e.g. \"/\", \"/vms/100\", \"/storage/local\").";
        propagate = oBool "Whether the entry propagates to child paths.";
        token_id = oStr "Grant the role to this API token id (\"user@realm!tokenname\"). Exactly one of user/group/token_id.";
      };
    };

    user_tokens = {
      type = "proxmox_user_token";
      prefix = "token";
      nameAttr = "token_name";
      refs.user = tokenUserRef;
      description = "API tokens for a user, keyed by token name. The generated secret is computed by Proxmox and only lives in Terraform state.";
      attrs = {
        token_name = oStr "Token name. Defaults to the attribute key.";
        comment = oStr "Free-form comment.";
        expiration_date = oStr "Token expiry as an RFC 3339 timestamp.";
        privileges_separation = oBool "Whether the token has its own (separated) privileges rather than the user's.";
      };
    };
  };

  # cfg -> { config; credentials; }. `config` carries no secrets: the token/
  # password and every `<attr>File` become sensitive tf variables fed from
  # TF_VAR_<id> at apply time.
  proxmoxTfConfig = genlib.mkTfConfig {
    inherit resourceTypes providerVersion tokenVar;
    providerName = "proxmox";
    providerSource = "bpg/proxmox";
    runtimePrefix = "services.proxmox-ve.runtime";
    # API-token auth when the operator supplies a token file; otherwise
    # username/password. `username`, `endpoint` and `insecure` are not secret,
    # so they are emitted literally. The optional `ssh` block is rendered as a
    # one-element list (MaxItems:1) and reuses the provider password by default.
    providerBlock =
      cfg:
      let
        auth =
          if (cfg.apiTokenFile or null) != null then
            { api_token = "\${var.${tokenVar}}"; }
          else
            {
              username = cfg.username or "root@pam";
              password = "\${var.${tokenVar}}";
            };
        ssh = cfg.ssh or null;
        sshBlock = lib.optionalAttrs (ssh != null) {
          ssh = [
            (genlib.cleanNulls {
              username = ssh.username or "root";
              agent = ssh.agent or false;
              agent_socket = ssh.agentSocket or null;
            })
          ];
        };
      in
      {
        inherit (cfg) endpoint;
        insecure = cfg.insecure or true;
      }
      // auth
      // sshBlock;
  };
in
{
  inherit resourceTypes proxmoxTfConfig;
  resourceOptions = genlib.resourceOptions resourceTypes;
  mkReconcileService = args: genlib.mkReconcileService (args // { inherit executor tokenVar; });
}
