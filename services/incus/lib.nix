# lxc/incus provider specifics: executor, resource surface, provider block.
#
# The resource surface is *derived* from the vendored provider schema
# (./provider-schema.json, parsed by ./schema.nix) via
# ../../modules/lib/tf-schema.nix. What stays hand-written is only what a schema
# cannot state: the reference graph between collections, the odd description
# that adds a fact, and the import IDs of the objects that incus or its
# preseed make before the reconciler runs.
#
# Shared helpers (option helpers, renderer, reconciler) live in modules/lib.
{ pkgs, nix-tf-schema }:
let
  inherit (pkgs) lib;
  genlib = import ../../modules/lib { inherit pkgs; };
  tfSchema = import ../../modules/lib/tf-schema.nix { inherit pkgs nix-tf-schema; };

  provider = pkgs.terraform-providers.lxc_incus;
  providerVersion = provider.version;
  # provider source address; also keys the vendored provider schema.
  providerSource = "lxc/incus";
  # incus has no `services.incus`: its NixOS module is `virtualisation.incus`.
  runtimePrefix = "virtualisation.incus.runtime";
  executor = pkgs.opentofu.withPlugins (_: [ provider ]);

  # A reference to an object by its name. The literal fallback is for objects
  # that incus makes itself (the `default` project, say) or that a different
  # tool manages.
  nameRef = type: {
    targets = [
      {
        inherit type;
        field = "name";
      }
    ];
    managedOnly = false;
  };
  projectRef = nameRef "project" // {
    description = "Project of the object. Unset means the `default` project.";
  };
  networkRef = nameRef "network" // {
    description = "Network of the object.";
  };
  poolRef = nameRef "storage_pool" // {
    description = "Storage pool of the object.";
  };

  # The import ID of an object that the provider identifies by its project and
  # name: `[<project>/]<name>`. The provider also accepts a remote prefix, but
  # the reconciler talks to the local daemon only.
  projectScopedId = v: lib.optionalString (v ? project) "${v.project}/" + v.name;

  # The lxc/incus resource surface, keyed by resource name. Per resource, only
  # the facts the schema does not carry (see modules/lib/tf-schema.nix for the
  # full overlay vocabulary). No resource sets `scope`: the reconciler talks to
  # the local unix socket as root, which has full access.
  #
  # Profile devices refer to networks and pools by literal name: refs are top
  # level only, and a device's properties are a map. OpenTofu thus does not
  # know that a profile depends on the network or pool its devices name. When
  # the same apply creates both, the profile can come first and fail. The
  # usual case, a profile that uses a network and pool that exist already, is
  # not affected.
  generated = tfSchema.mkResourceTypes {
    schema = import ./schema.nix;
    inherit provider runtimePrefix;
    source = providerSource;
    # The provider block configures no remote: the reconciler manages the
    # local daemon only.
    omitEverywhere = [ "remote" ];
    unsupported = {
      instance = "An instance is a workload with a lifecycle of its own, not configuration of the host.";
      instance_snapshot = "A snapshot is a point-in-time copy of an instance, which is not modelled.";
      image = "An image belongs with the instances that use it, which are not modelled.";
    };
    resources = {
      certificate = {
        refs.projects = nameRef "project" // {
          description = "Projects that a restricted certificate can access.";
        };
        # The certificate is public, but a host often mints it at runtime (a
        # client key pair made at first boot, say). A `<attr>File` sibling is
        # the only way to read a file at apply time.
        extraSecrets = [ "certificate" ];
        description = "Certificates in the trust store. Give the PEM inline, or the path of a file on the host with `certificateFile`.";
      };
      cluster_group = { };
      network = {
        refs.project = projectRef;
        importId = projectScopedId;
        description = "Networks. Keys of `config` that the network computes (`ipv4.address` when not set, say) are kept, and other keys that are not in `config` are removed.";
      };
      network_acl = {
        refs.project = projectRef;
      };
      network_address_set = {
        refs.project = projectRef;
      };
      network_forward = {
        refs = {
          project = projectRef;
          network = networkRef;
        };
        description = "Network forwards. A forward is identified by its network and listen address.";
      };
      network_integration = {
        refs.project = projectRef;
      };
      network_lb = {
        refs = {
          project = projectRef;
          network = networkRef;
        };
        description = "Network load balancers. A load balancer is identified by its network and listen address.";
      };
      network_peer = {
        refs = {
          project = projectRef;
          network = networkRef;
          target_network = nameRef "network" // {
            description = "Network to peer with.";
          };
          target_project = nameRef "project" // {
            description = "Project of the network to peer with.";
          };
        };
      };
      network_zone = {
        refs.project = projectRef;
      };
      network_zone_record = {
        refs = {
          project = projectRef;
          zone = nameRef "network_zone" // {
            description = "Zone of the record.";
          };
        };
      };
      profile = {
        refs.project = projectRef;
        # Not needed for the `default` profile: the provider changes that
        # profile in place when it creates it, and resets it when it destroys
        # it.
        importId = projectScopedId;
        description = "Profiles. Devices name their networks and pools literally, so OpenTofu does not order a profile after them.";
      };
      project = {
        importId = v: v.name;
      };
      server = {
        description = "Server configuration. Set one entry at most. Only the keys in `config` are managed; other server keys are kept.";
      };
      storage_pool = {
        refs.project = projectRef;
        importId = projectScopedId;
        description = "Storage pools. Keys of `config` that the pool computes (`source`, say) are kept.";
      };
      storage_bucket = {
        refs = {
          project = projectRef;
          pool = poolRef;
        };
      };
      storage_bucket_key = {
        refs = {
          project = projectRef;
          pool = poolRef;
          storage_bucket = nameRef "storage_bucket" // {
            description = "Bucket of the key.";
          };
        };
        description = "Access keys of storage buckets. incus makes the access and secret keys; they are in the state only.";
      };
      storage_volume = {
        description = "Custom storage volumes.";
        refs = {
          project = projectRef;
          pool = poolRef;
        };
      };
    };
  };
  inherit (generated) resourceTypes;

  incusTfConfig = genlib.mkTfConfig {
    inherit
      resourceTypes
      providerVersion
      providerSource
      runtimePrefix
      ;
    providerName = "incus";
    legacyLabelPrefixes = import ./legacy-label-prefixes.nix;
    providerBlock = cfg: {
      # A directory with no `config.yml`, so that the provider uses its
      # default configuration: the `local` remote on the local unix socket.
      # The default, `$HOME/.config/incus`, can hold the remotes of an admin.
      config_dir = cfg.configDir;
    };
  };
in
{
  inherit
    provider
    providerSource
    runtimePrefix
    resourceTypes
    incusTfConfig
    ;
  # the generator's drift assertions and coverage data, for the pairing's checks
  # to force independently of any particular configuration.
  inherit (generated) checks coverage;
  resourceOptions = genlib.resourceOptions resourceTypes;
  mkReconcileService = args: genlib.mkReconcileService (args // { inherit executor; });
}
