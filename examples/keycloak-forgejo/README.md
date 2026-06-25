# Example: keycloak + forgejo (Dunder Mifflin Paper Co.)

A disposable NixOS VM that exercises both pairings together:
`services.keycloak.runtime.*` and `services.forgejo.runtime.*` plus
the SSO loop wiring Keycloak as a Forgejo OAuth2 login source.

## Run it

From the repository root:

```sh
nix run .#keycloak-forgejo
```

Boot takes ~3-4 min. The console auto-logs in as `root` / `hackme`.
A `scranton.qcow2` lands in CWD; delete it to start over. Exit with
`Ctrl+a x` or `poweroff` from the guest.

## Forwarded ports

| Host port | Guest | What                                                  |
| --------- | ----- | ----------------------------------------------------- |
| 2222      | 22    | SSH (`ssh -p 2222 root@localhost`, password `hackme`) |
| 8080      | 8080  | Keycloak                                              |
| 3000      | 3000  | Forgejo                                               |
| 8888      | 8888  | Static avatar host (`jhalpert.png`)                   |

## What it demonstrates

**Keycloak (`services.keycloak.runtime`):**

- Realm `dunder_mifflin` with a custom `dunder_mifflin` login theme
  (Scranton blue on corporate beige -- see `themes/dunder_mifflin/`).
- Declarative user-profile schema (`realm_user_profiles`) so the
  `picture` attribute survives Keycloak v24+'s default
  `unmanaged_attribute_policy = DISABLED`.
- User `jhalpert` (Jim Halpert) with `initial_password.valueFile`
  indirection and a `picture` attribute pointing at the avatar host.
- OIDC client `dunder-mifflin-infinity` with `client_secretFile`
  indirection and a redirect URI pointed at Forgejo's OAuth2 callback.

**Forgejo (`services.forgejo.runtime`):**

- Org `dunder_mifflin`, public repo `scranton_branch`, private repo
  `intranet`.
- Pre-created users `jhalpert` and `dschrute` (passwords via
  `passwordFile`).
- Collaborator binding granting `jhalpert` write on `intranet`.

**Glue (plain systemd one-shots, not runtime-state):**

- `nginx` serving the rasterised PNG avatar at
  `http://localhost:8888/jhalpert.png`.
- `forgejo-oauth-setup` calling `forgejo admin auth add-oauth` to
  register Keycloak as a Forgejo login source named
  `DunderMifflinInfinity` (the svalabs/forgejo terraform provider
  doesn't model auth sources, so the runtime layer can't reach it).

## Try it

1. **Forgejo (local user).** <http://localhost:3000> -> login
   `dschrute` / `hackme`. See the org and the public `scranton_branch`
   repo; the private `intranet` repo is not visible.
2. **Keycloak account console.**
   <http://localhost:8080/realms/dunder_mifflin/account/> -> login
   `jhalpert` / `hackme`. The themed login page (beige + Scranton
   blue) and Jim's pre-populated profile.
3. **SSO loop.** Sign out of Forgejo. Visit
   <http://localhost:3000/user/login> and click **Sign in with
   DunderMifflinInfinity** (below the local login form) -> log in
   as `jhalpert` / `hackme` on the themed Keycloak page -> Forgejo
   links the SSO identity to the pre-created `jhalpert` (matched by
   email), pulls his avatar via the OIDC `picture` claim, and lands
   you on his dashboard.
4. **Internal repo.** As Jim, navigate to
   <http://localhost:3000/dunder_mifflin/intranet>. He has write
   access. Sign out (or sign in as `dschrute`), the URL returns 404.

## Known wrinkles

- **First-boot avatar.** Tofu creates `keycloak_user` and
  `keycloak_realm_user_profile` in parallel; the user-create request
  can race the schema, so on first apply Keycloak drops the `picture`
  attribute silently. Restarting `declarative-keycloak.service` (or
  rebooting) refreshes drift and re-PUTs the attribute. The fix is to
  emit a `depends_on` edge from user resources to their realm's
  user-profile -- a renderer change worth landing soon.
