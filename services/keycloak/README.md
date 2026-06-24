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

    declarative-services.url = "github:applicative-systems/terraform-providers";
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

### Realm with users, groups, an OIDC client, and an IdP

A flavoured example exercising managed-key list refs, parent refs, and
nested-secret indirection at once.

```nix
{
  services.keycloak = {
    enable = true;
    initialAdminPassword = "REPLACE_ME";
    settings.hostname = "sso.example.com";
    database.passwordFile = "/run/secrets/keycloak-db-password";

    runtime = {
      enable = true;
      bootstrapAdminPasswordFile = "/run/secrets/keycloak-admin-password";

      realms.staff = {
        display_name = "Staff SSO";
        smtp_server = {
          host = "smtp.example.com";
          from = "noreply@example.com";
          auth = {
            username = "noreply";
            passwordFile = "/run/secrets/staff-smtp-password";   # nested File
          };
        };
      };

      roles.engineer = { realm = "staff"; description = "Engineering"; };
      groups.eng     = { realm = "staff"; name = "engineering"; };

      # managed list-refs: scope/role names resolve to managed siblings
      # (built-in names like "offline_access" pass through as literals).
      default_roles.staff = {
        realm = "staff";
        default_roles = [ "engineer" "offline_access" "uma_authorization" ];
      };
      group_roles.eng = {
        realm = "staff";
        group = "eng";
        role_ids = [ "engineer" ];   # managed key, resolved to id
      };

      users.alice = {
        realm = "staff";
        username = "alice";
        email = "alice@example.com";
        # nested initial-password File:
        initial_password = {
          valueFile = "/run/secrets/staff-alice-initial-password";
          temporary = true;
        };
      };

      openid_clients.app = {
        realm = "staff";
        client_id = "app";
        access_type = "CONFIDENTIAL";
        client_secretFile = "/run/secrets/staff-app-client-secret";
        valid_redirect_uris = [ "https://app.example.com/*" ];
        web_origins        = [ "https://app.example.com" ];
        standard_flow_enabled = true;
      };

      oidc_google_identity_providers.staff_google = {
        realm = "staff";
        client_id = "google-client-id";
        client_secretFile = "/run/secrets/staff-google-secret";
      };

      attribute_importer_identity_provider_mappers.staff_google_email = {
        realm = "staff";
        identity_provider = "staff_google";   # managed IdP key
        name = "google-email";
        user_attribute = "email";
        claim_name = "email";
      };
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

Every [`keycloak/keycloak`][provider] resource is exposed as a typed
collection under `services.keycloak.runtime.<collection>.<key>`. Where a
parent reference is a managed sibling, supply the sibling's key and the
generator emits the right Terraform interpolation in apply order; where
a reference accepts either a managed key or a literal name/id (the
`managedOnly = false` form), built-in / external values just pass
through.

### Realms

| Option   | `keycloak_*` resource | Key defaults |
| -------- | --------------------- | ------------ |
| `realms` | `realm`               | `realm`      |

The `realms` collection covers ~50 flat realm attributes and the nested
blocks `smtp_server`, `internationalization`, `security_defenses`,
`otp_policy`, `web_authn_policy`, `web_authn_passwordless_policy`.

### Roles, groups, users

| Option              | `keycloak_*` resource | Key defaults | Reference inputs                              |
| ------------------- | --------------------- | ------------ | --------------------------------------------- |
| `roles`             | `role`                | `name`       | `realm`, `composite_roles` → roles            |
| `default_roles`     | `default_roles`       | —            | `realm`, `default_roles` → roles              |
| `groups`            | `group`               | `name`       | `realm`, `parent` → groups                    |
| `default_groups`    | `default_groups`      | —            | `realm`, `group_ids` → groups                 |
| `group_memberships` | `group_memberships`   | —            | `realm`, `group` → groups, `members` → users  |
| `group_roles`       | `group_roles`         | —            | `realm`, `group` → groups, `role_ids` → roles |
| `users`             | `user`                | `username`   | `realm`                                       |
| `user_roles`        | `user_roles`          | —            | `realm`, `user` → users, `role_ids` → roles   |
| `user_groups`       | `user_groups`         | —            | `realm`, `user` → users, `group_ids` → groups |

### Clients, scopes, service accounts

| Option                                      | `keycloak_*` resource                      | Key defaults | Reference inputs                                                             |
| ------------------------------------------- | ------------------------------------------ | ------------ | ---------------------------------------------------------------------------- |
| `openid_clients`                            | `openid_client`                            | `client_id`  | `realm`                                                                      |
| `openid_client_scopes`                      | `openid_client_scope`                      | `name`       | `realm`                                                                      |
| `openid_client_default_scopes`              | `openid_client_default_scopes`             | —            | `realm`, `client` → openid_clients, `default_scopes` → openid_client_scopes  |
| `openid_client_optional_scopes`             | `openid_client_optional_scopes`            | —            | `realm`, `client` → openid_clients, `optional_scopes` → openid_client_scopes |
| `openid_client_service_account_roles`       | `openid_client_service_account_role`       | —            | `realm`, `client` → openid_clients (target)                                  |
| `openid_client_service_account_realm_roles` | `openid_client_service_account_realm_role` | —            | `realm`                                                                      |
| `openid_client_permissions`                 | `openid_client_permissions`                | —            | `realm`, `client` → openid_clients                                           |
| `saml_clients`                              | `saml_client`                              | `client_id`  | `realm`                                                                      |
| `saml_client_scopes`                        | `saml_client_scope`                        | `name`       | `realm`                                                                      |
| `saml_client_default_scopes`                | `saml_client_default_scopes`               | —            | `realm`, `client` → saml_clients, `default_scopes` → saml_client_scopes      |

### Protocol mappers (OpenID, SAML, generic)

OpenID mappers (`realm` + optional `client` → openid_clients +
optional `client_scope` → openid_client_scopes):

| Option                                      | `keycloak_*` resource                      |
| ------------------------------------------- | ------------------------------------------ |
| `openid_user_attribute_protocol_mappers`    | `openid_user_attribute_protocol_mapper`    |
| `openid_user_property_protocol_mappers`     | `openid_user_property_protocol_mapper`     |
| `openid_group_membership_protocol_mappers`  | `openid_group_membership_protocol_mapper`  |
| `openid_full_name_protocol_mappers`         | `openid_full_name_protocol_mapper`         |
| `openid_sub_protocol_mappers`               | `openid_sub_protocol_mapper`               |
| `openid_hardcoded_claim_protocol_mappers`   | `openid_hardcoded_claim_protocol_mapper`   |
| `openid_audience_protocol_mappers`          | `openid_audience_protocol_mapper`          |
| `openid_audience_resolve_protocol_mappers`  | `openid_audience_resolve_protocol_mapper`  |
| `openid_hardcoded_role_protocol_mappers`    | `openid_hardcoded_role_protocol_mapper`    |
| `openid_user_realm_role_protocol_mappers`   | `openid_user_realm_role_protocol_mapper`   |
| `openid_user_client_role_protocol_mappers`  | `openid_user_client_role_protocol_mapper`  |
| `openid_user_session_note_protocol_mappers` | `openid_user_session_note_protocol_mapper` |
| `openid_script_protocol_mappers`            | `openid_script_protocol_mapper`            |

SAML mappers (`realm` + optional `client` → saml_clients + optional
`client_scope` → saml_client_scopes):

| Option                                 | `keycloak_*` resource                 |
| -------------------------------------- | ------------------------------------- |
| `saml_user_attribute_protocol_mappers` | `saml_user_attribute_protocol_mapper` |
| `saml_user_property_protocol_mappers`  | `saml_user_property_protocol_mapper`  |
| `saml_script_protocol_mappers`         | `saml_script_protocol_mapper`         |

Generic mappers (`realm` + optional `client` → openid/saml clients +
optional `client_scope` → openid/saml client_scopes, multi-target):

| Option                            | `keycloak_*` resource            |
| --------------------------------- | -------------------------------- |
| `generic_protocol_mappers`        | `generic_protocol_mapper`        |
| `generic_client_protocol_mappers` | `generic_client_protocol_mapper` |
| `generic_role_mappers`            | `generic_role_mapper`            |
| `generic_client_role_mappers`     | `generic_client_role_mapper`     |

### Identity providers + mappers

| Option                             | `keycloak_*` resource             | Key defaults | Reference inputs        |
| ---------------------------------- | --------------------------------- | ------------ | ----------------------- |
| `oidc_identity_providers`          | `oidc_identity_provider`          | `alias`      | `realm` (by realm name) |
| `saml_identity_providers`          | `saml_identity_provider`          | `alias`      | `realm` (by realm name) |
| `oidc_google_identity_providers`   | `oidc_google_identity_provider`   | `alias`      | `realm` (by realm name) |
| `oidc_facebook_identity_providers` | `oidc_facebook_identity_provider` | `alias`      | `realm` (by realm name) |
| `oidc_github_identity_providers`   | `oidc_github_identity_provider`   | `alias`      | `realm` (by realm name) |
| `kubernetes_identity_providers`    | `kubernetes_identity_provider`    | `alias`      | `realm` (by realm name) |

Identity-provider mappers (`realm` + `identity_provider` → any IdP
collection, multi-target with literal fallback):

| Option                                             | `keycloak_*` resource                             |
| -------------------------------------------------- | ------------------------------------------------- |
| `hardcoded_attribute_identity_provider_mappers`    | `hardcoded_attribute_identity_provider_mapper`    |
| `hardcoded_group_identity_provider_mappers`        | `hardcoded_group_identity_provider_mapper`        |
| `hardcoded_role_identity_provider_mappers`         | `hardcoded_role_identity_provider_mapper`         |
| `attribute_importer_identity_provider_mappers`     | `attribute_importer_identity_provider_mapper`     |
| `attribute_to_role_identity_provider_mappers`      | `attribute_to_role_identity_provider_mapper`      |
| `user_template_importer_identity_provider_mappers` | `user_template_importer_identity_provider_mapper` |
| `custom_identity_provider_mappers`                 | `custom_identity_provider_mapper`                 |

### Authentication

| Option                             | `keycloak_*` resource             | Key defaults | Reference inputs                                                                       |
| ---------------------------------- | --------------------------------- | ------------ | -------------------------------------------------------------------------------------- |
| `authentication_flows`             | `authentication_flow`             | `alias`      | `realm`                                                                                |
| `authentication_subflows`          | `authentication_subflow`          | `alias`      | `realm`, `parent_flow` → authentication_flows / authentication_subflows (multi-target) |
| `authentication_executions`        | `authentication_execution`        | —            | `realm`, `parent_flow` → authentication_flows / authentication_subflows (multi-target) |
| `authentication_execution_configs` | `authentication_execution_config` | `alias`      | `realm`, `execution` → authentication_executions                                       |
| `authentication_bindings`          | `authentication_bindings`         | —            | `realm`                                                                                |

### Authorization (per-client fine-grained)

| Option                                              | `keycloak_*` resource                             | Key defaults |
| --------------------------------------------------- | ------------------------------------------------- | ------------ |
| `openid_client_authorization_resources`             | `openid_client_authorization_resource`            | `name`       |
| `openid_client_authorization_scopes`                | `openid_client_authorization_scope`               | `name`       |
| `openid_client_authorization_permissions`           | `openid_client_authorization_permission`          | `name`       |
| `openid_client_authorization_aggregate_policies`    | `openid_client_authorization_aggregate_policy`    | `name`       |
| `openid_client_authorization_client_policies`       | `openid_client_authorization_client_policy`       | `name`       |
| `openid_client_authorization_client_scope_policies` | `openid_client_authorization_client_scope_policy` | `name`       |
| `openid_client_authorization_group_policies`        | `openid_client_authorization_group_policy`        | `name`       |
| `openid_client_authorization_js_policies`           | `openid_client_authorization_js_policy`           | `name`       |
| `openid_client_authorization_role_policies`         | `openid_client_authorization_role_policy`         | `name`       |
| `openid_client_authorization_time_policies`         | `openid_client_authorization_time_policy`         | `name`       |
| `openid_client_authorization_user_policies`         | `openid_client_authorization_user_policy`         | `name`       |

All authz resources share `realm` + `resource_server` → openid_clients
(the latter resolves to the client's computed `resource_server_id`,
populated once `services.keycloak.runtime.openid_clients.<key>.authorization`
is set).

### Federation

LDAP (`realm` + `ldap_user_federation` → ldap_user_federations for the
mappers):

| Option                                       | `keycloak_*` resource                       | Key defaults |
| -------------------------------------------- | ------------------------------------------- | ------------ |
| `ldap_user_federations`                      | `ldap_user_federation`                      | `name`       |
| `ldap_user_attribute_mappers`                | `ldap_user_attribute_mapper`                | `name`       |
| `ldap_group_mappers`                         | `ldap_group_mapper`                         | `name`       |
| `ldap_role_mappers`                          | `ldap_role_mapper`                          | `name`       |
| `ldap_hardcoded_role_mappers`                | `ldap_hardcoded_role_mapper`                | `name`       |
| `ldap_hardcoded_attribute_mappers`           | `ldap_hardcoded_attribute_mapper`           | `name`       |
| `ldap_hardcoded_group_mappers`               | `ldap_hardcoded_group_mapper`               | `name`       |
| `ldap_msad_user_account_control_mappers`     | `ldap_msad_user_account_control_mapper`     | `name`       |
| `ldap_msad_lds_user_account_control_mappers` | `ldap_msad_lds_user_account_control_mapper` | `name`       |
| `ldap_full_name_mappers`                     | `ldap_full_name_mapper`                     | `name`       |
| `ldap_custom_mappers`                        | `ldap_custom_mapper`                        | `name`       |

Other federation:

| Option                        | `keycloak_*` resource        | Key defaults | Reference inputs                                        |
| ----------------------------- | ---------------------------- | ------------ | ------------------------------------------------------- |
| `custom_user_federations`     | `custom_user_federation`     | `name`       | `realm`                                                 |
| `hardcoded_attribute_mappers` | `hardcoded_attribute_mapper` | `name`       | `realm`, `ldap_user_federation` → ldap_user_federations |

### Realm keys

| Option                            | `keycloak_*` resource            | Key defaults | Reference inputs |
| --------------------------------- | -------------------------------- | ------------ | ---------------- |
| `realm_keystore_aes_generateds`   | `realm_keystore_aes_generated`   | `name`       | `realm`          |
| `realm_keystore_ecdsa_generateds` | `realm_keystore_ecdsa_generated` | `name`       | `realm`          |
| `realm_keystore_hmac_generateds`  | `realm_keystore_hmac_generated`  | `name`       | `realm`          |
| `realm_keystore_java_keystores`   | `realm_keystore_java_keystore`   | `name`       | `realm`          |
| `realm_keystore_rsas`             | `realm_keystore_rsa`             | `name`       | `realm`          |
| `realm_keystore_rsa_generateds`   | `realm_keystore_rsa_generated`   | `name`       | `realm`          |

### Realm-level config + permissions

| Option                                               | `keycloak_*` resource                               | Key defaults | Reference inputs                                                      |
| ---------------------------------------------------- | --------------------------------------------------- | ------------ | --------------------------------------------------------------------- |
| `required_actions`                                   | `required_action`                                   | `alias`      | `realm`                                                               |
| `realm_events`                                       | `realm_events`                                      | —            | `realm`                                                               |
| `realm_localizations`                                | `realm_localization`                                | `locale`     | `realm`                                                               |
| `realm_default_client_scopes`                        | `realm_default_client_scopes`                       | —            | `realm`, `default_scopes` → openid/saml client_scopes (multi-target)  |
| `realm_optional_client_scopes`                       | `realm_optional_client_scopes`                      | —            | `realm`, `optional_scopes` → openid/saml client_scopes (multi-target) |
| `organizations`                                      | `organization`                                      | `name`       | `realm` (by realm name)                                               |
| `identity_provider_token_exchange_scope_permissions` | `identity_provider_token_exchange_scope_permission` | —            | `realm`                                                               |
| `realm_user_profiles`                                | `realm_user_profile`                                | —            | `realm`                                                               |
| `realm_client_policy_profiles`                       | `realm_client_policy_profile`                       | `name`       | `realm`                                                               |
| `realm_client_policy_profile_policies`               | `realm_client_policy_profile_policy`                | `name`       | `realm`, `profiles` → realm_client_policy_profiles                    |
| `group_permissions`                                  | `group_permissions`                                 | —            | `realm`, `group` → groups                                             |
| `users_permissions`                                  | `users_permissions`                                 | —            | `realm`                                                               |

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
placeholders.

The same `<attr>` / `<attr>File` mechanism protects every secret-valued
resource attribute — including nested-Sensitive fields buried inside
submodules, at any depth. Examples:

- `openid_clients.<k>.client_secret` ↔ `client_secretFile`
- `users.<k>.initial_password.value` ↔ `valueFile` (nested)
- `realms.<k>.smtp_server.auth.password` ↔ `passwordFile` (nested)
- `realms.<k>.smtp_server.token_auth.client_secret` ↔ `client_secretFile` (nested)
- `ldap_user_federations.<k>.bind_credential` ↔ `bind_credentialFile`
- `realm_keystore_rsas.<k>.private_key` ↔ `private_keyFile`
- `realm_keystore_java_keystores.<k>.{keystore_password,key_password}` ↔ `*File`
- `oidc_*_identity_providers.<k>.client_secret` ↔ `client_secretFile`
- `saml_clients.<k>.signing_private_key` ↔ `signing_private_keyFile`

For each, set either the literal _or_ its `File` sibling (they're
mutually exclusive). The renderer walks the value tree at apply time,
substitutes a sensitive Terraform variable at the nested location, and
collects the host path into the credentials map so systemd
`LoadCredential=` can read it.
