# CLAUDE.md

> Status: the pattern is implemented. **`services/forgejo` is the worked
> reference pairing** — new pairings are modeled on it, and the "Provider
> implementation contract" below is exactly what it encodes. Grafana and
> Keycloak (see "Target pairings") are designed but not yet built; do not
> present them as implemented.

## Purpose

Make NixOS services **more declaratively configurable** than upstream Nixpkgs
modules allow, by pairing each service with its Terraform provider and
reconciling the service's _runtime state_ once the service is up.

Upstream NixOS modules configure a service's **static** surface — package
version, config file, the systemd unit. They deliberately do **not** manage a
service's **runtime** state: Grafana dashboards/datasources, a Git forge's
orgs/repos/teams, etc. Many such services ship a Terraform provider that _does_
manage exactly that state.

This repo closes the gap: you declare the desired runtime state in Nix, and a
systemd unit applies it (via OpenTofu) against the live, local instance after
the service's primary unit starts.

A pairing only makes sense when the service has **admin-declarative runtime
state reachable through a provider** that the NixOS module cannot already
express. Services whose entire surface is config-file-driven (and thus already
declarative via their NixOS options) are out of scope. (Authelia is the
canonical _non_-fit: no Terraform provider exists, and its admin surface is
already covered by `services.authelia.*` — so it was dropped as a pairing.)

## Settled decisions

| Topic            | Decision                                                                                                                                                                                                                                                                                                   |
| ---------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Executor         | **OpenTofu** (nixpkgs `opentofu`, MPL 2.0 / free). `terraform` is BSL 1.1 / unfree and is **not** used.                                                                                                                                                                                                    |
| Config authoring | Generate **`.tf.json`** directly from Nix (`builtins.toJSON`). No HCL, no terranix dependency.                                                                                                                                                                                                             |
| Secrets          | **systemd `LoadCredential=`** is the blessed path. Generated config references the secret as a `sensitive` Terraform variable; never literal secrets. sops-nix/agenix, if used, only supply the source that feeds `LoadCredential=`.                                                                       |
| Reconciliation   | **Run-once**: a `Type=oneshot` unit ordered `After=` the primary unit + readiness probe, runs `init` + `apply -auto-approve`. Re-applies on config change via `restartTriggers`. **No** drift timer. A failed apply fails _that unit_ visibly (`systemctl status`) and does **not** tear down the service. |
| State            | **Local, per-host only.** Terraform state lives under the **base service's primary state directory** (e.g. `services.forgejo.stateDir` → `/var/lib/forgejo`), co-located with the service it configures. No remote backends.                                                                               |
| Module namespace | Under the base service as **`services.<svc>.runtime.*`** (e.g. `services.forgejo.runtime.repositories`), so the pairing reads as a transparent extension of the upstream `services.<svc>` module.                                                                                                          |
| Formatter        | **treefmt** driving **nixfmt**. Formatter is the single source of layout truth — run it, never hand-format.                                                                                                                                                                                                |
| CI               | **GitHub Actions**: `nix flake check` on push + PR, Nix provided by Determinate Systems `nix-installer-action`. Workflow is Forgejo-Actions-compatible (same syntax) if hosting moves there.                                                                                                               |
| License          | **MIT** (matches nixpkgs ecosystem norms; permissive).                                                                                                                                                                                                                                                     |
| Toolchain pin    | Flake `nixpkgs` input tracks **`nixos-unstable`** (the verified provider/service versions live there); minimum **Nix ≥ 2.18** for the stable flake CLI + `nix flake check`.                                                                                                                                |
| Commits          | **Conventional Commits**, **atomic** (one self-contained conceptual change per commit; the tree builds/passes at every commit), linear history (rebase/squash, no merge commits). VCS is the colocated `jj`/`git` checkout.                                                                                |

## Core mechanism

For each enabled pairing:

1. Enable the upstream Nixpkgs service (`services.<svc>.enable = true`).
2. Generate `.tf.json` from `services.<svc>.runtime.*` options describing the
   desired state, plus a `provider` block pointed at the local instance
   (loopback / unix socket), with credentials sourced from `LoadCredential=`.
3. Wrap the executor with the pairing's provider via
   `pkgs.opentofu.withPlugins (_: [ provider ])`, so `tofu init`/`apply` resolve
   it from a Nix-built plugin dir with **no registry access** at activation
   time.
4. Run the oneshot apply unit `After=` the primary unit, gated on a **readiness
   probe** (the unit being "started" ≠ the service accepting connections).
5. Re-apply when the generated config changes (`restartTriggers`).

## Target pairings

Provider reality verified against nixpkgs + the public registry:

| Service      | Provider                          | Source                                                  | Status                                                                                                                                                                                                                                                          |
| ------------ | --------------------------------- | ------------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **Forgejo**  | `forgejo` (svalabs/forgejo 1.5.0) | vendored in `services/forgejo/pkg.nix` (not in nixpkgs) | **Implemented — the reference pairing.** Dedicated Forgejo provider on the Forgejo Go SDK, tracking Forgejo's API as it diverges from Gitea (hard fork since 2024). Chosen over the in-nixpkgs `gitea` provider. Vendored via `terraform-providers.mkProvider`. |
| **Grafana**  | `grafana` (4.36.0)                | `pkgs.terraform-providers.grafana`                      | Designed, not yet built. In-nixpkgs provider.                                                                                                                                                                                                                   |
| **Keycloak** | `keycloak` (5.7.0)                | `pkgs.terraform-providers.keycloak`                     | Designed, not yet built. Full admin REST API (realms/clients/roles/scopes). Heavy JVM service — VM tests need extra memory and a generous readiness wait.                                                                                                       |

## Repository layout

Each service<->provider pairing lives in its own directory under `services/`.
`services/forgejo` is the worked example:

```
flake.nix                   # outputs: nixosModules (.default + per-pairing .<svc>), checks, formatter
treefmt.nix                 # treefmt + nixfmt config
modules/
  default.nix               # aggregates per-pairing modules into nixosModules.default
  lib/                      # provider-agnostic helpers: tf-label/file, run-once OpenTofu reconciler
services/                   # one directory per service<->provider pairing
  forgejo/                  # worked example: the Forgejo <-> svalabs/forgejo pairing
    module.nix              # NixOS module: services.forgejo.runtime options + systemd wiring (reconciler + token bootstrap)
    lib.nix                 # provider specifics: wrapped OpenTofu executor + .tf.json generation (resource spec + ref resolution)
    pkg.nix                 # optional: vendor the provider when it's not in nixpkgs (here svalabs/forgejo via mkProvider)
    checks.nix              # the pairing's checks attrset (nixosTest); merged into flake checks
    README.md               # per-pairing usage docs
```

## Provider implementation contract

`services/forgejo` is the template. A new pairing `services/<svc>/` provides
`module.nix`, `lib.nix`, `checks.nix`, a `README.md`, and (only when the
provider is not in nixpkgs) `pkg.nix`. It **reuses** the provider-agnostic
helpers in `modules/lib` and **replicates** the forgejo `lib.nix` generation
pattern. Everything below is what the forgejo pairing encodes.

### Wiring a new pairing

- Export it from the flake: add `nixosModules.<svc> = ./services/<svc>/module.nix;`,
  add the directory to `modules/default.nix`'s `imports` (so it also joins the
  aggregate `nixosModules.default`), and merge
  `import ./services/<svc>/checks.nix { inherit pkgs self; }` into the flake's
  `checks`.
- Everything (`checks`, `formatter`) is produced for both `x86_64-linux` and
  `aarch64-linux` via `forAllSystems`.

### `lib.nix` — provider specifics

- Signature `{ pkgs }:`; pulls `genlib = import ../../modules/lib { inherit pkgs; }`
  and returns `{ resourceTypes; resourceOptions; <svc>TfConfig; mkReconcileService; … }`.
- Specializes the generic reconciler with the provider's executor and token
  variable: `mkReconcileService = args: genlib.mkReconcileService (args // { inherit executor tokenVar; });`.
- `executor = pkgs.opentofu.withPlugins (_: [ provider ])`. `tokenVar` is the
  `sensitive` Terraform variable **and** `LoadCredential` id carrying the admin
  token (e.g. `forgejo_api_token`).
- The `.tf.json` generation engine (`<svc>TfConfig`, reference resolution) lives
  **here, per-provider**, modeled on forgejo — `modules/lib` carries only the
  reusable `tfLabel`, `tfJsonFile`, and `mkReconcileService`.

### Modeling the resource surface

- Enumerate every provider resource in a `resourceTypes` record:
  `{ type = "<provider>_<resource>"; prefix; nameAttr; scope; refs; secrets; requiredSecrets; attrs; description; }`
  — `prefix` is a unique label prefix, `nameAttr` the attribute defaulted from
  the collection key (or `null`), `scope` the token scope(s) the resource needs,
  `refs` its parent links, `secrets` its secret-valued attributes,
  `requiredSecrets` those of them the provider requires, `attrs` the typed
  option for every settable attribute.
- Each resource is exposed as a **strictly typed** collection:
  `attrsOf (submodule { options = <attrs> ++ <refs> ++ <attr>File; })` — **no
  `freeformType`**. Every settable upstream attribute is a declared option typed
  to what the provider accepts (string/bool/int/list/map, and `submodule` for
  nested objects), so a wrong name, wrong type, or missing required field is an
  eval-time error at `nix flake check`, not an apply-time one. Derive `attrs`
  from the provider schema (`tofu providers schema -json`); omit computed /
  output-only attributes. Required attributes are declared without a default;
  optional ones are `nullOr T` defaulting to `null` (dropped from the generated
  JSON when unset). The attrset key becomes the Terraform label and defaults
  `nameAttr`. Reference inputs and `<attr>File` secret inputs are declared
  separately (they are resolved/rerouted at generation, not passed through).
- Parent links are named by the **key of another managed resource** and resolved
  to `${type.label.field}` interpolations — this both wires the numeric `*_id`
  attributes a user cannot know _and_ orders `tofu apply`. A `refs` entry is
  `{ attr; targets; field; managedOnly; required; description; }`: `managedOnly`
  references (numeric ids) must resolve to a managed sibling (generation throws
  otherwise); name references accept a managed key _or_ a literal; `required`
  declares the reference input as a required option.
- `<svc>TfConfig cfg` returns `{ config; credentials; }`. `config` carries **no
  secret**: a `provider` block pointed at the local instance, plus the admin
  token and every `<attr>File` secret as `sensitive` input `variable`s fed from
  `TF_VAR_<id>` at apply time.

### Secrets — per-resource credential indirection

- Mark secret attributes in `resourceTypes.<r>.secrets`. Each gets an
  `<attr>File` option taking a **host file path** (a string path resolved on the
  target, _never_ a Nix store path). When set, generation emits `${var.<id>}` +
  a `sensitive` variable and collects an `id → host path` pair (id
  `secret_<prefix>_<key>_<attr>`); the literal `<attr>` and `<attr>File` are
  mutually exclusive. The credential map flows `<svc>TfConfig` → `module.nix` →
  `mkReconcileService`, which `LoadCredential=`s each file and exports it as
  `TF_VAR_<id>`. This is the same mechanism that protects the admin token.

### The reconciler unit (`mkReconcileService`, reused as-is)

- Unit `declarative-<svc>`: `Type=oneshot` + `RemainAfterExit`;
  `after`/`requires` the primary unit (and the token bootstrap, if any);
  `wantedBy = multi-user.target`; `restartTriggers = [ confFile ]` (re-apply on
  config change); env `TF_IN_AUTOMATION=1` / `TF_INPUT=0`.
- Its Terraform state lives under the **base service's primary state directory**
  (a `declarative-terraform` subdir of e.g. `services.forgejo.stateDir`, created
  `0700`), co-located with the service it configures and backed up alongside it,
  so the reconciler runs as the service's `User`/`Group` rather than in an
  isolated `DynamicUser` state dir.
- The script installs the generated config `0600`, **polls `healthUrl`** until
  the service answers, exports each credential from `$CREDENTIALS_DIRECTORY`,
  then runs `tofu init` + `tofu apply -auto-approve` (`-input=false -no-color`).

### `module.nix` — the NixOS module

- `{ config, lib, pkgs, ... }:`; `cfg = config.services.<svc>.runtime`;
  `tflib = import ./lib.nix { inherit pkgs; }`.
- Options live under `services.<svc>.runtime` — so the pairing reads as a
  transparent extension of the upstream `services.<svc>` module: `enable`
  (`mkEnableOption`), `baseUrl` (default = the local instance), `tokenFile`
  (`nullOr str` — a **host path resolved on the target, never a store path**;
  `null` ⇒ self-bootstrap), any provider-specific knobs, **plus
  `// tflib.resourceOptions`**.
- `config = mkIf cfg.enable { … }` **asserts `services.<svc>.enable`** (the
  pairing layers on the upstream service) and wires the reconciler with
  `healthUrl`, the service's `user`/`group`/`stateDir`, and the resolved
  `tokenFile`/`credentials`.
- Token strategy: accept the operator's `tokenFile`, or self-bootstrap via a
  companion `declarative-<svc>-token` oneshot. Forgejo currently mints one
  maximal `all`-scoped token (mint-once); its least-privilege `requiredScopes`
  computation is kept dormant for Forgejo ≥16's admin token API. Pick what fits
  the provider's auth model.

### `checks.nix` — the VM test

- `{ pkgs, self }:` → `{ <svc> = pkgs.testers.runNixOSTest { … }; }`, merged into
  the flake's `checks`. Import `self.nixosModules.default`; boot with
  `services.<svc>` (including its `runtime` block) and let it converge **at boot
  with zero manual setup**; `wait_for_unit("declarative-<svc>.service")` (a
  failed apply fails the unit).
- Assert the **runtime state via the live service API** (anonymous, token, or
  login) — never the Terraform state. Cover both reference kinds, idempotency (a
  second apply reports `0 added/changed/destroyed`), and secret indirection (the
  value reaches the service; the literal is absent from the generated
  `.tf.json`). Use `specialisation` for config-change cases; size
  `virtualisation` for the service. No mocks.

### `pkg.nix` — vendoring (only when the provider is not in nixpkgs)

- `pkgs.terraform-providers.mkProvider { owner; repo; rev; spdx; hash; vendorHash; homepage; }`,
  with `required_providers` pinned to `provider.version`. Update by bumping
  `rev`, then refreshing `hash` (source) and `vendorHash` (Go modules) together.

### Docs & comments

- Ship a `README.md` per pairing: Installation → Configuration examples (several
  distinct use cases) → Module options → Resources table → Security note.
- Every `.nix` file opens with a header comment stating its role and the _why_,
  not just the _what_.

## Conventions

- Nix only; no parallel non-Nix config layers.
- Options describe _desired state_ in domain terms; they must not leak Terraform
  resource addresses or HCL into the user-facing API.
- Always use **`hackme`** for any plain-text password — never invent ad-hoc test
  passwords. If the service rejects it on policy grounds (length/complexity),
  relax that policy in the test config (e.g. `MIN_PASSWORD_LENGTH`) rather than
  picking a different password.
- See "Provider implementation contract" for the per-pairing file, option, and
  test layout.

## Development

```sh
nix flake check                      # eval modules + run all NixOS VM tests + formatting
nix build .#checks.<system>.<svc>    # run one pairing's VM test (e.g. checks.x86_64-linux.forgejo)
nix fmt                              # treefmt -> nixfmt across the tree
nix develop                          # devshell (curl, jq)
```

## Verification standard

Behavior is proven with **NixOS VM integration tests**
(`pkgs.testers.runNixOSTest`): boot a VM with the pairing enabled, wait for the
service, let the runner apply, then assert the _runtime state_ exists (query the
service, not the Terraform state). Eval-only/build-only success is **not**
evidence the reconciliation works. Never assert behavior you did not exercise.

## Hard rules for agents

- **Never put secrets in generated `.tf.json`.** Anything in the Nix store is
  world-readable. The admin token and per-resource secrets come from systemd
  `LoadCredential=` as `sensitive` Terraform variables; for resource attributes
  use the `<attr>File` option (a host path), never the literal.
- **Never commit Terraform state or `.terraform/`.** State is host runtime data
  under `/var/lib`, not source.
- Generated config is **JSON**, not HCL.
- Executor is **OpenTofu**. Do not pull in `terraform` (unfree).
- Activation must be **offline** — the provider is baked in via
  `opentofu.withPlugins`; no provider downloads during `init`/`apply`.
- **Commit after every conceptual change.** One atomic commit per logical change — never batch unrelated edits into one commit, and never leave finished work uncommitted. In `jj`, finalize the working copy with `jj commit -m "<conventional message>"` (which opens a fresh change on top).
