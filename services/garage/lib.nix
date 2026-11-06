# arsolitt/garagehq provider specifics: executor, resource surface, provider block.
#
# The resource surface is *derived* from the vendored provider schema
# (./provider-schema.json, parsed by ./schema.nix) via
# ../../modules/lib/tf-schema.nix. What stays hand-written is only what a schema
# cannot state: the reference graph between collections, which attribute a
# bucket's key fills, and that the type prefix differs from the provider's name.
# A provider bump that adds, removes or retypes anything is
# then an eval-time error rather than an apply-time surprise.
#
# Shared helpers (option helpers, renderer, reconciler) live in modules/lib.
{ pkgs, nix-tf-schema }:
let
  genlib = import ../../modules/lib { inherit pkgs; };
  tfSchema = import ../../modules/lib/tf-schema.nix { inherit pkgs nix-tf-schema; };

  provider = import ./pkg.nix { inherit pkgs; };
  providerVersion = provider.version;
  # provider source address; also keys the vendored provider schema.
  providerSource = "arsolitt/garagehq";
  # the resource types are `garage_*`, not `garagehq_*`.
  providerName = "garage";
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
    "RemoveBucketAlias"
    "UpdateBucket"
    "UpdateKey"
  ];
  executor = pkgs.opentofu.withPlugins (_: [ provider ]);

  # The arsolitt/garagehq resource surface. Per collection, only the facts the
  # schema does not carry (see modules/lib/tf-schema.nix for the full overlay
  # vocabulary). `scope` is null throughout: a Garage admin token is not scoped
  # per resource kind.
  generated = tfSchema.mkResourceTypes {
    schema = import ./schema.nix;
    inherit provider providerName runtimePrefix;
    source = providerSource;
    # The provider is not in the OpenTofu registry.
    docsUrl = "https://registry.terraform.io/providers/${providerSource}/${providerVersion}";
    # the sdk/v2 synthetic attribute.
    omitEverywhere = [ "id" ];
    resources = {
      bucket = {
        # A bucket gets one global alias from the provider, which is the key.
        nameAttr = "global_alias";
      };
      key = { };
      bucket_key = {
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
    unsupported = {
      admin_token = "the reconciler token comes from declarative-garage-token; with this resource that token could mint other tokens";
      cluster_layout = "declarative-garage-layout must assign the layout before the reconciler runs, because Garage needs a layout before the bucket and key resources can apply";
    };
  };
  inherit (generated) resourceTypes;

  garageTfConfig = genlib.mkTfConfig {
    inherit
      resourceTypes
      providerName
      providerVersion
      providerSource
      runtimePrefix
      tokenVar
      ;
    providerBlock =
      cfg:
      let
        url = builtins.match "(https?)://([^/]+)/?" cfg.baseUrl;
      in
      if url == null then
        throw "${runtimePrefix}.baseUrl: expected `<http|https>://<host>[:<port>]`, got `${cfg.baseUrl}`"
      else
        {
          scheme = builtins.elemAt url 0;
          host = builtins.elemAt url 1;
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
