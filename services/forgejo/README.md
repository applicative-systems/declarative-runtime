# Forgejo pairing

Declaratively manage a [Forgejo](https://forgejo.org/) instance's **runtime
state** (organizations, repositories, teams, webhooks, Actions secrets/variables,
…) from NixOS, on top of the upstream `services.forgejo` module.

[provider]: https://registry.terraform.io/providers/svalabs/forgejo/latest/docs

## Installation

### Include the module

Add this flake as an input and import its `nixosModules.forgejo` into your
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
          declarative-runtime.nixosModules.forgejo
          ./host.nix
        ];
      };
    };
}
```

## Configuration examples

Set `services.forgejo.enable = true` (the module asserts it) and declare the
runtime state under `services.forgejo.runtime`; with `tokenFile` unset the
module mints its own scoped admin token at boot, so the examples below need
nothing more to apply. Each entry's attributes are **typed options** named after
the upstream resource's snake_case attributes (validated at `nix flake check`;
an unknown name or wrong type is a build error). Parent links name another
managed entry by its key, which resolves to a correctly ordered Terraform
reference.

Those options are **derived from the provider's own schema** rather than
hand-written, so they track the pinned provider exactly — see
[Provider updates](#provider-updates).

### Organizations, repositories, and teams

Create an organization, a repository it owns, and a team inside it. `owner` and
`organization` name the managed organization by its key, so the repo and team
are applied after it.

```nix
{
  services.forgejo = {
    enable = true;

    runtime = {
      enable = true;

      organizations.acme = {
        description = "ACME Corporation";
        visibility = "public";
      };

      # `owner` names the managed organization by key -> applied after it.
      repositories.widgets = {
        owner = "acme";
        description = "Widget factory";
        private = false;
      };

      teams.engineers = {
        organization = "acme";
        description = "Engineering";
        units_map."repo.code" = "read"; # required by the provider
      };
    };
  };
}
```

### Actions variables and secrets

Configure CI inputs at organization and repository scope. `organization`
resolves to the managed org's name, while `repository` names a managed repo by
key and resolves to its numeric `id`.

```nix
{
  services.forgejo = {
    enable = true;

    runtime = {
      enable = true;

      organizations.acme.description = "ACME Corporation";
      repositories.widgets.owner = "acme";

      # String-name reference to the managed organization.
      organization_action_variables.ci_region = {
        organization = "acme";
        data = "eu-west";
      };

      # `repository` -> ${forgejo_repository.widgets.id} (a numeric reference).
      repository_action_variables.build_flag = {
        repository = "widgets";
        data = "release";
      };

      # `data` (literal) lands in the world-readable Nix store; use `dataFile`
      # (a host path) for a real secret -- see the security note.
      repository_action_secrets.registry_token = {
        repository = "widgets";
        data = "REPLACE_ME";
      };
    };
  };
}
```

### Webhooks and branch protection

Guard a repository with a delivery webhook and a protected branch. Both name the
managed repository by key (a numeric `id` reference); nested maps (`config`) and
lists (`events`) are typed and serialized as-is.

```nix
{
  services.forgejo = {
    enable = true;

    runtime = {
      enable = true;

      organizations.acme.description = "ACME Corporation";
      repositories.widgets.owner = "acme";

      repository_webhooks.ci = {
        repository = "widgets"; # -> ${forgejo_repository.widgets.id}
        type = "forgejo";
        events = [
          "push"
          "pull_request"
        ];
        active = true;
        config = {
          url = "https://ci.acme.example/forgejo-hook";
          content_type = "json";
        };
      };

      branch_protections.main = {
        repository = "widgets";
        branch_name = "main";
        enable_push = false;
        required_approvals = 1;
      };
    };
  };
}
```

## Module options (`services.forgejo.runtime`)

| Option          | Type        | Default                        | Purpose                                                                                                                                           |
| --------------- | ----------- | ------------------------------ | ------------------------------------------------------------------------------------------------------------------------------------------------- |
| `enable`        | bool        | `false`                        | Turn on the reconciler.                                                                                                                           |
| `baseUrl`       | str         | `http://localhost:<HTTP_PORT>` | Forgejo API base URL the provider targets.                                                                                                        |
| `tokenFile`     | null or str | `null`                         | Host path to an admin API token (read via systemd `LoadCredential=`, never stored). `null` ⇒ the module mints its own scoped admin token at boot. |
| `adminUsername` | str         | `"declarative-forgejo"`        | Admin account the bootstrap oneshot creates/uses. Ignored when `tokenFile` is set.                                                                |

Plus one collection option per provider resource (next section).

## Resources

Every [`svalabs/forgejo`][provider] resource is exposed as a collection keyed by
an arbitrary handle. What each collection accepts comes from the vendored
provider schema, not from this table: the authoritative option list is

```sh
nix build .#checks.x86_64-linux.forgejo-options-doc   # every option, typed
nix build .#checks.x86_64-linux.forgejo-schema-coverage # what is covered
```

| Option                          | `forgejo_*` resource           | Key defaults | Reference inputs                   |
| ------------------------------- | ------------------------------ | ------------ | ---------------------------------- |
| `organizations`                 | `organization`                 | `name`       | —                                  |
| `users`                         | `user`                         | `login`      | — (requires admin)                 |
| `repositories`                  | `repository`                   | `name`       | `owner` → org/user                 |
| `teams`                         | `team`                         | `name`       | `organization` → org               |
| `team_members`                  | `team_member`                  | —            | `team` → team, `user` → user       |
| `collaborators`                 | `collaborator`                 | —            | `repository` → repo, `user` → user |
| `repository_webhooks`           | `repository_webhook`           | —            | `repository` → repo                |
| `branch_protections`            | `branch_protection`            | —            | `repository` → repo                |
| `deploy_keys`                   | `deploy_key`                   | —            | `repository` → repo                |
| `repository_action_secrets`     | `repository_action_secret`     | `name`       | `repository` → repo                |
| `repository_action_variables`   | `repository_action_variable`   | `name`       | `repository` → repo                |
| `organization_action_secrets`   | `organization_action_secret`   | `name`       | `organization` → org               |
| `organization_action_variables` | `organization_action_variable` | `name`       | `organization` → org               |
| `ssh_keys`                      | `ssh_key`                      | —            | `user` → user (requires admin)     |
| `gpg_keys`                      | `gpg_key`                      | —            | —                                  |

The provider takes an owning organization either by name or by numeric
`organization_id` and requires exactly one of the two. Only the name form is
exposed, since the `organization` reference above already accepts both a managed
organization's key and a literal name.

## Provider updates

The option surface is generated from `provider-schema.json`, a normalized dump
of the pinned provider's schema, committed next to `pkg.nix`. To move to a newer
provider, bump `rev`/`hash`/`vendorHash` in `pkg.nix`, then:

```sh
nix run .#update-provider-schemas
nix flake check
```

The check names every difference the bump introduces: resources added or
removed, attributes added, removed or retyped, and any correction in `lib.nix`
that no longer matches the schema. A new resource must either be modelled or
listed in the pairing's `unsupported` set with a reason — it cannot be ignored.

An upstream attribute that becomes **required** turns into a required option,
which fails evaluation for configurations that never set it. That is usually the
right signal, but `forceOptional` in the collection's overlay is the release
valve when it is not.

## Security note

Secret-valued _resource_ attributes — `password` (`users`), `data`
(`*_action_secret`), `auth_token` (`repositories`), `authorization_header`
(`repository_webhooks`) — each accept an `<attr>File` form (`passwordFile`,
`dataFile`, `auth_tokenFile`, `authorization_headerFile`) that takes a **host
file path** instead of the literal value. The file is read at apply time via
systemd `LoadCredential=` into a sensitive Terraform variable and **never enters
the Nix store**; the generated `.tf.json` holds only a `${var.…}` reference (the
same mechanism that protects the provider admin token). Prefer it for any real
secret:

```nix
services.forgejo.runtime.organization_action_secrets.deploy_key = {
  organization = "acme";
  dataFile = "/run/secrets/forgejo-deploy-key"; # host path, not a store path
};
```

Setting the attribute _literally_ (e.g. `data = "…"`) still works, but renders
the value verbatim into the **world-readable** `.tf.json` store path — use it
only for non-secret values. `<attr>` and `<attr>File` are mutually exclusive.
