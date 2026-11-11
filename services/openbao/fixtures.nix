# Shared fixture data for the OpenBao pairing, used by the VM integration test
# (checks.nix) and the `openbao-rendered-fixtures` package.
#
# Each fixture is a `services.openbao.runtime` collection set. The secret files
# it names (`/etc/openbao-*`) exist in the VM test; rendering never reads them.
{
  main = {
    namespace.team = { };

    mount = {
      kv = {
        type = "kv";
        options.version = "2";
      };
      pki = {
        type = "pki";
        max_lease_ttl_seconds = 315360000;
      };
      transit.type = "transit";
    };

    auth_backend = {
      userpass.type = "userpass";
      approle.type = "approle";
    };

    policy = {
      reader.policy = ''
        path "kv/data/*" {
          capabilities = ["read"]
        }
      '';
      # A policy in a managed namespace: the namespace is made first.
      team-admin = {
        namespace = "team";
        policy = ''
          path "*" {
            capabilities = ["create", "read", "update", "delete", "list"]
          }
        '';
      };
    };

    password_policy.alphanumeric.policy = ''
      length = 20
      rule "charset" {
        charset = "abcdefghijklmnopqrstuvwxyz0123456789"
      }
    '';

    userpass_auth_backend_user.alice = {
      mount = "userpass";
      password_woFile = "/etc/openbao-alice-password";
      password_wo_version = 1;
      token_policies = [ "reader" ];
    };

    approle_auth_backend_role.ci = {
      backend = "approle";
      role_id = "ci-role";
      token_policies = [ "reader" ];
    };
    approle_auth_backend_role_secret_id.ci = {
      backend = "approle";
      role_name = "ci";
      secret_idFile = "/etc/openbao-ci-secret-id";
    };

    token_auth_backend_role.deploy = {
      allowed_policies = [ "reader" ];
      orphan = true;
    };

    kv_secret_v2.app = {
      mount = "kv";
      data_jsonFile = "/etc/openbao-app-secret.json";
    };

    transit_secret_backend_key.app = {
      backend = "transit";
      type = "aes256-gcm96";
    };

    pki_secret_backend_root_cert.root = {
      backend = "pki";
      type = "internal";
      common_name = "Example Root CA";
      ttl = "87600h";
    };
    pki_secret_backend_config_urls.pki = {
      backend = "pki";
      issuing_certificates = [ "http://127.0.0.1:8200/v1/pki/ca" ];
    };
    pki_secret_backend_role.web = {
      backend = "pki";
      issuer_ref = "root";
      allowed_domains = [ "example.com" ];
      allow_subdomains = true;
    };

    identity_entity.alice.policies = [ "reader" ];
    identity_entity_alias.alice = {
      canonical_id = "alice";
      mount_accessor = "userpass";
    };
    identity_group.readers = {
      member_entity_ids = [ "alice" ];
      policies = [ "reader" ];
    };
  };
}
