# CLAUDE.md

> Status: the pattern is implemented, by two pairings. **`services/forgejo` is
> the worked reference pairing** — new pairings are modeled on it, and the
> "Provider implementation contract" below is exactly what it encodes.
> `services/keycloak` is the second, and the one to read for the sdk/v2 schema
> dialect and for a large resource surface. Grafana (see "Target pairings") is
> designed but not yet built; do not present it as implemented.

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

| Topic            | Decision                                                                                                                                                                                                                                                                                                                                                    |
| ---------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Executor         | **OpenTofu** (nixpkgs `opentofu`, MPL 2.0 / free). `terraform` is BSL 1.1 / unfree and is **not** used.                                                                                                                                                                                                                                                     |
| Config authoring | Generate **`.tf.json`** directly from Nix (`builtins.toJSON`). No HCL, no terranix dependency.                                                                                                                                                                                                                                                              |
| Secrets          | **systemd `LoadCredential=`** is the blessed path. Generated config references the secret as a `sensitive` Terraform variable; never literal secrets. sops-nix/agenix, if used, only supply the source that feeds `LoadCredential=`.                                                                                                                        |
| Reconciliation   | **Run-once**: a `Type=oneshot` unit ordered `After=` the primary unit + readiness probe, runs `init` + `apply -auto-approve`. Re-applies on config change via `restartTriggers`. **No** drift timer. A failed apply fails _that unit_ visibly (`systemctl status`) and does **not** tear down the service.                                                  |
| State            | **Local, per-host only.** Terraform state lives under the **base service's primary state directory** (e.g. `services.forgejo.stateDir` → `/var/lib/forgejo`), co-located with the service it configures. No remote backends.                                                                                                                                |
| Module namespace | Under the base service as **`services.<svc>.runtime.*`** (e.g. `services.forgejo.runtime.repositories`), so the pairing reads as a transparent extension of the upstream `services.<svc>` module.                                                                                                                                                           |
| Resource surface | **Derived from a vendored provider schema**, via the generic converters in [`nix-tf-schema`](https://git.fediversity.eu/fediversity/nix-tf-schema) (a source-only flake input). A pairing hand-writes only what the schema cannot carry: the reference graph, the NixOS-facing prose, and per-collection corrections. Provider drift is an eval-time error. |
| Formatter        | **treefmt** driving **nixfmt**. Formatter is the single source of layout truth — run it, never hand-format.                                                                                                                                                                                                                                                 |
| CI               | **GitHub Actions**: `nix flake check` on push + PR, Nix provided by Determinate Systems `nix-installer-action`. Workflow is Forgejo-Actions-compatible (same syntax) if hosting moves there.                                                                                                                                                                |
| License          | **MIT** (matches nixpkgs ecosystem norms; permissive).                                                                                                                                                                                                                                                                                                      |
| Toolchain pin    | Flake `nixpkgs` input tracks **`nixos-unstable`** (the verified provider/service versions live there); minimum **Nix ≥ 2.18** for the stable flake CLI + `nix flake check`.                                                                                                                                                                                 |
| Commits          | **Conventional Commits**, **atomic** (one self-contained conceptual change per commit; the tree builds/passes at every commit), linear history (rebase/squash, no merge commits). VCS is the colocated `jj`/`git` checkout.                                                                                                                                 |

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
| **Keycloak** | `keycloak` (5.8.0)                | `pkgs.terraform-providers.keycloak`                     | **Implemented.** All 101 provider resources modelled, proven by six VM tests. Full admin REST API (realms/clients/roles/scopes). Heavy JVM service — VM tests need extra memory and a generous readiness wait.                                                  |

## Repository layout

Each service<->provider pairing lives in its own directory under `services/`.
`services/forgejo` is the worked example:

```
flake.nix                   # outputs: nixosModules (.default + per-pairing .<svc>), packages, apps, checks, formatter
treefmt.nix                 # treefmt + nixfmt config
modules/
  default.nix               # aggregates per-pairing modules into nixosModules.default
  lib/
    default.nix             # provider-agnostic helpers: tf-label/file, .tf.json generation, run-once OpenTofu reconciler
    tf-schema.nix           # schema-driven resourceTypes generator + drift assertions
    render-fixtures.nix     # renders a pairing's fixtures through the real option system (refactor snapshot)
    schema-report.nix       # the per-pairing coverage table, as a build artifact
services/                   # one directory per service<->provider pairing
  forgejo/                  # worked example: the Forgejo <-> svalabs/forgejo pairing
    module.nix              # NixOS module: services.forgejo.runtime options + systemd wiring (reconciler + token bootstrap)
    lib.nix                 # provider specifics: wrapped OpenTofu executor + the resource-surface overlay
    provider-schema.json    # normalized dump of the pinned provider's schema; the resource surface is derived from it
    schema.nix              # one line: fromJSON (readFile ./provider-schema.json) -- import is memoized, readFile is not
    pkg.nix                 # optional: vendor the provider when it's not in nixpkgs (here svalabs/forgejo via mkProvider)
    fixtures.nix            # the services.forgejo.runtime blocks the VM tests converge, shared with the rendered-fixtures package
    checks.nix              # the pairing's checks attrset (nixosTest); merged into flake checks
    README.md               # per-pairing usage docs
  keycloak/                 # the Keycloak <-> keycloak/keycloak pairing; same layout, no pkg.nix (provider is in nixpkgs)
```

## Provider implementation contract

`services/forgejo` is the template. A new pairing `services/<svc>/` provides
`module.nix`, `lib.nix`, `provider-schema.json`, `schema.nix`, `fixtures.nix`,
`checks.nix`, a `README.md`, and (only when the provider is not in nixpkgs)
`pkg.nix`. It **reuses** the provider-agnostic helpers in `modules/lib` —
including the resource-surface generator — and only writes down what the
provider schema cannot express. Everything below is what the forgejo and
keycloak pairings encode.

### Wiring a new pairing

- Export it from the flake: add
  `nixosModules.<svc> = withSchemaLib ./services/<svc>/module.nix;`, add an entry
  to `pairingLibs` (which is what feeds the schema, coverage, options-doc and
  rendered-fixture outputs), add the directory to `modules/default.nix`'s
  `imports` (so it also joins the aggregate `nixosModules.default`), and merge
  `import ./services/<svc>/checks.nix { inherit pkgs self; }` into the flake's
  `checks`.
- `withSchemaLib` sets `_module.args.nixTfSchema`: a NixOS module cannot reach a
  flake input by path, so the schema library is threaded in as a module argument.
- Everything (`packages`, `checks`, `formatter`) is produced for both
  `x86_64-linux` and `aarch64-linux`.

### Vendored provider schema

- `provider-schema.json` is a normalized `tofu providers schema -json` dump of
  the pinned provider: `jq -S`, data sources and the top-level `provider` block
  dropped, `source`/`version` injected (the dump itself carries no version). It
  is committed, and `nix run .#update-provider-schemas` regenerates it.
- **Never IFD.** The flake evaluates for `aarch64-linux` as well, and IFD would
  mean running a foreign-arch provider binary during eval. Provider schemas are
  platform-independent, so one committed JSON per provider version is correct.
- `schema.nix` is a one-line `fromJSON (readFile ./provider-schema.json)`. Nix
  memoizes `import <path>` but not `readFile`, and `lib.nix` is instantiated
  ~10 times per `nix flake check`.

### `lib.nix` — provider specifics

- Signature `{ pkgs, nixTfSchema }:`; pulls
  `genlib = import ../../modules/lib { inherit pkgs; }` and
  `tfSchema = import ../../modules/lib/tf-schema.nix { inherit pkgs nixTfSchema; }`,
  and returns
  `{ resourceTypes; resourceOptions; coverage; <svc>TfConfig; mkReconcileService; provider; providerSource; … }`.
- Specializes the generic reconciler with the provider's executor and token
  variable: `mkReconcileService = args: genlib.mkReconcileService (args // { inherit executor tokenVar; });`.
- `executor = pkgs.opentofu.withPlugins (_: [ provider ])`. `tokenVar` is the
  `sensitive` Terraform variable **and** `LoadCredential` id carrying the admin
  credential (e.g. `forgejo_api_token`).
- `.tf.json` generation is `genlib.mkTfConfig` — shared, not per-provider. What
  is per-provider is the resource-surface overlay below.

### Modeling the resource surface

- The surface is **derived from `provider-schema.json`**, not hand-written:
  `tfSchema.mkResourceTypes { schema; provider; source; runtimePrefix; resources; unsupported ? {}; omitEverywhere ? []; }`
  returns `{ resourceTypes; checks; coverage; }` in exactly the shape
  `modules/lib/default.nix` already consumes. Split of responsibility:

  | Derived from the schema                                | Hand-written in the overlay                                |
  | ------------------------------------------------------ | ---------------------------------------------------------- |
  | every settable attribute, its Nix type and optionality | the collection name, `type`, `prefix`, `nameAttr`, `scope` |
  | nested blocks as submodules, `blockAttrs` wrapping     | `refs` — the reference graph, which no schema carries      |
  | `secrets` (schema `sensitive`) and `requiredSecrets`   | `description` — the NixOS-facing prose                     |
  | attribute descriptions (provider's own, else a stub)   | corrections: see the next bullet                           |

- Corrections a collection may declare, all of them optional and all validated
  against the schema: `omit` (dotted paths to drop), `extraSecrets` /
  `notSecrets` (attributes the schema mis-marks), `forceOptional`,
  `requiredAttrs` (extra non-empty checks), `oneOfRefs` (Go-validator
  `ExactlyOneOf`, absent from the schema), and `extraAttrs` (last-resort typed
  overrides). Provider-wide dialect artifacts go in `omitEverywhere` — the
  sdk/v2 synthetic `id`, say — not in per-collection `omit`.
- **Every overlay key must name a real schema path.** There is deliberately no
  way to declare an option with no schema counterpart; `refs` is the only
  exception, and that is what makes the drift check total.
- Each resource is exposed as a **strictly typed** collection:
  `attrsOf (submodule { options = <attrs> ++ <refs> ++ <attr>File; })` — **no
  `freeformType`**. A wrong name, wrong type, or missing required field is an
  eval-time error at `nix flake check`, not an apply-time one. Computed /
  output-only attributes are dropped. The attrset key becomes the Terraform
  label and defaults `nameAttr`. Reference inputs and `<attr>File` secret inputs
  are declared separately (they are resolved/rerouted at generation, not passed
  through).
- Required attributes are declared without a default; optional ones are
  `nullOr T` defaulting to `null` (dropped from the generated JSON when unset).
  Four cases are forced optional even when the schema says required:
  - **`nameAttr`** — must be nullable so the attrset key can fill it; the
    non-empty requirement is re-imposed after injection via `requiredAttrs`.
  - **secrets** — the `<attr>File` sibling may satisfy them instead.
  - **collection-typed** — `listOf`/`attrsOf` default to `[]`/`{}` and cannot
    express "unset"; an empty value would silently strip server-side state.
  - **explicit `forceOptional`** — the release valve when a provider bump makes
    an attribute required and existing configurations must keep evaluating.

### Two schema dialects

Which one a provider speaks decides how nested objects are read, and both
readers are exercised in-tree:

- **terraform-plugin-sdk/v2** (keycloak): nested objects live in
  `block.block_types.<k>` with a `nesting_mode`. A `list`/`set` block with
  `max_items == 1` is a _singleton block_ that Terraform reads as a one-element
  list, so it must render as `[ { … } ]` — that is what `blockAttrs` is for, and
  it is derived, never listed by hand. Every sdk/v2 resource also carries a
  synthetic `id`.
- **terraform-plugin-framework** (forgejo): nested objects live in
  `block.attributes.<k>.nested_type` with `nesting_mode: "single"` and encode as
  plain objects — no `blockAttrs` at all.

### Drift is a hard error

- Eval-time assertions live in the generator's `checks` and fire the moment
  `resourceTypes` is forced. Identity: the schema's `source` and `version` match
  the packaged provider. Overlay → schema: every `type`, `nameAttr`, ref `attr`,
  correction entry and `extraAttrs` key names something the schema declares;
  `prefix`es and `type`s are unique. Schema → overlay: every resource the
  provider offers is either modelled or listed in `unsupported` with a non-empty
  reason. A provider bump therefore names every new resource in the error.
- `<svc>-schema-coverage` forces those assertions on their own, so drift fails a
  check that names it rather than whichever VM test happens to eval first, and
  renders the coverage table as the review artifact.
- `<svc>-schema-current` is the authoritative one: it re-extracts the schema in
  a sandbox and diffs it against the vendored file, so a provider that changes a
  schema without changing its version still fails CI.
- `<svc>-options-doc` is the user-facing option surface as `options.json`; build
  it before and after a change and diff, since rendered `.tf.json` alone cannot
  show an option nobody sets.
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

- Secret attributes come from the schema's `sensitive` flag (with `extraSecrets`
  / `notSecrets` to correct it), at any nesting depth. Each gets an
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

- `{ config, lib, pkgs, nixTfSchema, ... }:`; `cfg = config.services.<svc>.runtime`;
  `tflib = import ./lib.nix { inherit pkgs nixTfSchema; }`.
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
- The `services.<svc>.runtime` blocks the tests converge live in `fixtures.nix`,
  not inline. `<svc>-rendered-fixtures` renders exactly those through the real
  option system and renderer, so diffing that package before and after a change
  to the resource surface proves the wire format is untouched.

### `pkg.nix` — vendoring (only when the provider is not in nixpkgs)

- `pkgs.terraform-providers.mkProvider { owner; repo; rev; spdx; hash; vendorHash; homepage; }`,
  with `required_providers` pinned to `provider.version`. Update by bumping
  `rev`, then refreshing `hash` (source) and `vendorHash` (Go modules) together.

### Docs & comments

- Ship a `README.md` per pairing: Installation → Configuration examples (several
  distinct use cases) → Module options → Resources table → Provider updates →
  Security note. The resources table is a map, not the contract: point at
  `<svc>-options-doc` and `<svc>-schema-coverage` as the authoritative lists.
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

After a nixpkgs bump moves a provider (or a `pkg.nix` bump does):

```sh
nix run .#update-provider-schemas    # refresh every services/<svc>/provider-schema.json
nix flake check                      # now names every resource and attribute that changed
```

Static evidence for a change to a resource surface, both diffed before/after:

```sh
nix build .#<svc>-rendered-fixtures            # the wire format -- an empty diff means no behaviour change
nix build .#checks.<system>.<svc>-options-doc  # the user-facing option surface
nix build .#checks.<system>.<svc>-schema-coverage  # what is modelled, and what is deliberately not
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
