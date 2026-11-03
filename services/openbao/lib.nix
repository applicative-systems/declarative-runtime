# hashicorp/vault provider specifics, against OpenBao: executor, resource
# surface, provider block.
#
# The resource surface is *derived* from the vendored provider schema
# (./provider-schema.json, parsed by ./schema.nix) via
# ../../modules/lib/tf-schema.nix. What stays hand-written is only what a schema
# cannot state: the reference graph between collections, the odd description
# that adds a fact, and the resources that OpenBao does not serve.
#
# Shared helpers (option helpers, renderer, reconciler) live in modules/lib.
{ pkgs, nix-tf-schema }:
let
  inherit (pkgs) lib;
  genlib = import ../../modules/lib { inherit pkgs; };
  tfSchema = import ../../modules/lib/tf-schema.nix { inherit pkgs nix-tf-schema; };
  schema = import ./schema.nix;

  provider = pkgs.terraform-providers.hashicorp_vault;
  providerVersion = provider.version;
  # provider source address; also keys the vendored provider schema.
  providerSource = "hashicorp/vault";
  runtimePrefix = "services.openbao.runtime";
  # the token that the provider authenticates with.
  tokenVar = "openbao_token";
  executor = pkgs.opentofu.withPlugins (_: [ provider ]);

  # A reference takes the key of a managed entry or a literal value, so objects
  # that OpenBao makes itself (the `token/` auth method, the `default` and
  # `root` policies) and objects managed elsewhere stay reachable.
  ref =
    targets: attrs:
    {
      inherit targets;
      managedOnly = false;
    }
    // attrs;
  on =
    field:
    map (type: {
      inherit type field;
    });

  # resources that mount a secrets engine or an auth method.
  secretsMounts = [
    "mount"
    "database_secrets_mount"
    "kubernetes_secret_backend"
    "ldap_secret_backend"
    "rabbitmq_secret_backend"
  ];
  authMounts = [
    "auth_backend"
    "jwt_auth_backend"
    "ldap_auth_backend"
  ];

  mountRef = ref (on "path" secretsMounts) { };
  authRef = ref (on "path" authMounts) { };
  # an optional `backend` of an auth method resource.
  defaultAuthRef = ref (on "path" authMounts) {
    description = "Auth method mount path. Null is the default path of the auth method type.";
  };
  accessorRef = ref (on "accessor" authMounts) { };
  policiesRef = ref (on "name" [ "policy" ]) { };
  passwordPolicyRef = ref (on "name" [ "password_policy" ]) { };
  entityRef = ref (on "id" [ "identity_entity" ]) { };
  groupRef = ref (on "id" [ "identity_group" ]) { };
  oidcKeyRef = ref (on "name" [ "identity_oidc_key" ]) { };
  oidcClientRef = ref (on "client_id" [ "identity_oidc_client" ]) { };
  # an issuer comes from a root certificate, or from an issuer that is
  # imported with an intermediate certificate.
  issuerRef = ref (on "issuer_id" [
    "pki_secret_backend_root_cert"
    "pki_secret_backend_issuer"
  ]) { };
  pkiKeyRef = ref (on "key_id" [ "pki_secret_backend_key" ]) { };
  # every PKI resource takes the path of its PKI mount.
  pki = refs: { backend = mountRef; } // refs;

  # OpenBao has namespaces, so each resource that takes a `namespace` can be
  # put in a managed one.
  namespaceRef = ref (on "path_fq" [ "namespace" ]) {
    description = "Namespace path. Null is the namespace of the provider (the root namespace).";
  };
  withNamespace =
    name: o:
    o
    // {
      refs =
        lib.optionalAttrs (schema.resource_schemas."vault_${name}".block.attributes ? namespace) {
          namespace = namespaceRef;
        }
        // o.refs or { };
    };

  # Database plugins that the provider has a block for, but that OpenBao does
  # not have built in.
  absentDatabasePlugins = [
    "couchbase"
    "elasticsearch"
    "hana"
    "mongodb"
    "mongodbatlas"
    "mssql"
    "oracle"
    "redis_elasticache"
    "redshift"
    "snowflake"
  ];

  because = reason: types: lib.genAttrs types (_: reason);
  unsupported =
    because "OpenBao does not have this secrets engine or auth method built in." [
      "ad_secret_backend"
      "ad_secret_library"
      "ad_secret_role"
      "alicloud_auth_backend_role"
      "alicloud_secret_backend"
      "alicloud_secret_backend_role"
      "aws_auth_backend_cert"
      "aws_auth_backend_client"
      "aws_auth_backend_config_identity"
      "aws_auth_backend_identity_whitelist"
      "aws_auth_backend_login"
      "aws_auth_backend_role"
      "aws_auth_backend_role_tag"
      "aws_auth_backend_roletag_blacklist"
      "aws_auth_backend_sts_role"
      "aws_secret_backend"
      "aws_secret_backend_role"
      "aws_secret_backend_static_role"
      "azure_auth_backend_config"
      "azure_auth_backend_role"
      "azure_secret_backend"
      "azure_secret_backend_role"
      "azure_secret_backend_static_role"
      "cf_auth_backend_config"
      "cf_auth_backend_role"
      "consul_secret_backend"
      "consul_secret_backend_role"
      "gcp_auth_backend"
      "gcp_auth_backend_role"
      "gcp_secret_backend"
      "gcp_secret_impersonated_account"
      "gcp_secret_roleset"
      "gcp_secret_static_account"
      "gcpkms_secret_backend"
      "gcpkms_secret_backend_key"
      "github_auth_backend"
      "github_team"
      "github_user"
      "mongodbatlas_secret_backend"
      "mongodbatlas_secret_role"
      "nomad_secret_backend"
      "nomad_secret_role"
      "oci_auth_backend"
      "oci_auth_backend_role"
      "okta_auth_backend"
      "okta_auth_backend_group"
      "okta_auth_backend_user"
      "terraform_cloud_secret_backend"
      "terraform_cloud_secret_creds"
      "terraform_cloud_secret_role"
    ]
    // because "Vault Enterprise or Vault only: OpenBao does not have this engine." [
      "keymgmt_aws_kms"
      "keymgmt_azure_kms"
      "keymgmt_distribute_key"
      "keymgmt_gcp_kms"
      "keymgmt_key"
      "keymgmt_key_rotate"
      "keymgmt_replicate_key"
      "kmip_secret_backend"
      "kmip_secret_ca_generated"
      "kmip_secret_ca_imported"
      "kmip_secret_listener"
      "kmip_secret_role"
      "kmip_secret_scope"
      "transform_alphabet"
      "transform_key_configuration"
      "transform_role"
      "transform_template"
      "transform_transformation"
      "saml_auth_backend"
      "saml_auth_backend_role"
      "scep_auth_backend_role"
      "spiffe_auth_backend_config"
      "spiffe_auth_backend_role"
      "spiffe_secret_backend_config"
      "spiffe_secret_backend_role"
      "os_secret_backend"
      "os_secret_backend_account"
      "os_secret_backend_host"
      "pki_external_ca_secret_backend_acme_account"
      "pki_external_ca_secret_backend_order"
      "pki_external_ca_secret_backend_order_certificate"
      "pki_external_ca_secret_backend_order_challenge_fulfilled"
      "pki_external_ca_secret_backend_role"
    ]
    // because "Vault Enterprise PKI enrollment protocol: OpenBao PKI does not serve it." [
      "pki_secret_backend_config_cmpv2"
      "pki_secret_backend_config_est"
      "pki_secret_backend_config_scep"
    ]
    // because "Vault Enterprise `sys/` endpoint: OpenBao does not serve it." [
      "managed_keys"
      "secrets_sync_association"
      "secrets_sync_aws_destination"
      "secrets_sync_azure_destination"
      "secrets_sync_config"
      "secrets_sync_gcp_destination"
      "secrets_sync_gh_destination"
      "secrets_sync_github_apps"
      "secrets_sync_vercel_destination"
      "egp_policy"
      "rgp_policy"
      "config_control_group"
      "config_group_policy_application"
      "activation_flags"
      "quota_lease_count"
      "raft_snapshot_agent_config"
      "plugin_pinned_version"
      "plugin_runtime"
      "config_ui_custom_message"
      "config_ui_default_auth"
      "rotation_policy"
      "oauth_resource_server_config_profile"
      "agent_registration"
    ]
    //
      because
        "Vault Enterprise step-up MFA (`sys/mfa/method`): OpenBao serves only the identity MFA methods (`identity_mfa_*`)."
        [
          "mfa_duo"
          "mfa_okta"
          "mfa_pingid"
          "mfa_totp"
        ]
    //
      because "Mints a credential that goes only into the Terraform state, where no consumer can read it."
        [
          "approle_auth_backend_login"
          "token"
          "pki_secret_backend_cert"
          "pki_secret_backend_sign"
        ]
    //
      because
        "OpenBao refuses to make an audit device through the API unless `unsafe_allow_api_audit_creation` is set. Declare audit devices in `services.openbao.settings` instead."
        [
          "audit"
        ];

  # The hashicorp/vault resource surface that OpenBao serves, keyed by resource
  # name. Per resource, only the facts the schema does not carry (see
  # modules/lib/tf-schema.nix for the full overlay vocabulary). No resource sets
  # `scope`: the provider token is a single token, and its policies decide
  # what it can do.
  generated = tfSchema.mkResourceTypes {
    inherit
      schema
      provider
      runtimePrefix
      unsupported
      ;
    source = providerSource;
    # the sdk/v2 synthetic `id` is computed.
    omitEverywhere = [ "id" ];
    resources = lib.mapAttrs withNamespace {
      # Mounts and system configuration.
      namespace.nameAttr = "path";
      mount.nameAttr = "path";
      auth_backend = {
        nameAttr = "path";
        # a list of objects, which the option conversion does not support; the
        # same settings are top-level attributes.
        omit = [ "tune" ];
        description = "Auth method mounts other than `jwt`, `oidc` and `ldap`.";
      };
      policy = { };
      password_policy = { };
      audit_request_header = { };
      config_ui_header = { };
      sys_config_cors = { };
      plugin.description = "Plugin catalog entries. The plugin binary must be in the plugin directory of the server.";
      quota_config = { };
      quota_rate_limit = { };
      raft_autopilot.description = "Raft autopilot configuration. Declare at most one. Requires the `raft` storage backend.";

      # Auth methods.
      approle_auth_backend_role = {
        nameAttr = "role_name";
        refs = {
          backend = defaultAuthRef;
          token_policies = policiesRef;
        };
      };
      approle_auth_backend_role_secret_id = {
        refs = {
          backend = defaultAuthRef;
          role_name = ref (on "role_name" [ "approle_auth_backend_role" ]) { };
        };
        description = "AppRole secret IDs. Without `secret_id`, OpenBao generates the secret ID, and it goes only into the Terraform state.";
      };
      cert_auth_backend_role.refs = {
        backend = defaultAuthRef;
        token_policies = policiesRef;
      };
      jwt_auth_backend = {
        nameAttr = "path";
        omit = [ "tune" ];
        description = "`jwt` and `oidc` auth method mounts with their configuration.";
      };
      jwt_auth_backend_role = {
        nameAttr = "role_name";
        refs = {
          backend = defaultAuthRef;
          token_policies = policiesRef;
        };
      };
      kerberos_auth_backend_config.refs.mount = authRef;
      kerberos_auth_backend_group.refs = {
        mount = authRef;
        policies = policiesRef;
      };
      kerberos_auth_backend_ldap_config.refs = {
        mount = authRef;
        token_policies = policiesRef;
      };
      kubernetes_auth_backend_config = {
        refs.backend = defaultAuthRef;
        description = "Kubernetes auth method configuration. Declare at most one per mount.";
      };
      kubernetes_auth_backend_role = {
        nameAttr = "role_name";
        refs = {
          backend = defaultAuthRef;
          token_policies = policiesRef;
        };
      };
      ldap_auth_backend = {
        nameAttr = "path";
        omit = [ "tune" ];
        refs.token_policies = policiesRef;
      };
      ldap_auth_backend_group = {
        nameAttr = "groupname";
        refs = {
          backend = defaultAuthRef;
          policies = policiesRef;
        };
      };
      ldap_auth_backend_user = {
        nameAttr = "username";
        refs = {
          backend = defaultAuthRef;
          policies = policiesRef;
        };
      };
      radius_auth_backend.refs = {
        mount = authRef;
        token_policies = policiesRef;
        unregistered_user_policies = policiesRef;
      };
      radius_auth_backend_user = {
        nameAttr = "username";
        refs = {
          mount = authRef;
          policies = policiesRef;
        };
      };
      token_auth_backend_role = {
        nameAttr = "role_name";
        refs = {
          allowed_policies = policiesRef;
          disallowed_policies = policiesRef;
          token_policies = policiesRef;
        };
      };
      userpass_auth_backend_user = {
        nameAttr = "username";
        refs = {
          mount = authRef;
          token_policies = policiesRef;
        };
      };

      # Key/value and generic secrets.
      generic_endpoint = {
        nameAttr = "path";
        description = "Writes to arbitrary API paths. The path is literal, so the write is not ordered after a managed mount.";
      };
      generic_secret = {
        nameAttr = "path";
        description = "Secrets at arbitrary paths. The path is literal, so the write is not ordered after a managed mount.";
      };
      kv_secret = {
        nameAttr = "path";
        description = "Key/value version 1 secrets at their full paths. The path is literal, so the write is not ordered after a managed mount.";
      };
      kv_secret_backend_v2 = {
        refs.mount = mountRef;
        description = "Key/value version 2 mount configuration. Declare at most one per mount.";
      };
      kv_secret_v2.refs.mount = mountRef;

      # Secrets engines.
      database_secrets_mount = {
        nameAttr = "path";
        omit = absentDatabasePlugins;
      };
      database_secret_backend_connection = {
        omit = absentDatabasePlugins;
        refs = {
          backend = mountRef;
          password_policy = passwordPolicyRef;
        };
      };
      database_secret_backend_role.refs = {
        backend = mountRef;
        db_name = ref (on "name" [ "database_secret_backend_connection" ]) { };
      };
      database_secret_backend_static_role.refs = {
        backend = mountRef;
        db_name = ref (on "name" [ "database_secret_backend_connection" ]) { };
      };
      kubernetes_secret_backend.nameAttr = "path";
      kubernetes_secret_backend_role.refs.backend = mountRef;
      ldap_secret_backend = {
        nameAttr = "path";
        refs.password_policy = passwordPolicyRef;
      };
      ldap_secret_backend_dynamic_role = {
        nameAttr = "role_name";
        refs.mount = mountRef;
      };
      ldap_secret_backend_library_set.refs.mount = mountRef;
      ldap_secret_backend_static_role = {
        nameAttr = "role_name";
        refs.mount = mountRef;
      };
      rabbitmq_secret_backend = {
        nameAttr = "path";
        refs.password_policy = passwordPolicyRef;
      };
      rabbitmq_secret_backend_role.refs.backend = mountRef;
      ssh_secret_backend_ca = {
        refs.backend = mountRef;
        description = "SSH secrets engine CA keys. Declare at most one per mount. Without `private_key`, OpenBao generates the key pair, and the private key does not leave OpenBao.";
      };
      ssh_secret_backend_role.refs.backend = mountRef;
      transit_secret_backend_key.refs.backend = mountRef;
      transit_secret_cache_config = {
        refs.backend = mountRef;
        description = "Transit secrets engine cache configuration. Declare at most one per mount.";
      };

      # PKI secrets engine.
      pki_secret_backend_key = {
        nameAttr = "key_name";
        refs = pki { };
        description = "PKI keys. A generated key does not leave OpenBao.";
      };
      pki_secret_backend_root_cert = {
        nameAttr = "issuer_name";
        refs = pki { key_ref = pkiKeyRef; };
      };
      pki_secret_backend_intermediate_cert_request = {
        refs = pki { key_ref = pkiKeyRef; };
        description = "PKI intermediate CA certificate signing requests. With `type = \"exported\"`, the private key goes only into the Terraform state.";
      };
      pki_secret_backend_root_sign_intermediate.refs = pki {
        csr = ref (on "csr" [ "pki_secret_backend_intermediate_cert_request" ]) { };
        issuer_ref = issuerRef;
      };
      pki_secret_backend_intermediate_set_signed.refs = pki {
        certificate = ref (on "certificate" [ "pki_secret_backend_root_sign_intermediate" ]) { };
      };
      pki_secret_backend_issuer.refs = pki { issuer_ref = issuerRef; };
      pki_secret_backend_role.refs = pki { issuer_ref = issuerRef; };
      pki_secret_backend_acme_eab = {
        refs = pki {
          role = ref (on "name" [ "pki_secret_backend_role" ]) { };
          issuer = issuerRef;
        };
        description = "PKI ACME external account bindings. The key goes only into the Terraform state.";
      };
      pki_secret_backend_config_acme = {
        refs = pki { };
        description = "PKI ACME configuration. Declare at most one per mount.";
      };
      pki_secret_backend_config_auto_tidy = {
        refs = pki { };
        description = "PKI automatic tidy configuration. Declare at most one per mount.";
      };
      pki_secret_backend_config_ca = {
        refs = pki { };
        description = "PKI CA bundles to import.";
      };
      pki_secret_backend_config_cluster = {
        refs = pki { };
        description = "PKI cluster URLs. Declare at most one per mount.";
      };
      pki_secret_backend_config_issuers = {
        refs = pki { default = issuerRef; };
        description = "PKI default issuer. Declare at most one per mount.";
      };
      pki_secret_backend_config_urls = {
        refs = pki { };
        description = "PKI issuing certificate, CRL and OCSP URLs. Declare at most one per mount.";
      };
      pki_secret_backend_crl_config = {
        refs = pki { };
        description = "PKI CRL configuration. Declare at most one per mount.";
      };

      # Identity.
      identity_entity.refs.policies = policiesRef;
      identity_entity_alias = {
        refs = {
          canonical_id = entityRef;
          mount_accessor = accessorRef;
        };
        description = "Identity entity aliases. The name is the name of the alias in its auth method.";
      };
      identity_entity_policies = {
        refs = {
          entity_id = entityRef;
          policies = policiesRef;
        };
        description = "Policies of an identity entity. Leave `policies` unset in `identity_entities` for an entity that this manages.";
      };
      identity_group.refs = {
        policies = policiesRef;
        member_entity_ids = entityRef;
        member_group_ids = groupRef;
      };
      identity_group_alias = {
        refs = {
          canonical_id = groupRef;
          mount_accessor = accessorRef;
        };
        description = "Identity group aliases. The name is the name of the group in its auth method.";
      };
      identity_group_member_entity_ids = {
        refs = {
          group_id = groupRef;
          member_entity_ids = entityRef;
        };
        description = "Member entities of an identity group. Set `external_member_entity_ids = true` in `identity_groups` for a group that this manages.";
      };
      identity_group_member_group_ids = {
        refs = {
          group_id = groupRef;
          member_group_ids = groupRef;
        };
        description = "Member groups of an identity group. Set `external_member_group_ids = true` in `identity_groups` for a group that this manages.";
      };
      identity_group_policies = {
        refs = {
          group_id = groupRef;
          policies = policiesRef;
        };
        description = "Policies of an identity group. Set `external_policies = true` in `identity_groups` for a group that this manages.";
      };
      identity_mfa_duo = { };
      identity_mfa_okta = { };
      identity_mfa_pingid = { };
      identity_mfa_totp = { };
      identity_mfa_login_enforcement.refs = {
        mfa_method_ids = ref (on "method_id" [
          "identity_mfa_duo"
          "identity_mfa_okta"
          "identity_mfa_pingid"
          "identity_mfa_totp"
        ]) { };
        auth_method_accessors = accessorRef;
        identity_entity_ids = entityRef;
        identity_group_ids = groupRef;
      };

      # Identity tokens and the OIDC provider.
      identity_oidc.description = "Identity token issuer configuration. Declare at most one per namespace.";
      identity_oidc_key.description = "Identity token and OIDC signing keys. To allow a managed OIDC client, use `identity_oidc_key_allowed_client_ids`: a reference from here would make a cycle with the client's `key`.";
      identity_oidc_key_allowed_client_id.refs = {
        key_name = oidcKeyRef;
        allowed_client_id = oidcClientRef;
      };
      identity_oidc_role.refs = {
        key = oidcKeyRef;
        client_id = oidcClientRef;
      };
      identity_oidc_assignment.refs = {
        entity_ids = entityRef;
        group_ids = groupRef;
      };
      identity_oidc_client = {
        refs = {
          key = oidcKeyRef;
          assignments = ref (on "name" [ "identity_oidc_assignment" ]) {
            description = "Assignments of the client. The literal `allow_all` assigns every entity and group.";
          };
        };
        description = "OIDC provider clients. The client secret goes only into the Terraform state.";
      };
      identity_oidc_scope = { };
      identity_oidc_provider.refs = {
        allowed_client_ids = oidcClientRef;
        scopes_supported = ref (on "name" [ "identity_oidc_scope" ]) { };
      };
    };
  };
  inherit (generated) resourceTypes;

  openbaoTfConfig = genlib.mkTfConfig {
    inherit
      resourceTypes
      providerVersion
      providerSource
      runtimePrefix
      tokenVar
      ;
    providerName = "vault";
    providerBlock =
      cfg:
      {
        inherit (cfg) address;
        token = "\${var.${tokenVar}}";
        # The reconciler is the only client of its token, so a child token
        # buys nothing, and it would need `auth/token/create`.
        skip_child_token = true;
      }
      // lib.optionalAttrs (cfg.caCertFile != null) { ca_cert_file = cfg.caCertFile; };
  };
in
{
  inherit
    provider
    providerSource
    resourceTypes
    openbaoTfConfig
    ;
  # the generator's drift assertions and coverage data, for the pairing's checks
  # to force independently of any particular configuration.
  inherit (generated) checks coverage;
  resourceOptions = genlib.resourceOptions resourceTypes;
  mkReconcileService = args: genlib.mkReconcileService (args // { inherit executor tokenVar; });
}
