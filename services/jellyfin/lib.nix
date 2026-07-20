# jellyfin-provider specifics: executor, resource types, provider block.
# shared helpers (option helpers, renderer, reconciler) live in modules/lib.
#
# The whole ThePhaseless/jellyfin resource surface is modelled below as strictly
# typed option collections (no freeformType), derived from the provider schema
# (`tofu providers schema -json`); computed/output-only attributes are omitted.
{ pkgs }:
let
  genlib = import ../../modules/lib { inherit pkgs; };
  inherit (genlib)
    oStr
    oBool
    rStr
    rListStr
    ;

  provider = import ./pkg.nix { inherit pkgs; };
  providerVersion = provider.version;

  # Single sensitive tf variable. It carries the API key when the operator
  # supplies `apiKeyFile`, otherwise the admin password used for the provider's
  # username/password authentication (and first-boot wizard bootstrap). The
  # provider block below references whichever field matches the auth mode; the
  # variable itself is always fed from LoadCredential as TF_VAR_jellyfin_token.
  tokenVar = "jellyfin_token";

  executor = pkgs.opentofu.withPlugins (_: [ provider ]);

  # plugin -> plugin_repository link. The user names the key of a managed
  # repository (its `url` is interpolated) or supplies a literal repository URL.
  # This both fills `repository_url` and orders plugin installation after the
  # repository is registered.
  pluginRepoRef = {
    attr = "repository_url";
    targets = [
      {
        collection = "plugin_repositories";
        field = "url";
      }
    ];
    managedOnly = false;
    required = true;
    description = "Repository the plugin is installed from: the key of a managed plugin_repository (services.jellyfin.runtime.plugin_repositories.<name>), or a literal manifest URL.";
  };

  # plugin_configuration -> plugin link. Jellyfin identifies a plugin by an
  # opaque GUID assigned at install time, which the user cannot know up front;
  # naming the managed plugin key resolves it to `${jellyfin_plugin.<label>.id}`
  # (and orders configuration after installation). A literal GUID is also
  # accepted for a plugin managed outside this pairing.
  pluginRef = {
    attr = "plugin_id";
    targets = [
      {
        collection = "plugins";
        field = "id";
      }
    ];
    managedOnly = false;
    required = true;
    description = "Plugin to configure: the key of a managed plugin (services.jellyfin.runtime.plugins.<name>), or a literal plugin GUID.";
  };

  # Helper: the five write-only "singleton" configuration resources share an
  # identical single-attribute shape (a required raw configuration_json blob).
  singletonConfig = type: prefix: description: {
    inherit type prefix description;
    nameAttr = null;
    refs = { };
    attrs = {
      configuration_json = rStr "The configuration as a JSON string (merged with the server's existing configuration).";
    };
  };

  # The full ThePhaseless/jellyfin resource surface. Per resource:
  #   type            the `jellyfin_*` resource type
  #   prefix          unique Terraform label prefix
  #   nameAttr        attribute defaulted from the collection key (or null)
  #   refs            parent links resolved to references against managed siblings
  #   secrets         secret-valued attributes gaining an `<attr>File` form
  #   requiredSecrets secrets the provider requires (one of `<attr>`/`<attr>File`)
  #   requiredAttrs   collection-typed attrs that must be set non-empty
  #   attrs           the settable attributes, each a typed option (no freeform)
  #   importId        (optional) declared-state -> provider import id (see
  #                   modules/lib mkImportEntries); omitted where the id is a
  #                   server-assigned GUID/token or the resource is a singleton
  resourceTypes = {
    users = {
      type = "jellyfin_user";
      prefix = "user";
      nameAttr = "name";
      refs = { };
      secrets = [ "password" ];
      description = "Jellyfin users, keyed by username.";
      attrs = {
        name = oStr "The username. Defaults to the attribute key.";
        password = oStr "The user password. Prefer `passwordFile` to keep it out of the world-readable store.";
        is_administrator = oBool "Whether the user is an administrator.";
        is_disabled = oBool "Whether the user is disabled.";
        enable_all_folders = oBool "Whether the user has access to all libraries.";
        policy_json = oStr "The full user policy as a JSON string, merged with the existing policy. Individual attributes like `is_administrator` take precedence over values here.";
      };
    };
    libraries = {
      type = "jellyfin_library";
      prefix = "library";
      nameAttr = "name";
      refs = { };
      # imported by library name.
      importId = ctx: ctx.item.name;
      requiredAttrs = [ "paths" ];
      description = "Jellyfin media libraries (virtual folders), keyed by library name.";
      attrs = {
        name = oStr "The library name. Defaults to the attribute key.";
        collection_type = rStr "The collection type ('movies', 'tvshows', 'music', 'books', 'homevideos', 'boxsets', 'mixed').";
        paths = rListStr "Filesystem paths that make up this library.";
        library_options_json = oStr "Library options as a JSON string, for full customisation of library settings.";
      };
    };
    api_keys = {
      type = "jellyfin_api_key";
      prefix = "api_key";
      nameAttr = "app_name";
      refs = { };
      description = "Jellyfin API keys, keyed by application name. The generated token is computed by Jellyfin and only lives in Terraform state.";
      attrs = {
        app_name = oStr "The application name for the API key. Defaults to the attribute key.";
      };
    };
    plugin_repositories = {
      type = "jellyfin_plugin_repository";
      prefix = "plugin_repo";
      nameAttr = "name";
      refs = { };
      # imported by repository name.
      importId = ctx: ctx.item.name;
      description = "Jellyfin plugin repositories, keyed by repository name.";
      attrs = {
        name = oStr "The repository name. Defaults to the attribute key.";
        url = rStr "The repository manifest URL.";
        enabled = oBool "Whether the repository is enabled.";
      };
    };
    plugins = {
      type = "jellyfin_plugin";
      prefix = "plugin";
      nameAttr = "name";
      refs.repository = pluginRepoRef;
      # imported by plugin package name (the provider also accepts a GUID).
      importId = ctx: ctx.item.name;
      description = "Jellyfin plugins installed from a repository, keyed by plugin package name. Installation downloads the package, so the server needs network access to the repository.";
      attrs = {
        name = oStr "The plugin package name. Defaults to the attribute key.";
        version = rStr "The plugin version to install.";
      };
    };
    plugin_configurations = {
      type = "jellyfin_plugin_configuration";
      prefix = "plugin_config";
      nameAttr = null;
      refs.plugin = pluginRef;
      secrets = [ "configuration_json" ];
      requiredSecrets = [ "configuration_json" ];
      description = "Jellyfin plugin configurations, keyed by an arbitrary label. Universal (JSON) configuration for any plugin, e.g. SSO-Auth.";
      attrs = {
        configuration_json = oStr "The plugin configuration as a JSON string. Prefer `configuration_jsonFile` when it embeds secrets (e.g. an OIDC client secret).";
      };
    };
    scheduled_tasks = {
      type = "jellyfin_scheduled_task";
      prefix = "scheduled_task";
      nameAttr = null;
      refs = { };
      description = "Triggers for Jellyfin scheduled tasks, keyed by an arbitrary label.";
      attrs = {
        task_id = rStr "The unique identifier of the scheduled task.";
        triggers_json = rStr "The task triggers as a JSON array string (each object: Type, TimeOfDayTicks, IntervalTicks, DayOfWeek, MaxRuntimeTicks).";
      };
    };
    system_configuration = {
      type = "jellyfin_system_configuration";
      prefix = "system_config";
      nameAttr = null;
      refs = { };
      description = "The Jellyfin system configuration singleton, keyed by an arbitrary label (only one entry is meaningful).";
      attrs = {
        server_name = oStr "The server display name.";
        configuration_json = oStr "The full system configuration as a JSON string, merged with the existing configuration.";
      };
    };
    networking_configuration =
      singletonConfig "jellyfin_networking_configuration" "networking_config"
        "The Jellyfin networking configuration singleton (HTTPS, ports, remote access, proxies, IP filtering), keyed by an arbitrary label.";
    encoding_configuration =
      singletonConfig "jellyfin_encoding_configuration" "encoding_config"
        "The Jellyfin encoding/transcoding configuration singleton, keyed by an arbitrary label.";
    branding_configuration =
      singletonConfig "jellyfin_branding_configuration" "branding_config"
        "The Jellyfin branding configuration singleton (e.g. splashscreen), keyed by an arbitrary label.";
    metadata_configuration =
      singletonConfig "jellyfin_metadata_configuration" "metadata_config"
        "The Jellyfin metadata configuration singleton, keyed by an arbitrary label.";
    livetv_configuration =
      singletonConfig "jellyfin_livetv_configuration" "livetv_config"
        "The Jellyfin Live TV configuration singleton (recording options, tuner hosts, listing providers), keyed by an arbitrary label.";
  };

  jellyfinTfConfig = genlib.mkTfConfig {
    inherit resourceTypes providerVersion tokenVar;
    providerName = "jellyfin";
    providerSource = "ThePhaseless/jellyfin";
    runtimePrefix = "services.jellyfin.runtime";
    # API key auth when the operator supplies one; otherwise username/password,
    # which the provider also uses to complete the startup wizard on a fresh
    # instance. `username` is not secret, so it is emitted literally.
    providerBlock =
      cfg:
      {
        endpoint = cfg.baseUrl;
      }
      // (
        if cfg.apiKeyFile != null then
          {
            api_key = "\${var.${tokenVar}}";
          }
        else
          {
            username = cfg.adminUsername;
            password = "\${var.${tokenVar}}";
          }
      );
  };
in
{
  inherit resourceTypes jellyfinTfConfig;
  resourceOptions = genlib.resourceOptions resourceTypes;
  mkReconcileService = args: genlib.mkReconcileService (args // { inherit executor tokenVar; });
}
