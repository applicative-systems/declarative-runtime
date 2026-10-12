# OpenBao pairing

Declaratively manage an [OpenBao](https://openbao.org) server's **runtime
state** (namespaces, mounts, auth methods, policies, secrets, PKI, identity
and more) from NixOS, on top of the upstream `services.openbao` module,
through the [`hashicorp/vault`][provider] provider. OpenBao is a fork of
Vault and serves the same API, so the Vault provider manages it.

[provider]: https://registry.terraform.io/providers/hashicorp/vault/latest/docs

## Installation

### Include the module

Add this flake as an input and import its `nixosModules.openbao` into your
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
          declarative-runtime.nixosModules.openbao
          ./host.nix
        ];
      };
    };
}
```

### Requirements

- **An initialized, unsealed server.** OpenBao starts sealed, and a new
  server is not initialized. Initialization (`bao operator init`) and
  unsealing (by hand, or by an auto-unseal `seal` in
  `services.openbao.settings`) stay with the operator. The reconciler waits
  until `/v1/sys/health` reports an active, unsealed server, so order an
  unseal unit before `declarative-openbao.service` when you have one.
- **A token in a file** (`tokenFile`). OpenBao cannot make a credential for
  the reconciler before it is initialized, so there is no bootstrap step: give
  a token whose policies allow every change that the declared state makes.
  The root token works, but a token with a narrower policy is safer.

## Configuration examples

Set `services.openbao.enable = true` (the module asserts it) and declare the
runtime state under `services.openbao.runtime`. Each entry's attributes are
**typed options** named after the upstream resource's snake_case attributes
(validated at `nix flake check`; an unknown name or wrong type is a build
error). A reference to a mount, policy, entity, issuer or other managed
object takes the object's key, which resolves to a correctly ordered
Terraform reference.

Those options are **derived from the provider's own schema** rather than
hand-written, so they track the pinned provider exactly - see
[Provider updates](#provider-updates).

### Mounts, policies and users

```nix
services.openbao = {
  enable = true;
  settings = {
    listener.default = {
      type = "tcp";
      tls_cert_file = "/run/secrets/openbao-cert.pem";
      tls_key_file = "/run/secrets/openbao-key.pem";
    };
    storage.raft.path = "/var/lib/openbao";
  };
  runtime = {
    enable = true;
    # The address defaults to the first TCP listener.
    tokenFile = "/run/secrets/openbao-token";

    mounts.kv = {
      type = "kv";
      options.version = "2";
    };
    auth_backends.userpass.type = "userpass";
    policies.reader.policy = ''
      path "kv/data/*" {
        capabilities = ["read"]
      }
    '';
    userpass_auth_backend_users.alice = {
      mount = "userpass";
      password_woFile = "/run/secrets/openbao-alice-password";
      password_wo_version = 1;
      token_policies = [ "reader" ];
    };
    kv_secret_v2s.app = {
      mount = "kv";
      data_jsonFile = "/run/secrets/openbao-app-secret.json";
    };
  };
};
```

### Namespaces

A resource that takes a `namespace` can name a managed namespace by its key.
Null is the namespace of the provider, which is the root namespace.

```nix
services.openbao.runtime = {
  namespaces.team = { };
  policies.team-admin = {
    namespace = "team";
    policy = ''
      path "*" {
        capabilities = ["create", "read", "update", "delete", "list"]
      }
    '';
  };
};
```

### PKI

A role's `issuer_ref` names a managed root certificate or issuer by its key.

```nix
services.openbao.runtime = {
  mounts.pki = {
    type = "pki";
    max_lease_ttl_seconds = 315360000;
  };
  pki_secret_backend_root_certs.root = {
    backend = "pki";
    type = "internal";
    common_name = "Example Root CA";
    ttl = "87600h";
  };
  pki_secret_backend_roles.web = {
    backend = "pki";
    issuer_ref = "root";
    allowed_domains = [ "example.com" ];
    allow_subdomains = true;
  };
};
```

### Identity

An entity alias names a managed entity and a managed auth method by their
keys. The alias links logins on that auth method to the entity.

```nix
services.openbao.runtime = {
  identity_entities.alice.policies = [ "reader" ];
  identity_entity_alias.alice = {
    canonical = "alice";
    mount_accessor = "userpass";
  };
  identity_groups.readers.member_entitys = [ "alice" ];
};
```

## Module options (`services.openbao.runtime`)

| Option       | Type        | Default                          | Purpose                                                                                |
| ------------ | ----------- | -------------------------------- | -------------------------------------------------------------------------------------- |
| `enable`     | bool        | `false`                          | Turn on the reconciler.                                                                |
| `address`    | null or str | first TCP listener in `settings` | OpenBao API address the provider targets. `http` when the listener sets `tls_disable`. |
| `caCertFile` | null or str | `null`                           | Host path to the CA of the server certificate. Null trusts the system CA bundle.       |
| `tokenFile`  | null or str | `null`                           | Host path to an OpenBao token (read via `LoadCredential=`, not stored). Required.      |

Plus one collection option per provider resource (next section).

## Resources

The [`hashicorp/vault`][provider] resources that OpenBao serves are exposed
as collections keyed by a handle, which must be a valid Terraform identifier.
What each collection accepts comes from the vendored provider schema, not
from this table: the authoritative option list is

```sh
nix build .#checks.x86_64-linux.openbao-options-doc     # every option, typed
nix build .#checks.x86_64-linux.openbao-schema-coverage # what is covered
```

| Option                                          | `vault_*` resource                             | Key defaults  |
| ----------------------------------------------- | ---------------------------------------------- | ------------- |
| `namespaces`                                    | `namespace`                                    | `path`        |
| `mounts`                                        | `mount`                                        | `path`        |
| `auth_backends`                                 | `auth_backend`                                 | `path`        |
| `policies`                                      | `policy`                                       | `name`        |
| `password_policies`                             | `password_policy`                              | `name`        |
| `audit_request_headers`                         | `audit_request_header`                         | `name`        |
| `config_ui_headers`                             | `config_ui_header`                             | `name`        |
| `sys_config_cors`                               | `sys_config_cors`                              | -             |
| `plugins`                                       | `plugin`                                       | `name`        |
| `quota_configs`                                 | `quota_config`                                 | -             |
| `quota_rate_limits`                             | `quota_rate_limit`                             | `name`        |
| `raft_autopilots`                               | `raft_autopilot`                               | -             |
| `approle_auth_backend_roles`                    | `approle_auth_backend_role`                    | `role_name`   |
| `approle_auth_backend_role_secret_ids`          | `approle_auth_backend_role_secret_id`          | -             |
| `cert_auth_backend_roles`                       | `cert_auth_backend_role`                       | `name`        |
| `jwt_auth_backends`                             | `jwt_auth_backend`                             | `path`        |
| `jwt_auth_backend_roles`                        | `jwt_auth_backend_role`                        | `role_name`   |
| `kerberos_auth_backend_configs`                 | `kerberos_auth_backend_config`                 | -             |
| `kerberos_auth_backend_groups`                  | `kerberos_auth_backend_group`                  | `name`        |
| `kerberos_auth_backend_ldap_configs`            | `kerberos_auth_backend_ldap_config`            | -             |
| `kubernetes_auth_backend_configs`               | `kubernetes_auth_backend_config`               | -             |
| `kubernetes_auth_backend_roles`                 | `kubernetes_auth_backend_role`                 | `role_name`   |
| `ldap_auth_backends`                            | `ldap_auth_backend`                            | `path`        |
| `ldap_auth_backend_groups`                      | `ldap_auth_backend_group`                      | `groupname`   |
| `ldap_auth_backend_users`                       | `ldap_auth_backend_user`                       | `username`    |
| `radius_auth_backends`                          | `radius_auth_backend`                          | -             |
| `radius_auth_backend_users`                     | `radius_auth_backend_user`                     | `username`    |
| `token_auth_backend_roles`                      | `token_auth_backend_role`                      | `role_name`   |
| `userpass_auth_backend_users`                   | `userpass_auth_backend_user`                   | `username`    |
| `generic_endpoints`                             | `generic_endpoint`                             | `path`        |
| `generic_secrets`                               | `generic_secret`                               | `path`        |
| `kv_secrets`                                    | `kv_secret`                                    | `path`        |
| `kv_secret_backend_v2s`                         | `kv_secret_backend_v2`                         | -             |
| `kv_secret_v2s`                                 | `kv_secret_v2`                                 | `name`        |
| `database_secrets_mounts`                       | `database_secrets_mount`                       | `path`        |
| `database_secret_backend_connections`           | `database_secret_backend_connection`           | `name`        |
| `database_secret_backend_roles`                 | `database_secret_backend_role`                 | `name`        |
| `database_secret_backend_static_roles`          | `database_secret_backend_static_role`          | `name`        |
| `kubernetes_secret_backends`                    | `kubernetes_secret_backend`                    | `path`        |
| `kubernetes_secret_backend_roles`               | `kubernetes_secret_backend_role`               | `name`        |
| `ldap_secret_backends`                          | `ldap_secret_backend`                          | `path`        |
| `ldap_secret_backend_dynamic_roles`             | `ldap_secret_backend_dynamic_role`             | `role_name`   |
| `ldap_secret_backend_library_sets`              | `ldap_secret_backend_library_set`              | `name`        |
| `ldap_secret_backend_static_roles`              | `ldap_secret_backend_static_role`              | `role_name`   |
| `rabbitmq_secret_backends`                      | `rabbitmq_secret_backend`                      | `path`        |
| `rabbitmq_secret_backend_roles`                 | `rabbitmq_secret_backend_role`                 | `name`        |
| `ssh_secret_backend_cas`                        | `ssh_secret_backend_ca`                        | -             |
| `ssh_secret_backend_roles`                      | `ssh_secret_backend_role`                      | `name`        |
| `transit_secret_backend_keys`                   | `transit_secret_backend_key`                   | `name`        |
| `transit_secret_cache_configs`                  | `transit_secret_cache_config`                  | -             |
| `pki_secret_backend_keys`                       | `pki_secret_backend_key`                       | `key_name`    |
| `pki_secret_backend_root_certs`                 | `pki_secret_backend_root_cert`                 | `issuer_name` |
| `pki_secret_backend_intermediate_cert_requests` | `pki_secret_backend_intermediate_cert_request` | -             |
| `pki_secret_backend_root_sign_intermediates`    | `pki_secret_backend_root_sign_intermediate`    | -             |
| `pki_secret_backend_intermediate_set_signeds`   | `pki_secret_backend_intermediate_set_signed`   | -             |
| `pki_secret_backend_issuers`                    | `pki_secret_backend_issuer`                    | -             |
| `pki_secret_backend_roles`                      | `pki_secret_backend_role`                      | `name`        |
| `pki_secret_backend_acme_eabs`                  | `pki_secret_backend_acme_eab`                  | -             |
| `pki_secret_backend_config_acmes`               | `pki_secret_backend_config_acme`               | -             |
| `pki_secret_backend_config_auto_tidies`         | `pki_secret_backend_config_auto_tidy`          | -             |
| `pki_secret_backend_config_cas`                 | `pki_secret_backend_config_ca`                 | -             |
| `pki_secret_backend_config_clusters`            | `pki_secret_backend_config_cluster`            | -             |
| `pki_secret_backend_config_issuers`             | `pki_secret_backend_config_issuers`            | -             |
| `pki_secret_backend_config_urls`                | `pki_secret_backend_config_urls`               | -             |
| `pki_secret_backend_crl_configs`                | `pki_secret_backend_crl_config`                | -             |
| `identity_entities`                             | `identity_entity`                              | `name`        |
| `identity_entity_alias`                         | `identity_entity_alias`                        | `name`        |
| `identity_entity_policies`                      | `identity_entity_policies`                     | -             |
| `identity_groups`                               | `identity_group`                               | `name`        |
| `identity_group_alias`                          | `identity_group_alias`                         | `name`        |
| `identity_group_member_entity_ids`              | `identity_group_member_entity_ids`             | -             |
| `identity_group_member_group_ids`               | `identity_group_member_group_ids`              | -             |
| `identity_group_policies`                       | `identity_group_policies`                      | -             |
| `identity_mfa_duos`                             | `identity_mfa_duo`                             | -             |
| `identity_mfa_oktas`                            | `identity_mfa_okta`                            | -             |
| `identity_mfa_pingids`                          | `identity_mfa_pingid`                          | -             |
| `identity_mfa_totps`                            | `identity_mfa_totp`                            | -             |
| `identity_mfa_login_enforcements`               | `identity_mfa_login_enforcement`               | `name`        |
| `identity_oidcs`                                | `identity_oidc`                                | -             |
| `identity_oidc_keys`                            | `identity_oidc_key`                            | `name`        |
| `identity_oidc_key_allowed_client_ids`          | `identity_oidc_key_allowed_client_id`          | -             |
| `identity_oidc_roles`                           | `identity_oidc_role`                           | `name`        |
| `identity_oidc_assignments`                     | `identity_oidc_assignment`                     | `name`        |
| `identity_oidc_clients`                         | `identity_oidc_client`                         | `name`        |
| `identity_oidc_scopes`                          | `identity_oidc_scope`                          | `name`        |
| `identity_oidc_providers`                       | `identity_oidc_provider`                       | `name`        |

### References

These attributes take the key of a managed object, or a literal value for an
object that is managed elsewhere. The option has the name of the attribute,
with `_ids` changed to `s` and without an `_id` or `_alias` suffix:
`canonical_id` is `canonical`, and `member_entity_ids` is `member_entitys`.

- `namespace`: a namespace in `namespaces`.
- `backend` or `mount` of a secrets engine: a mount in `mounts`,
  `database_secrets_mounts`, `kubernetes_secret_backends`,
  `ldap_secret_backends` or `rabbitmq_secret_backends`.
- `backend` or `mount` of an auth method: an auth method in `auth_backends`,
  `jwt_auth_backends` or `ldap_auth_backends`. `mount_accessor` and
  `auth_method_accessors` take the same keys, and resolve to the accessor.
- Policy lists (`policies`, `token_policies`, `allowed_policies` and others):
  policies in `policies`, or literal names such as `default`.
- `password_policy`: a policy in `password_policies`.
- Entity and group IDs: entities in `identity_entities`, groups in
  `identity_groups`.
- `issuer_ref`: a root certificate in `pki_secret_backend_root_certs` or an
  issuer in `pki_secret_backend_issuers`. PKI key references take a key in
  `pki_secret_backend_keys`.
- OIDC keys and clients: keys in `identity_oidc_keys`, clients in
  `identity_oidc_clients`.
- Database roles take a connection in
  `database_secret_backend_connections`, and AppRole secret IDs take a role
  in `approle_auth_backend_roles`.

### Unsupported resources

The provider also manages Vault features that OpenBao does not have. The
pairing's `unsupported` set in `lib.nix` lists each one with its reason:

- Secrets engines and auth methods that OpenBao does not have built in, such
  as AWS, Azure, GCP, GitHub, Okta and Consul.
- Vault Enterprise features: KMIP, key management, transform, Sentinel
  policies, secrets sync, control groups, step-up MFA (`vault_mfa_*`; use
  `identity_mfa_*`), and the PKI enrollment protocols.
- `vault_token`, `vault_approle_auth_backend_login`,
  `vault_pki_secret_backend_cert` and `vault_pki_secret_backend_sign`: they
  make a credential that goes only into the Terraform state, where no consumer
  can read it.
- `vault_audit`: OpenBao refuses to make an audit device through the API
  unless `unsafe_allow_api_audit_creation` is set. Declare audit devices in
  `services.openbao.settings` instead.

The database collections leave out the plugin blocks of the databases that
OpenBao does not have built in. The blocks that stay are `cassandra`,
`influxdb`, `mysql`, `mysql_aurora`, `mysql_legacy`, `mysql_rds`,
`postgresql` and `redis`.

## Limitations

- `generic_endpoints`, `generic_secrets` and `kv_secrets` take a literal path,
  so their writes are not ordered after a managed mount. For key/value
  secrets, prefer `kv_secret_v2s`, whose `mount` is a reference.
- A write-only attribute (`*_wo`) is not in the state, so the provider cannot
  see a change to it. Increase its `*_wo_version` to write a new value.
- A TTL attribute of type number (such as `token_ttl`) takes a number of
  seconds, not a duration such as `"1h"`.
- The provider supports fields that only recent Vault versions have, for
  example the rotation fields of database connections. OpenBao ignores them.
- `identity_oidc_keys` has no reference for `allowed_client_ids`: a reference
  from a key to a client would make a cycle with the client's `key`. Use
  `identity_oidc_key_allowed_client_ids` to allow a managed client.

## State

The reconciler runs as a systemd dynamic user of its own
(`declarative-openbao`) and keeps its Terraform state in
`/var/lib/declarative-openbao/declarative-terraform`. The state holds the
secrets that the declared resources write or read, such as key/value secret
data, AppRole secret IDs and private keys.

## Provider updates

The option surface is generated from `provider-schema.json`, a normalized
dump of the pinned provider's schema, committed next to `module.nix`. The
provider itself comes from nixpkgs, so it moves when the flake's `nixpkgs`
input does; after such a bump:

```sh
nix run .#update-provider-schemas
nix flake check
```

The check names every difference the bump introduces: resources added or
removed, attributes added, removed or retyped, and any correction in
`lib.nix` that no longer matches the schema. A new resource must either be
modelled or listed in the pairing's `unsupported` set with a reason - it
cannot be ignored.

An upstream attribute that becomes **required** turns into a required
option, which fails evaluation for configurations that never set it. That
is usually the right signal, but `forceOptional` in the collection's
overlay is the release valve when it is not.

## Security note

Each secret-valued _resource_ attribute (for example `password_wo` on
`userpass_auth_backend_users`, `data_json` on `kv_secret_v2s` and
`secret_id` on `approle_auth_backend_role_secret_ids`) accepts a `<attr>File`
form that takes a **host file path** instead of the literal value. The file
is read at apply time via systemd `LoadCredential=` into a sensitive
Terraform variable and **never enters the Nix store**; the generated
`.tf.json` holds only a `${var....}` reference (the same mechanism that
protects the provider token). Setting the attribute _literally_ still works,
but renders the value verbatim into the **world-readable** `.tf.json` store
path. The two forms are mutually exclusive.
