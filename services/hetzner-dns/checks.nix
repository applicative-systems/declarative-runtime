# hetzner-dns — Full integration test.
# Hetzner DNS is a remote cloud API with. We emulate it with ./emulator.py.
#
#   hetzner-dns-import — Import-adoption test: two importable-only zones,
#   created against the emulator, then re-adopted after the tfstate is deleted
#   (0 added / 0 destroyed) rather than recreated. hcloud_zone imports by name.
#   RRSets/records reference their parent zone by a server-assigned numeric id
#   (not derivable from a lost state), so they are excluded here; composite
#   import ids are covered by the forgejo branch-protection test.
{ pkgs, self }:
let
  port = 8899;
  apiToken = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef";
  tsigSecret = "hackme";
  endpoint = "http://127.0.0.1:${toString port}/v1";
  tfJson = "/var/lib/declarative-hetzner-dns/declarative-terraform/main.tf.json";
in
{
  hetzner-dns = pkgs.testers.runNixOSTest {
    name = "declarative-hetzner-dns";

    nodes.machine =
      { pkgs, ... }:
      {
        imports = [ self.nixosModules.default ];
        environment.systemPackages = [ pkgs.curl ];
        environment.etc."hcloud-dns-token".text = apiToken;
        environment.etc."hcloud-tsig-key".text = tsigSecret;
        systemd.services.hetzner-dns-emulator = {
          description = "Hetzner DNS API test double";
          wantedBy = [ "multi-user.target" ];
          environment = {
            PORT = toString port;
            EXPECTED_TOKEN = apiToken;
          };
          serviceConfig = {
            ExecStart = "${pkgs.python3}/bin/python3 ${./emulator.py}";
            # TODO
            ExecStartPost = "${pkgs.curl}/bin/curl --retry 30 --retry-delay 1 --retry-all-errors -fsS -o /dev/null http://127.0.0.1:${toString port}/v1/healthz";
            DynamicUser = true;
            Restart = "on-failure";
          };
        };

        systemd.services.declarative-hetzner-dns = {
          after = [ "hetzner-dns-emulator.service" ];
          wants = [ "hetzner-dns-emulator.service" ];
        };

        services.hetzner-dns.runtime = {
          enable = true;
          tokenFile = "/etc/hcloud-dns-token";
          inherit endpoint;

          # canonical
          zones.acme = {
            name = "acme.example";
            ttl = 3600;
            labels.team = "platform";
            delete_protection = false;
          };

          # nested secret
          zones.mirror = {
            name = "mirror.example";
            mode = "secondary";
            primary_nameservers = [
              {
                address = "203.0.113.53";
                tsig_algorithm = "hmac-sha256";
                tsig_keyFile = "/etc/hcloud-tsig-key";
              }
            ];
          };

          # multi-records
          zone_rrsets.www = {
            zone = "acme";
            name = "www";
            type = "A";
            ttl = 300;
            records = [
              { value = "203.0.113.10"; }
              { value = "203.0.113.11"; }
            ];
          };
          zone_rrsets.apex_txt = {
            zone = "acme";
            name = "@";
            type = "TXT";
            records = [ { value = "\"v=spf1 -all\""; } ];
          };

          # mx record
          zone_records.mx = {
            zone = "acme";
            name = "@";
            type = "MX";
            value = "10 mail.acme.example";
            comment = "primary mx";
          };
        };

        virtualisation.memorySize = 2048;

        specialisation.addRecord.configuration = {
          services.hetzner-dns.runtime.zone_rrsets.api = {
            zone = "acme";
            name = "api";
            type = "A";
            records = [ { value = "203.0.113.20"; } ];
          };
        };
      };

    testScript = ''
      PORT = ${toString port}
      TOKEN = "${apiToken}"
      TSIG = "${tsigSecret}"
      TFJSON = "${tfJson}"

      def api(path):
          return machine.succeed(
              f"curl --fail -H 'Authorization: Bearer {TOKEN}' "
              f"http://127.0.0.1:{PORT}/v1{path}"
          )

      machine.start()
      machine.wait_for_unit("hetzner-dns-emulator.service")

      machine.wait_for_unit("declarative-hetzner-dns.service")

      # assert config
      zone = api("/zones/acme.example")
      assert '"team": "platform"' in zone, f"zone label not applied: {zone}"
      assert '"ttl": 3600' in zone, f"zone ttl not applied: {zone}"

      www = api("/zones/acme.example/rrsets/www/A")
      assert '"203.0.113.10"' in www and '"203.0.113.11"' in www, f"www A not applied: {www}"

      txt = api("/zones/acme.example/rrsets/@/TXT")
      assert "v=spf1 -all" in txt, f"apex TXT not applied: {txt}"

      mx = api("/zones/acme.example/rrsets/@/MX")
      assert "10 mail.acme.example" in mx, f"MX record not applied: {mx}"

      mirror = api("/zones/mirror.example")
      assert '"mode": "secondary"' in mirror, f"secondary zone not applied: {mirror}"
      assert f'"tsig_key": "{TSIG}"' in mirror, f"tsig key did not reach API: {mirror}"

      # check secrets
      tfjson = machine.succeed(f"cat {TFJSON}")
      assert TOKEN not in tfjson, "API token leaked into generated .tf.json"
      assert TSIG not in tfjson, "TSIG secret leaked into generated .tf.json"

      # check state owner
      owner = machine.succeed(
          "stat -c %U /var/lib/declarative-hetzner-dns/declarative-terraform/terraform.tfstate"
      ).strip()
      assert owner == "declarative-hetzner-dns", f"tfstate not owned by service user: {owner}"

      # idempotent
      machine.succeed("systemctl restart declarative-hetzner-dns.service")
      apply_lines = machine.succeed(
          "journalctl -u declarative-hetzner-dns.service --no-pager --output=cat "
          "| grep 'Apply complete'"
      ).strip().splitlines()
      assert apply_lines, "no 'Apply complete!' line in journal"
      assert "0 added, 0 changed, 0 destroyed" in apply_lines[-1], \
          f"reapply was not a no-op: {apply_lines[-1]}"

      # restart triggers
      machine.succeed("/run/current-system/specialisation/addRecord/bin/switch-to-configuration test")
      api_ = machine.wait_until_succeeds(
          f"curl --fail -H 'Authorization: Bearer {TOKEN}' "
          f"http://127.0.0.1:{PORT}/v1/zones/acme.example/rrsets/api/A"
      )
      assert '203.0.113.20' in api_, f"api A not applied: {api_}"
    '';
  };

  hetzner-dns-import = pkgs.testers.runNixOSTest {
    name = "declarative-hetzner-dns-import";

    nodes.machine =
      { pkgs, ... }:
      {
        imports = [ self.nixosModules.default ];
        environment.systemPackages = [ pkgs.curl ];
        environment.etc."hcloud-dns-token".text = apiToken;

        systemd.services.hetzner-dns-emulator = {
          description = "Hetzner DNS API test double";
          wantedBy = [ "multi-user.target" ];
          environment = {
            PORT = toString port;
            EXPECTED_TOKEN = apiToken;
          };
          serviceConfig = {
            ExecStart = "${pkgs.python3}/bin/python3 ${./emulator.py}";
            ExecStartPost = "${pkgs.curl}/bin/curl --retry 30 --retry-delay 1 --retry-all-errors -fsS -o /dev/null http://127.0.0.1:${toString port}/v1/healthz";
            DynamicUser = true;
            Restart = "on-failure";
          };
        };

        systemd.services.declarative-hetzner-dns = {
          after = [ "hetzner-dns-emulator.service" ];
          wants = [ "hetzner-dns-emulator.service" ];
        };

        services.hetzner-dns.runtime = {
          enable = true;
          tokenFile = "/etc/hcloud-dns-token";
          inherit endpoint;

          # Importable-only: hcloud_zone imports by name. Two zones prove
          # multi-resource adoption. (zone_rrsets/zone_records link to their
          # parent zone by its server-assigned numeric id, which a lost state
          # cannot re-derive, so on re-apply the provider force-replaces them
          # rather than adopting; only zones adopt cleanly here. Composite
          # import ids are covered by the forgejo branch-protection test.)
          zones.acme = {
            name = "acme.example";
            ttl = 3600;
            labels.team = "platform";
          };
          zones.beta = {
            name = "beta.example";
            ttl = 7200;
          };
        };

        virtualisation.memorySize = 2048;
      };

    testScript = ''
      PORT = ${toString port}
      TOKEN = "${apiToken}"

      def api(path):
          return machine.succeed(
              f"curl --fail -H 'Authorization: Bearer {TOKEN}' "
              f"http://127.0.0.1:{PORT}/v1{path}"
          )

      machine.start()
      machine.wait_for_unit("hetzner-dns-emulator.service")
      machine.wait_for_unit("declarative-hetzner-dns.service")

      # Baseline: both zones exist.
      api("/zones/acme.example")
      api("/zones/beta.example")

      # Simulate a lost / rebuilt tfstate, then re-run the reconciler.
      state = "/var/lib/declarative-hetzner-dns/declarative-terraform"
      machine.succeed("systemctl stop declarative-hetzner-dns.service")
      machine.succeed(f"rm -f {state}/terraform.tfstate {state}/terraform.tfstate.backup")
      machine.succeed(f"test ! -e {state}/terraform.tfstate")
      machine.succeed("systemctl start declarative-hetzner-dns.service")
      machine.wait_for_unit("declarative-hetzner-dns.service")

      # The reconciler must ADOPT the pre-existing zone + rrsets, not recreate.
      journal = machine.succeed(
          "journalctl -u declarative-hetzner-dns.service --no-pager --output=cat"
      )
      for addr in [
          "hcloud_zone.zone_acme",
          "hcloud_zone.zone_beta",
      ]:
          assert f"declarative-import: adopted {addr}" in journal, \
              f"{addr} was not adopted via import:\n{journal}"

      apply_lines = [line for line in journal.splitlines() if "Apply complete" in line]
      assert apply_lines, "no 'Apply complete!' line after state-loss re-apply"
      adopted = apply_lines[-1]
      assert "0 added" in adopted and "0 destroyed" in adopted, \
          f"state-loss re-apply recreated resources instead of adopting: {adopted}"

      # Zones intact after adoption.
      zone = api("/zones/acme.example")
      assert '"team": "platform"' in zone, f"zone label changed after adoption: {zone}"
    '';
  };
}
