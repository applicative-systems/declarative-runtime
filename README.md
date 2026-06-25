# declarative-runtime

**Declarative NixOS service runtime config via paired OpenTofu providers.**
Make NixOS services **more declaratively configurable** than upstream Nixpkgs
modules allow, by pairing each service with its Terraform provider and
reconciling the service's _runtime state_ once it is up.

> **Status:** two pairings implemented.
>
> - **[Forgejo](services/forgejo/README.md)** — 15 resource types
>   (organizations, users, repositories, teams, action secrets/variables,
>   webhooks, branch protection, SSH/GPG/deploy keys, collaborators).
> - **[Keycloak](services/keycloak/README.md)** — ~95 resource types
>   (realms, clients, scopes, ~20 protocol mappers, identity providers,
>   IdP mappers, roles, groups, users, authentication flows, fine-grained
>   authorization + policies, LDAP federation + mappers, realm keystores,
>   realm-level config). Includes a service-account bootstrap and nested
>   `<attr>File` indirection for every secret attribute at any depth.

## The gap this closes

Upstream NixOS modules configure a service's **static** surface — package
version, config file, the systemd unit. They deliberately do **not** manage a
service's **runtime** state: Grafana dashboards/datasources, a Git forge's
orgs/repos/teams, and so on. Many such services ship a Terraform provider that
manages exactly that state.

Here you declare the desired runtime state in Nix, and a systemd unit applies it
(via OpenTofu) against the live, local instance after the service's primary unit
starts:

```nix
services.forgejo = {
  enable = true;
  runtime = {
    enable = true;
    organizations.acme.description = "ACME Corporation";
    repositories.widgets = {
      owner = "acme";
      description = "Widget factory";
    };
  };
};

services.keycloak = {
  enable = true;
  initialAdminPassword = "REPLACE_ME";
  database.passwordFile = "/run/secrets/keycloak-db-password";
  runtime = {
    enable = true;
    bootstrapAdminPasswordFile = "/run/secrets/keycloak-admin-password";
    realms.staff.display_name = "Staff SSO";
    openid_clients.app = {
      realm = "staff";
      client_id = "app";
      access_type = "CONFIDENTIAL";
      client_secretFile = "/run/secrets/staff-app-client-secret";
      valid_redirect_uris = [ "https://app.example.com/*" ];
    };
  };
};
```

A pairing only makes sense when a service has **admin-declarative runtime state
reachable through a provider** that the NixOS module cannot already express.
Services whose entire surface is config-file-driven (already declarative via
their NixOS options) are out of scope.

## How it works

For each enabled pairing:

1. Enable the upstream Nixpkgs service (`services.<svc>.enable = true`).
2. Generate `.tf.json` from `services.<svc>.runtime.*` (desired state).
3. Run a `Type=oneshot` apply unit ordered `After=` the primary unit, gated on a
   **readiness probe**; it re-applies when the generated config changes.

Reconciliation is **run-once, not a drift timer**. A failed apply fails _that
unit_ visibly (`systemctl status`) without tearing down the service.

## Usage

Add this flake as an input and import the pairing's NixOS module
(`nixosModules.forgejo`, `nixosModules.keycloak`, or
`nixosModules.default` for all pairings). Full installation, configuration
examples, the option reference, the resource table, and the secrets guide
live in the per-pairing README:

- [Forgejo pairing](services/forgejo/README.md)
- [Keycloak pairing](services/keycloak/README.md) — includes the
  service-account bootstrap flow and the operator-supplied client
  override.

### Runnable examples

Each entry under [`examples/`](examples/) is a complete NixOS
configuration with its own walkthrough. `nix run .#<example>` builds
and boots the example as a QEMU VM (host ports forwarded so you can
hit the services from a browser).

- [`keycloak-forgejo`](examples/keycloak-forgejo/README.md) — both
  pairings together, a custom Keycloak login theme, SSO from Forgejo
  into Keycloak, a private internal repo, and per-user avatars served
  over a side nginx. `nix run .#keycloak-forgejo`.

### Secrets

Secrets should never enter the world-readable Nix store. The admin token and
any secret-valued resource attribute are read at apply time from a **host file
path** via systemd `LoadCredential=` into a `sensitive` Terraform variable; the
generated `.tf.json` holds only a `${var.…}` reference. Each secret attribute
has an `<attr>File` form (e.g. `dataFile`, `passwordFile`) that takes the host
path — prefer it over the literal for any real secret.

## Repository layout

```
flake.nix              # outputs: nixosModules, packages (examples), checks, formatter
treefmt.nix            # treefmt + nixfmt config
modules/
  default.nix          # aggregates per-pairing modules into nixosModules.default
  lib/                 # shared helpers: tf-label/file, run-once reconciler
services/              # one directory per service<->provider pairing
  forgejo/             # Forgejo <-> svalabs/forgejo
    module.nix         #   NixOS module: services.forgejo.runtime + systemd wiring
    lib.nix            #   provider specifics: wrapped executor + .tf.json generation
    pkg.nix            #   vendor the provider (not in nixpkgs)
    checks.nix         #   NixOS VM test
    README.md          #   usage docs
  keycloak/            # Keycloak <-> keycloak/keycloak (in nixpkgs)
    module.nix         #   services.keycloak.runtime + reconciler + bootstrap unit
    lib.nix            #   ~95 typed resourceTypes + the value-tree renderer
    checks.nix         #   1 VM + 4 nspawn-container tests, one per resource family
    README.md          #   usage docs
examples/              # runnable demos; one configuration.nix + README per example
  keycloak-forgejo/    #   both pairings together with theme, SSO, avatar
```

## Development

```sh
nix flake check                      # eval modules + run all NixOS VM tests + formatting
nix build .#checks.<system>.forgejo  # run one pairing's VM test
nix fmt                              # treefmt -> nixfmt across the tree
```

Behavior is proven with **NixOS VM integration tests** (`runNixOSTest`): boot a
VM with the pairing enabled, let the reconciler apply, then assert the runtime
state by querying the live service API — not the Terraform state. Eval-only or
build-only success is not evidence the reconciliation works.

## Design decisions

- **Executor:** OpenTofu (MPL 2.0); `terraform` (BSL 1.1, unfree) is not used.
- **Config:** `.tf.json` generated directly from Nix (`builtins.toJSON`) — no
  HCL, no terranix.
- **State:** local, per-host only, co-located under the base service's state
  directory (e.g. `/var/lib/forgejo`). No remote backends.
- **Namespace:** options live under `services.<svc>.runtime.*`, so a pairing
  reads as a transparent extension of the upstream `services.<svc>` module.
- **Toolchain:** flake `nixpkgs` tracks `nixos-unstable`; Nix ≥ 2.18.

Contributors: [`CLAUDE.md`](CLAUDE.md) documents the full provider
implementation contract for adding a new pairing.

## License

MIT.
