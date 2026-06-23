# Keycloak pairing

Declaratively manage a [Keycloak](https://www.keycloak.org/) instance's
**runtime state** (realms, …) from NixOS, on top of the upstream
`services.keycloak` module.

[provider]: https://registry.terraform.io/providers/keycloak/keycloak/latest/docs

## Installation

### Include the module

Add this flake as an input and import its `nixosModules.keycloak` into your
host. Pointing the input's `nixpkgs` at your own keeps the provider build in
step with the rest of your system.

```nix
{
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

    # This repository.
    declarative-services.url = "github:youruser/terraform-providers";
    declarative-services.inputs.nixpkgs.follows = "nixpkgs";
  };

  outputs =
    { nixpkgs, declarative-services, ... }:
    {
      nixosConfigurations.myhost = nixpkgs.lib.nixosSystem {
        system = "x86_64-linux";
        modules = [
          declarative-services.nixosModules.keycloak
          ./host.nix
        ];
      };
    };
}
```

## Authentication model

The [`keycloak/keycloak`][provider] provider authenticates via OAuth2
**client-credentials** grant — it needs an OIDC client in the `master`
realm whose service-account user holds the master-realm `admin`
composite role (a realm-level role that grants global admin across every
realm). The pairing offers two paths:

1. **Self-bootstrap (default).** Set `bootstrapAdminPasswordFile` to a host
   path containing the master-realm `admin` password (the same value as
   `services.keycloak.initialAdminPassword`). A companion oneshot
   (`declarative-keycloak-bootstrap.service`) mints a dedicated
   service-account client (`clientId` = `clientName`, default
   `declarative-keycloak`), grants its service account the master-realm
   `admin` composite role, and persists the
   resulting `client_id`/`client_secret` 0600 under
   `/var/lib/declarative-keycloak-bootstrap/`. The reconciler picks them up
   via systemd `LoadCredential=` on every run; the file pair is the
   "already bootstrapped" marker, so the oneshot is a no-op on subsequent
   boots.

2. **Operator-supplied.** Set both `clientIdFile` and `clientSecretFile` to
   host paths for a service-account client you've created externally. The
   bootstrap oneshot is then not wired in at all.

## Configuration examples

Set `services.keycloak.enable = true` (the module asserts it) and declare
the runtime state under `services.keycloak.runtime`. Each entry's
attributes are **typed options** named after the upstream resource's
snake_case attributes (validated at `nix flake check`; an unknown name or
wrong type is a build error).

### Self-bootstrap: one realm

```nix
{
  services.keycloak = {
    enable = true;
    # Seed the master-realm admin user on first boot; the bootstrap oneshot
    # uses the same password (read from the host file via LoadCredential).
    initialAdminPassword = "REPLACE_ME";
    settings = {
      hostname = "sso.example.com";
    };
    database.passwordFile = "/run/secrets/keycloak-db-password";

    runtime = {
      enable = true;
      bootstrapAdminPasswordFile = "/run/secrets/keycloak-admin-password";

      realms.staff = {
        display_name = "Staff SSO";
        display_name_html = "<b>Staff</b> SSO";
      };
    };
  };
}
```

### Operator-supplied client (skip bootstrap)

Useful when the service-account client is provisioned out-of-band (e.g. by
a CI job or an existing IaC pipeline). With both files set, the pairing
does not create or modify the client and reads them directly.

```nix
{
  services.keycloak = {
    enable = true;
    settings.hostname = "sso.example.com";
    database.passwordFile = "/run/secrets/keycloak-db-password";

    runtime = {
      enable = true;
      clientIdFile = "/run/secrets/keycloak-tf-client-id";
      clientSecretFile = "/run/secrets/keycloak-tf-client-secret";

      realms.staff.display_name = "Staff SSO";
    };
  };
}
```

## Module options (`services.keycloak.runtime`)

| Option                       | Type        | Default                        | Purpose                                                                                                                                   |
| ---------------------------- | ----------- | ------------------------------ | ----------------------------------------------------------------------------------------------------------------------------------------- |
| `enable`                     | bool        | `false`                        | Turn on the reconciler.                                                                                                                   |
| `baseUrl`                    | str         | `http://localhost:<http-port>` | Keycloak admin API base URL the provider targets.                                                                                         |
| `bootstrapAdminPasswordFile` | null or str | `null`                         | Host path to the master-realm admin password. Required when no client credentials are supplied. Read via `LoadCredential=`; never stored. |
| `clientName`                 | str         | `"declarative-keycloak"`       | `clientId` of the service-account client minted at bootstrap. Unused when `clientIdFile`/`clientSecretFile` are set.                      |
| `clientIdFile`               | null or str | `null`                         | Host path to an externally-managed `client_id`. Set together with `clientSecretFile` to bypass bootstrap.                                 |
| `clientSecretFile`           | null or str | `null`                         | Host path to an externally-managed `client_secret`. Read via `LoadCredential=`; never stored.                                             |

Plus one collection option per provider resource (next section).

## Resources

Every [`keycloak/keycloak`][provider] resource is exposed as a collection
keyed by an arbitrary handle. First-wave coverage:

| Option   | `keycloak_*` resource | Key defaults | Reference inputs |
| -------- | --------------------- | ------------ | ---------------- |
| `realms` | `realm`               | `realm`      | —                |

Subsequent waves add clients, scopes, roles, groups, users, identity
providers, and protocol mappers.

## State directory note

Keycloak's upstream NixOS module runs as `User = "keycloak"; DynamicUser =
true; RuntimeDirectory = "keycloak"` — i.e. it has **no persistent
host-level state directory** (database state lives in PostgreSQL, runtime
state in `/run/keycloak`). The pairing therefore maintains its own
`/var/lib/keycloak/declarative-terraform` via systemd
`StateDirectory = "keycloak/declarative-terraform"`. systemd allocates the
same dynamic UID for `User = "keycloak"` in both the primary unit and the
reconciler, so the state dir is owned coherently with the rest of the
service and persists across reboots.

## Security note

The admin password (`bootstrapAdminPasswordFile`), the minted or
supplied `client_secret`, and the `client_id` are **never written to the
world-readable Nix store**. They are read at runtime via systemd
`LoadCredential=` and passed to OpenTofu as `sensitive = true` Terraform
input variables. The generated `.tf.json` (under
`/var/lib/keycloak/declarative-terraform/`) contains only `${var.…}`
placeholders for these values.

The same `<attr>` / `<attr>File` mechanism will protect secret-valued
resource attributes (e.g. `openid_client.client_secret`,
`user.initial_password`, `ldap_user_federation.bind_credential`) as those
resources land in subsequent waves; the first wave (realm only) declares
no secret attributes.
