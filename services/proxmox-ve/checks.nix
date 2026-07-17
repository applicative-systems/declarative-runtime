# Proxmox VE pairing checks, merged into the flake's per-system `checks`.
#
#   proxmox-ve-references — Offline eval check for the .tf.json generation:
#     reference resolution (VM -> pool, ACL -> role/user, user -> groups),
#     per-secret indirection (top-level user password + the *nested* cloud-init
#     user_account password), MaxItems:1 block wrapping across several nesting
#     depths, network_device rendered as a list attribute, and the two
#     provider-auth modes. This covers the VM/image surface that the live VM
#     test cannot (a real Proxmox node needs its own kernel + a hypervisor).
#
#   proxmox-ve — Full integration test against a Proxmox VE API test double
#     (./emulator.py, HTTPS + self-signed cert, as the real API serves). Boots a
#     VM, lets the pairing converge at boot, and asserts the *runtime state* via
#     the live API: roles, groups, users (incl. group membership), pools and
#     ACLs — exercising both reference kinds, per-secret indirection end-to-end
#     (the password reaches the API but never the generated .tf.json), state
#     ownership, apply idempotency, and re-apply on config change. Requires KVM.
{ pkgs, self }:
let
  inherit (pkgs) lib;
  tflib = import ./lib.nix { inherit pkgs; };

  has = needle: haystack: lib.hasInfix needle haystack;

  # A rich VM plus the access-control surface, rendered offline. The renderer
  # reads attributes with `or null`, so raw attrsets suffice here.
  fullJson =
    builtins.toJSON
      (tflib.proxmoxTfConfig {
        endpoint = "https://localhost:8006/";
        insecure = true;
        apiTokenFile = null;
        username = "root@pam";

        pools.prod.comment = "Production";
        roles.deployer.privileges = [
          "VM.Allocate"
          "VM.Config.Disk"
        ];
        groups.ops.comment = "Operations";
        users."svc@pve" = {
          comment = "Service account";
          enabled = true;
          groups = [ "ops" ];
          passwordFile = "/run/secrets/svc-password";
        };
        acls.svc_root = {
          path = "/";
          role = "deployer";
          user = "svc@pve";
          propagate = true;
        };

        vms.web = {
          node_name = "pve";
          pool = "prod";
          cpu = {
            cores = 2;
            type = "host";
          };
          memory.dedicated = 2048;
          network_device = [
            {
              bridge = "vmbr0";
              model = "virtio";
            }
          ];
          disk = [
            {
              interface = "scsi0";
              datastore_id = "local-lvm";
              size = 20;
              speed.read = 100;
            }
          ];
          agent = {
            enabled = true;
            wait_for_ip.ipv4 = true;
          };
          initialization = {
            dns.domain = "example.com";
            ip_config = [ { ipv4.address = "dhcp"; } ];
            user_account = {
              username = "nixos";
              passwordFile = "/run/secrets/ci-password";
            };
          };
        };
      }).config;

  tokenJson =
    builtins.toJSON
      (tflib.proxmoxTfConfig {
        endpoint = "https://pve.example:8006/";
        apiTokenFile = "/run/secrets/token";
      }).config;

  passwordJson =
    builtins.toJSON
      (tflib.proxmoxTfConfig {
        endpoint = "https://pve.example:8006/";
        apiTokenFile = null;
        username = "deploy@pve";
      }).config;

  sshJson =
    builtins.toJSON
      (tflib.proxmoxTfConfig {
        endpoint = "https://pve.example:8006/";
        apiTokenFile = null;
        ssh = {
          username = "root";
          agent = true;
        };
      }).config;
in
{
  proxmox-ve-references =
    # reference resolution
    assert lib.assertMsg (has "\${proxmox_virtual_environment_pool.pool_prod.pool_id}" fullJson)
      "vm.pool did not resolve to the managed pool id";
    assert lib.assertMsg (has "\${proxmox_virtual_environment_role.role_deployer.role_id}" fullJson)
      "acl.role did not resolve to the managed role id";
    assert lib.assertMsg (has "\${proxmox_virtual_environment_user.user_svc_pve.user_id}" fullJson)
      "acl.user did not resolve to the managed user id";
    assert lib.assertMsg (has "\${proxmox_virtual_environment_group.group_ops.group_id}" fullJson)
      "user.groups did not resolve to the managed group id";
    # name / id injection from the collection key
    assert lib.assertMsg (has "\"name\":\"web\"" fullJson) "vm name not defaulted from key";
    assert lib.assertMsg (has "\"pool_id\":\"prod\"" fullJson) "pool_id not defaulted from key";
    # per-secret indirection: top-level user password + nested cloud-init password
    assert lib.assertMsg (has "\${var.secret_user_svc_pve_password}" fullJson)
      "user passwordFile did not become a sensitive variable";
    assert lib.assertMsg (has "\${var.secret_vm_web_initialization_user_account_password}" fullJson)
      "nested cloud-init passwordFile did not become a sensitive variable";
    assert lib.assertMsg (
      !(has "/run/secrets/svc-password" fullJson)
    ) "user password host path leaked into generated .tf.json";
    assert lib.assertMsg (
      !(has "/run/secrets/ci-password" fullJson)
    ) "cloud-init password host path leaked into generated .tf.json";
    # MaxItems:1 block wrapping across depths + list-typed network_device
    assert lib.assertMsg (has "\"network_device\":[{" fullJson)
      "network_device not rendered as a list attribute";
    assert lib.assertMsg (has "\"cpu\":[{" fullJson) "cpu block not wrapped to a one-element list";
    assert lib.assertMsg (has "\"speed\":[{" fullJson)
      "nested disk.speed block not wrapped to a one-element list";
    assert lib.assertMsg (has "\"initialization\":[{" fullJson) "initialization block not wrapped";
    assert lib.assertMsg (has "\"ip_config\":[{" fullJson) "ip_config not rendered as a list";
    assert lib.assertMsg (has "\"ipv4\":[{" fullJson)
      "nested ip_config.ipv4 block not wrapped to a one-element list";
    assert lib.assertMsg (has "\"wait_for_ip\":[{" fullJson)
      "nested agent.wait_for_ip block not wrapped";
    # provider auth modes
    assert lib.assertMsg (has "\"api_token\":\"\${var.proxmox_token}\"" tokenJson)
      "apiTokenFile mode did not emit an api_token provider attribute";
    assert lib.assertMsg (
      !(has "\"password\"" tokenJson)
    ) "apiTokenFile mode must not emit username/password";
    assert lib.assertMsg (
      has "\"username\":\"deploy@pve\"" passwordJson
      && has "\"password\":\"\${var.proxmox_token}\"" passwordJson
    ) "username/password mode did not emit username + password provider attributes";
    assert lib.assertMsg (
      has "\"ssh\":[{" sshJson && has "\"agent\":true" sshJson
    ) "ssh block not rendered as a one-element list";
    pkgs.runCommand "proxmox-ve-references-check" { } "touch $out";

  proxmox-ve = pkgs.testers.runNixOSTest {
    name = "declarative-proxmox-ve";

    nodes.machine =
      { pkgs, ... }:
      {
        imports = [ self.nixosModules.default ];

        environment.systemPackages = [ pkgs.curl ];

        # Mock agenix secrets as host files, fed to the reconciler via
        # LoadCredential and kept out of the world-readable store.
        environment.etc."proxmox-root-password".text = "hackme";
        environment.etc."proxmox-svc-password".text = "hackme";

        # Proxmox VE API test double, serving self-signed HTTPS on :8006 like
        # the real pveproxy. The cert is generated at start into the runtime dir.
        systemd.services.proxmox-ve-emulator = {
          description = "Proxmox VE API test double";
          wantedBy = [ "multi-user.target" ];
          environment = {
            PORT = "8006";
            EXPECTED_PASSWORD = "hackme";
            CERT_FILE = "/run/proxmox-ve-emulator/cert.pem";
            KEY_FILE = "/run/proxmox-ve-emulator/key.pem";
          };
          serviceConfig = {
            RuntimeDirectory = "proxmox-ve-emulator";
            ExecStartPre = pkgs.writeShellScript "proxmox-emulator-cert" ''
              ${pkgs.openssl}/bin/openssl req -x509 -newkey rsa:2048 -nodes \
                -keyout /run/proxmox-ve-emulator/key.pem \
                -out /run/proxmox-ve-emulator/cert.pem \
                -subj "/CN=localhost" -days 3650
            '';
            ExecStart = "${pkgs.python3}/bin/python3 ${./emulator.py}";
            ExecStartPost = "${pkgs.curl}/bin/curl --retry 30 --retry-delay 1 --retry-all-errors -fsS -k -o /dev/null https://127.0.0.1:8006/api2/json/healthz";
            DynamicUser = true;
            Restart = "on-failure";
          };
        };

        # Order the reconciler after the test double instead of pveproxy, and
        # give the run-once apply room.
        systemd.services.declarative-proxmox-ve = {
          after = [ "proxmox-ve-emulator.service" ];
          wants = [ "proxmox-ve-emulator.service" ];
          serviceConfig.TimeoutStartSec = "600";
        };

        services.proxmox-ve.runtime = {
          enable = true;
          endpoint = "https://127.0.0.1:8006/";
          insecure = true;
          username = "root@pam";
          passwordFile = "/etc/proxmox-root-password";

          roles.deployer.privileges = [
            "VM.Allocate"
            "VM.Config.Disk"
            "Datastore.AllocateSpace"
          ];

          groups.ops.comment = "Operations";

          # user -> groups reference + per-secret password indirection.
          users."svc@pve" = {
            comment = "Service account";
            enabled = true;
            groups = [ "ops" ];
            passwordFile = "/etc/proxmox-svc-password";
          };

          pools.prod.comment = "Production";

          # acl -> role + user references.
          acls.svc_admin = {
            path = "/";
            role = "deployer";
            user = "svc@pve";
            propagate = true;
          };
        };

        virtualisation.memorySize = 2048;

        # config change: adds an acl -> group reference on a specific path.
        specialisation.addAcl.configuration = {
          services.proxmox-ve.runtime.acls.ops_pool = {
            path = "/pool/prod";
            role = "deployer";
            group = "ops";
            propagate = true;
          };
        };
      };

    testScript = ''
      import json

      TFJSON = "/var/lib/declarative-proxmox-ve/declarative-terraform/main.tf.json"

      machine.start()
      machine.wait_for_unit("proxmox-ve-emulator.service")

      # wait_for_unit blocks until the run-once reconciler has applied every
      # declared resource (a failed apply, incl. failed auth, fails the unit).
      machine.wait_for_unit("declarative-proxmox-ve.service")

      # Authenticate the same way the provider did (username/password ticket),
      # then read the runtime state back through the live API.
      ticket = json.loads(machine.succeed(
          "curl -sk --fail -d 'username=root@pam&password=hackme' "
          "https://127.0.0.1:8006/api2/json/access/ticket"
      ))["data"]["ticket"]

      def api(path):
          return json.loads(machine.succeed(
              f"curl -sk --fail -b 'PVEAuthCookie={ticket}' 'https://127.0.0.1:8006/api2/json{path}'"
          ))["data"]

      # role: privileges applied.
      role = api("/access/roles/deployer")
      assert "VM.Allocate" in role and "Datastore.AllocateSpace" in role, f"role privileges not applied: {role}"

      # group + membership: the user -> groups reference put svc@pve in ops.
      group = api("/access/groups/ops")
      assert group.get("comment") == "Operations", f"group comment not applied: {group}"
      assert "svc@pve" in group.get("members", []), f"group membership (user->groups ref) not applied: {group}"

      # user: created with the declared fields.
      user = api("/access/users/svc@pve")
      assert user.get("enable") == 1, f"user not enabled: {user}"
      assert "ops" in user.get("groups", []), f"user groups not applied: {user}"

      # pool: read back via the ?poolid= single-element list form.
      pool = api("/pools?poolid=prod")
      assert pool and pool[0].get("comment") == "Production", f"pool not applied: {pool}"

      # acl: role + user references resolved to a real binding.
      acl = api("/access/acl")
      assert any(
          e["path"] == "/" and e["roleid"] == "deployer"
          and e["type"] == "user" and e["ugid"] == "svc@pve"
          for e in acl
      ), f"acl (role+user refs) not applied: {acl}"

      # per-secret indirection reached the API end-to-end...
      seen_pw = api("/debug/user-password?userid=svc@pve")
      assert seen_pw == "hackme", f"user passwordFile did not reach the API: {seen_pw!r}"
      # ...but the literal never entered the generated config.
      tfjson = machine.succeed(f"cat {TFJSON}")
      assert "hackme" not in tfjson, "secret value leaked into generated .tf.json"

      # state is co-located under the reconciler's state dir and owned by it.
      owner = machine.succeed(
          "stat -c %U /var/lib/declarative-proxmox-ve/declarative-terraform/terraform.tfstate"
      ).strip()
      assert owner == "declarative-proxmox-ve", f"tfstate not owned by the reconciler user: {owner}"

      # re-applying must be idempotent: a second run reports 0/0/0.
      machine.succeed("systemctl restart declarative-proxmox-ve.service")
      apply_lines = machine.succeed(
          "journalctl -u declarative-proxmox-ve.service --no-pager --output=cat "
          "| grep 'Apply complete'"
      ).strip().splitlines()
      assert apply_lines, "no 'Apply complete!' line in journal"
      assert "0 added, 0 changed, 0 destroyed" in apply_lines[-1], \
          f"reapply was not a no-op: {apply_lines[-1]}"

      # config change (restartTriggers): the specialisation adds an acl->group
      # binding, which the reconciler applies on switch.
      machine.succeed("/run/current-system/specialisation/addAcl/bin/switch-to-configuration test")
      machine.wait_for_unit("declarative-proxmox-ve.service")
      acl2 = api("/access/acl")
      assert any(
          e["path"] == "/pool/prod" and e["roleid"] == "deployer"
          and e["type"] == "group" and e["ugid"] == "ops"
          for e in acl2
      ), f"acl->group binding not applied after config change: {acl2}"
    '';
  };
}
