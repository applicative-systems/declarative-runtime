# jkossis/garage provider specifics: executor, resource surface, provider block.
#
# The resource surface is *derived* from the vendored provider schema
# (./provider-schema.json, parsed by ./schema.nix) via
# ../../modules/lib/tf-schema.nix. What stays hand-written is only what a schema
# cannot state: the reference graph between collections, and which attribute a
# bucket's key fills. A provider bump that adds, removes or retypes anything is
# then an eval-time error rather than an apply-time surprise.
#
# Shared helpers (option helpers, renderer, reconciler) live in modules/lib.
{ pkgs, nix-tf-schema }:
let
  genlib = import ../../modules/lib { inherit pkgs; };
  tfSchema = import ../../modules/lib/tf-schema.nix { inherit pkgs nix-tf-schema; };

  provider = pkgs.terraform-providers.jkossis_garage;
  providerVersion = provider.version;
  # provider source address; also keys the vendored provider schema.
  providerSource = "jkossis/garage";
  runtimePrefix = "services.garage.runtime";
  tokenVar = "garage_admin_token";
  # The admin API functions the provider calls, which is the scope of the admin
  # token the module mints. A provider bump that calls another function fails
  # the apply with 403 Forbidden, so the VM test shows it.
  adminScope = [
    "AddBucketAlias"
    "AllowBucketKey"
    "CreateBucket"
    "CreateKey"
    "DeleteBucket"
    "DeleteKey"
    "DenyBucketKey"
    "GetBucketInfo"
    "GetKeyInfo"
    "ImportKey"
    "ListBuckets"
    "RemoveBucketAlias"
    "UpdateBucket"
  ];
  executor = pkgs.opentofu.withPlugins (_: [ provider ]);

  # The jkossis/garage resource surface. Per collection, only the facts the
  # schema does not carry (see modules/lib/tf-schema.nix for the full overlay
  # vocabulary). `scope` is null throughout: a Garage admin token is not scoped
  # per resource kind.
  generated = tfSchema.mkResourceTypes {
    schema = import ./schema.nix;
    inherit provider runtimePrefix;
    source = providerSource;
    resources = {
      bucket = {
        # A bucket gets one global alias from the provider, which is the key.
        nameAttr = "global_alias";
      };
      key = { };
      bucket_permission = {
        refs = {
          bucket_id = {
            targets = [
              {
                type = "bucket";
                field = "id";
              }
            ];
            managedOnly = false;
          };
          access_key_id = {
            targets = [
              {
                type = "key";
                field = "id";
              }
            ];
            managedOnly = false;
          };
        };
      };
    };
  };
  inherit (generated) resourceTypes;

  garageTfConfig = genlib.mkTfConfig {
    inherit
      resourceTypes
      providerVersion
      providerSource
      runtimePrefix
      tokenVar
      ;
    providerName = "garage";
    providerBlock = cfg: {
      endpoint = cfg.baseUrl;
      token = "\${var.${tokenVar}}";
    };
  };
in
{
  inherit
    adminScope
    provider
    providerSource
    resourceTypes
    garageTfConfig
    ;
  # the generator's drift assertions and coverage data, for the pairing's checks
  # to force independently of any particular configuration.
  inherit (generated) checks coverage;
  resourceOptions = genlib.resourceOptions resourceTypes;
  mkReconcileService = args: genlib.mkReconcileService (args // { inherit executor tokenVar; });
}
