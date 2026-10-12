# OpenBao pairing check, returned as a single-entry attrset merged into the
# flake's per-system `checks`.
#
#   openbao - Full integration test: boots a VM with services.openbao +
#     services.openbao.runtime and lets the pairing converge at boot. A
#     companion oneshot initializes and unseals the server and writes the root
#     token, which an operator does once when the server is set up; then the
#     run-once reconciler applies the config. Users, roles, keys and identities
#     reference mounts, policies, issuers and entities by their keys, so a
#     successful apply proves reference resolution and apply ordering. A user
#     password, an AppRole secret ID and a key/value secret given as host files
#     also prove per-secret credential indirection - each value is loaded from
#     a host file and kept out of the generated `.tf.json`. Requires KVM (a
#     NixOS VM test).
{ pkgs, self }:
let
  fixtures = import ./fixtures.nix;
  address = "http://127.0.0.1:8200";
  tokenFile = "/var/lib/openbao-init/root-token";
  alicePassword = "alice-hackme";
  ciSecretId = "ci-hackme";
  appSecret = {
    username = "app";
    password = "app-hackme";
  };
in
{
  openbao = pkgs.testers.runNixOSTest {
    name = "declarative-openbao";

    nodes.machine =
      { config, pkgs, ... }:
      {
        imports = [ self.nixosModules.default ];

        environment.systemPackages = [
          config.services.openbao.package
          pkgs.jq
        ];

        # mock agenix secrets, fed to the reconciler via LoadCredential.
        environment.etc."openbao-alice-password".text = alicePassword;
        environment.etc."openbao-ci-secret-id".text = ciSecretId;
        environment.etc."openbao-app-secret.json".text = builtins.toJSON appSecret;

        services.openbao = {
          enable = true;
          settings = {
            listener.default = {
              type = "tcp";
              tls_disable = true;
            };
            api_addr = address;
            cluster_addr = "http://127.0.0.1:8201";
            storage.raft.path = "/var/lib/openbao";
          };

          # No address: it defaults to the TCP listener.
          runtime = {
            enable = true;
            inherit tokenFile;
          }
          // fixtures.main;
        };

        # A new server is not initialized, and it is sealed after each start.
        # An operator initializes it once and unseals it after each start;
        # here a oneshot does both before the reconciler runs. A single key
        # share is enough for a test, not for a real server.
        systemd.services.openbao-init = {
          after = [ "openbao.service" ];
          requires = [ "openbao.service" ];
          before = [ "declarative-openbao.service" ];
          requiredBy = [ "declarative-openbao.service" ];
          path = [
            pkgs.curl
            pkgs.jq
          ];
          environment.BAO_ADDR = address;
          serviceConfig = {
            Type = "oneshot";
            RemainAfterExit = true;
            StateDirectory = "openbao-init";
            StateDirectoryMode = "0700";
            UMask = "0077";
          };
          script = ''
            until curl -fsS -o /dev/null "$BAO_ADDR/v1/sys/seal-status"; do sleep 1; done
            init="$STATE_DIRECTORY/init.json"
            if [ ! -e "$init" ]; then
              curl -fsS -X PUT -d '{"secret_shares":1,"secret_threshold":1}' \
                "$BAO_ADDR/v1/sys/init" > "$init.new"
              mv "$init.new" "$init"
            fi
            jq '{key: .keys_base64[0]}' "$init" \
              | curl -fsS -o /dev/null -X PUT -d @- "$BAO_ADDR/v1/sys/unseal"
            jq -r .root_token "$init" > ${tokenFile}
          '';
        };

        virtualisation.memorySize = 2048;
      };

    testScript = ''
      import json

      root = None

      # The CLI reads flags only before the first argument, so the format
      # flag goes directly after the subcommand.
      def bao(command, args="", token=None):
          token = token or root
          return json.loads(machine.succeed(
              f"BAO_ADDR=${address} BAO_TOKEN={token} bao {command} -format=json {args}"
          ))

      machine.start()

      # The whole chain must converge at boot:
      #   openbao.service -> openbao-init.service -> declarative-openbao.service
      # wait_for_unit blocks until the run-once reconciler has applied every
      # declared resource successfully (a failed apply fails the unit).
      machine.wait_for_unit("declarative-openbao.service")
      root = machine.succeed("cat ${tokenFile}").strip()

      mounts = bao("secrets list")
      assert mounts["kv/"]["type"] == "kv", f"kv mount not applied: {mounts.get('kv/')}"
      assert mounts["kv/"]["options"]["version"] == "2", f"kv mount not version 2: {mounts['kv/']}"
      assert mounts["pki/"]["config"]["max_lease_ttl"] == 315360000, f"pki mount TTL not applied: {mounts['pki/']}"
      assert mounts["transit/"]["type"] == "transit", f"transit mount not applied: {mounts.get('transit/')}"
      auths = bao("auth list")
      assert auths["userpass/"]["type"] == "userpass", f"userpass not applied: {auths.get('userpass/')}"
      assert auths["approle/"]["type"] == "approle", f"approle not applied: {auths.get('approle/')}"

      # A policy in a managed namespace.
      namespaces = bao("namespace list")
      assert "team/" in namespaces, f"namespace not applied: {namespaces}"
      bao("policy read", "-namespace=team team-admin")

      generated = bao("read", "sys/policies/password/alphanumeric/generate")["data"]["password"]
      assert len(generated) == 20 and generated.isalnum(), f"password policy not applied: {generated}"

      # Per-secret indirection: each secret was supplied as a host file and
      # must not appear in the generated config; logging in with it, and
      # reading it back, proves the value still reached OpenBao intact.
      login = bao("write", "auth/userpass/login/alice password=${alicePassword}")["auth"]
      assert "reader" in login["policies"], f"userpass token policies not applied: {login}"
      approle = bao("write", "auth/approle/login role_id=ci-role secret_id=${ciSecretId}")["auth"]
      assert "reader" in approle["policies"], f"approle token policies not applied: {approle}"
      app = bao("kv get", "-mount=kv app")["data"]["data"]
      assert app == json.loads('${builtins.toJSON appSecret}'), f"kv secret not applied: {app}"
      # The userpass token can read the secret through the `reader` policy.
      bao("kv get", "-mount=kv app", token=login["client_token"])
      tfjson = machine.succeed("cat /var/lib/declarative-openbao/declarative-terraform/main.tf.json")
      for name, secret in {
          "user password": "${alicePassword}",
          "AppRole secret ID": "${ciSecretId}",
          "key/value secret": "${appSecret.password}",
          "root token": root,
      }.items():
          assert secret not in tfjson, f"{name} leaked into generated .tf.json"

      deploy = bao("read", "auth/token/roles/deploy")["data"]
      assert deploy["orphan"] and deploy["allowed_policies"] == ["reader"], f"token role not applied: {deploy}"

      key = bao("read", "transit/keys/app")["data"]
      assert key["type"] == "aes256-gcm96", f"transit key not applied: {key}"

      # The role refers to the root issuer: issuing a certificate proves both.
      cert = bao("write", "pki/issue/web common_name=www.example.com")["data"]
      root_issuer = bao("read", "pki/issuer/default")["data"]
      assert root_issuer["issuer_name"] == "root", f"root issuer not named: {root_issuer}"
      # The two PEM values can differ in the whitespace at their ends.
      assert cert["issuing_ca"].strip() == root_issuer["certificate"].strip(), \
          f"certificate not issued by the root issuer: {cert['issuing_ca']!r} != {root_issuer['certificate']!r}"
      urls = bao("read", "pki/config/urls")["data"]
      assert urls["issuing_certificates"] == ["${address}/v1/pki/ca"], f"PKI URLs not applied: {urls}"

      # The alias links userpass logins as alice to the alice entity, which
      # is a member of the readers group.
      entity = bao("read", "identity/entity/name/alice")["data"]
      assert entity["policies"] == ["reader"], f"entity policies not applied: {entity}"
      assert login["entity_id"] == entity["id"], f"entity alias not applied: {login['entity_id']} != {entity['id']}"
      group = bao("read", "identity/group/name/readers")["data"]
      assert group["member_entity_ids"] == [entity["id"]], f"group members not applied: {group}"

      # The state is in the reconciler's own state directory, and only its
      # dynamic user can read it. On the host, the files show as the dynamic
      # user, or as `nobody` when systemd maps the directory into the unit
      # with an ID-mapped mount.
      tfstate = "/var/lib/declarative-openbao/declarative-terraform/terraform.tfstate"
      uid = machine.succeed("systemctl show -P UID declarative-openbao.service").strip()
      owner, mode = machine.succeed(f"stat -c '%u %a' {tfstate}").split()
      assert owner in (uid, "65534"), f"tfstate not owned by the reconciler: uid {owner}, reconciler uid {uid}"
      assert mode == "600", f"tfstate readable by others: mode {mode}"

      # Re-applying must be idempotent: a second run must succeed *and*
      # report 0/0/0 (the last 'Apply complete!' line in the journal).
      machine.succeed("systemctl restart declarative-openbao.service")
      apply_lines = machine.succeed(
          "journalctl -u declarative-openbao.service --no-pager --output=cat "
          "| grep 'Apply complete'"
      ).strip().splitlines()
      assert apply_lines, "no 'Apply complete!' line in journal"
      assert "0 added, 0 changed, 0 destroyed" in apply_lines[-1], \
          f"reapply was not a no-op: {apply_lines[-1]}"
    '';
  };
}
