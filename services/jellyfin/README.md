# Jellyfin pairing

Declaratively manage a [Jellyfin](https://jellyfin.org/) media server's
**runtime state** (users, libraries, plugins, plugin/system/networking/encoding
configuration, scheduled-task triggers, …) from NixOS, on top of the upstream
`services.jellyfin` module.

[provider]: https://registry.terraform.io/providers/ThePhaseless/jellyfin/latest/docs

## Installation

### Include the module

Add this flake as an input and import its `nixosModules.jellyfin` into your
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
          declarative-runtime.nixosModules.jellyfin
          ./host.nix
        ];
      };
    };
}
```

## Authentication and bootstrap

A fresh Jellyfin has not completed its startup wizard, so there is no API key to
authenticate with yet. The pairing handles this the way the provider intends:

- **Default (zero setup).** Leave `apiKeyFile` and `adminPasswordFile` unset. A
  companion oneshot mints a random `adminUsername` password once (persisted
  under `/var/lib`), and the provider uses it to create the initial admin,
  complete the wizard, and authenticate — so the instance converges from a cold
  boot with no operator secret at all.
- **Operator-supplied password.** Set `adminPasswordFile` to a host path holding
  the `adminUsername` password (via sops-nix/agenix). Used for the same
  username/password flow, but with a password you control.
- **API key.** Set `apiKeyFile` to a host path holding an administrative API key
  for an **already-configured** instance. The provider then authenticates with
  the key and does not touch the wizard.

## Configuration examples

Set `services.jellyfin.enable = true` (the module asserts it) and declare the
runtime state under `services.jellyfin.runtime`. Each entry's attributes are
**typed options** named after the provider's snake_case attributes (validated at
`nix flake check`; an unknown name or wrong type is a build error). Parent links
name another managed entry by its key, which resolves to a correctly ordered
Terraform reference.

### Users and libraries

```nix
{
  services.jellyfin = {
    enable = true;

    runtime = {
      enable = true;

      # The server display name (system configuration singleton).
      system_configuration.main.server_name = "Home Jellyfin";

      libraries.movies = {
        collection_type = "movies";
        paths = [ "/srv/media/movies" ];
      };
      libraries.shows = {
        collection_type = "tvshows";
        paths = [ "/srv/media/shows" ];
      };

      # `password` (literal) lands in the world-readable Nix store; use
      # `passwordFile` (a host path) for a real secret -- see the security note.
      users.alice = {
        passwordFile = "/run/secrets/jellyfin-alice";
        is_administrator = false;
      };
    };
  };
}
```

### Plugins and plugin configuration

`repository` names a managed `plugin_repositories` entry (resolved to its URL,
and ordered after it); `plugin` names a managed `plugins` entry (resolved to the
GUID Jellyfin assigns at install time, so configuration is applied after the
plugin is installed). Installing a plugin downloads it, so the server needs
network access to the repository.

```nix
{
  services.jellyfin = {
    enable = true;

    runtime = {
      enable = true;

      plugin_repositories.stable = {
        url = "https://repo.jellyfin.org/files/plugin/manifest.json";
        enabled = true;
      };

      # `repository` -> ${jellyfin_plugin_repository.<label>.url}
      plugins.sso_auth = {
        version = "3.5.2.0";
        repository = "stable";
      };

      # `plugin` -> ${jellyfin_plugin.<label>.id}. Keep the OIDC secret out of
      # the store with `configuration_jsonFile` -- see the security note.
      plugin_configurations.sso = {
        plugin = "sso_auth";
        configuration_jsonFile = "/run/secrets/jellyfin-sso-config.json";
      };
    };
  };
}
```

### Raw configuration singletons and scheduled tasks

The networking/encoding/branding/metadata/Live TV configuration resources take a
raw JSON blob, matching the provider's universal-configuration approach. Set
scheduled-task triggers by the task's id.

```nix
{
  services.jellyfin = {
    enable = true;

    runtime = {
      enable = true;

      networking_configuration.main.configuration_json = builtins.toJSON {
        EnableRemoteAccess = false;
        InternalHttpPort = 8096;
      };

      # Run the "Scan Media Library" task every 12h (ticks are 100ns units).
      scheduled_tasks.library_scan = {
        task_id = "7738148ffcd07979c7ceb148e06b3aed";
        triggers_json = builtins.toJSON [
          {
            Type = "IntervalTrigger";
            IntervalTicks = 432000000000;
          }
        ];
      };
    };
  };
}
```

## Module options (`services.jellyfin.runtime`)

| Option              | Type        | Default                 | Purpose                                                                                                       |
| ------------------- | ----------- | ----------------------- | ------------------------------------------------------------------------------------------------------------- |
| `enable`            | bool        | `false`                 | Turn on the reconciler.                                                                                       |
| `baseUrl`           | str         | `http://localhost:8096` | Jellyfin API base URL the provider targets.                                                                   |
| `apiKeyFile`        | null or str | `null`                  | Host path to an admin API key (read via systemd `LoadCredential=`, never stored). Set for an existing server. |
| `adminUsername`     | str         | `"admin"`               | Admin account the provider authenticates as / creates when `apiKeyFile` is unset.                             |
| `adminPasswordFile` | null or str | `null`                  | Host path to the `adminUsername` password. `null` ⇒ the module mints and persists a random one at boot.       |

Plus one collection option per provider resource (next section).

## Resources

Every [`ThePhaseless/jellyfin`][provider] resource is exposed as a collection
keyed by an arbitrary handle:

| Option                     | `jellyfin_*` resource      | Key defaults | Reference inputs                 |
| -------------------------- | -------------------------- | ------------ | -------------------------------- |
| `users`                    | `user`                     | `name`       | —                                |
| `libraries`                | `library`                  | `name`       | —                                |
| `api_keys`                 | `api_key`                  | `app_name`   | —                                |
| `plugin_repositories`      | `plugin_repository`        | `name`       | —                                |
| `plugins`                  | `plugin`                   | `name`       | `repository` → plugin_repository |
| `plugin_configurations`    | `plugin_configuration`     | —            | `plugin` → plugin                |
| `scheduled_tasks`          | `scheduled_task`           | —            | —                                |
| `system_configuration`     | `system_configuration`     | —            | — (singleton)                    |
| `networking_configuration` | `networking_configuration` | —            | — (singleton)                    |
| `encoding_configuration`   | `encoding_configuration`   | —            | — (singleton)                    |
| `branding_configuration`   | `branding_configuration`   | —            | — (singleton)                    |
| `metadata_configuration`   | `metadata_configuration`   | —            | — (singleton)                    |
| `livetv_configuration`     | `livetv_configuration`     | —            | — (singleton)                    |

The `*_configuration` singletons manage one server-wide object each; declare a
single entry (the key is only a Terraform label).

## Security note

Secret-valued _resource_ attributes — `password` (`users`) and
`configuration_json` (`plugin_configurations`) — each accept an `<attr>File`
form (`passwordFile`, `configuration_jsonFile`) that takes a **host file path**
instead of the literal value. The file is read at apply time via systemd
`LoadCredential=` into a sensitive Terraform variable and **never enters the Nix
store**; the generated `.tf.json` holds only a `${var.…}` reference (the same
mechanism that protects the provider admin credential). Prefer it for any real
secret:

```nix
services.jellyfin.runtime.users.alice = {
  passwordFile = "/run/secrets/jellyfin-alice"; # host path, not a store path
};
```

Setting the attribute _literally_ (e.g. `password = "…"`) still works, but
renders the value verbatim into the **world-readable** `.tf.json` store path —
use it only for non-secret values. `<attr>` and `<attr>File` are mutually
exclusive.
