# incus pairing check, returned as a single-entry attrset merged into the
# flake's per-system `checks`.
#
#   incus - Full integration test: boots a VM with virtualisation.incus, a
#     preseed that makes a network and a storage pool, and
#     virtualisation.incus.runtime. The run-once reconciler applies the config
#     at boot. It adopts the network and pool of the preseed with `adopt`, adds
#     the keys the preseed does not set, and refers to the adopted pool, so a
#     successful apply proves the import blocks and their ordering. A
#     certificate from a host file proves per-secret credential indirection.
#     Requires KVM (a NixOS VM test).
{ pkgs, self }:
let
  fixtures = import ./fixtures.nix;

  # The objects the preseed makes. The reconciler adopts them.
  preseed = {
    networks = [
      {
        name = "incusbr0";
        type = "bridge";
        config = {
          "ipv4.address" = "10.0.100.1/24";
          "ipv4.nat" = "true";
          "ipv6.address" = "none";
        };
      }
    ];
    storage_pools = [
      {
        name = "default";
        driver = "dir";
      }
    ];
  };

  # A client certificate for the metrics endpoint, as a host mints it.
  metricsCert = pkgs.runCommand "incus-metrics-cert" { nativeBuildInputs = [ pkgs.openssl ]; } ''
    mkdir $out
    openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:secp384r1 -nodes \
      -keyout $out/key.pem -out $out/cert.pem -days 3650 -subj /CN=metrics
  '';
in
{
  incus = pkgs.testers.runNixOSTest {
    name = "declarative-incus";

    nodes.machine = {
      imports = [ self.nixosModules.default ];

      # incus requires nftables.
      networking.nftables.enable = true;

      environment.etc."incus-metrics.crt".source = "${metricsCert}/cert.pem";

      virtualisation.incus = {
        enable = true;
        inherit preseed;
        runtime = {
          enable = true;
        }
        // fixtures.main;
      };

      virtualisation.memorySize = 2048;
    };

    testScript = ''
      import json

      def query(path):
          return json.loads(machine.succeed(f"incus query '{path}'"))

      def last_apply():
          lines = machine.succeed(
              "journalctl -u declarative-incus.service --no-pager --output=cat "
              "| grep 'Apply complete'"
          ).strip().splitlines()
          assert lines, "no 'Apply complete!' line in journal"
          return lines[-1]

      machine.start()

      # The whole chain must converge at boot:
      #   incus.service -> incus-preseed.service -> declarative-incus.service
      # wait_for_unit blocks until the run-once reconciler has applied every
      # declared resource successfully (a failed apply fails the unit).
      machine.wait_for_unit("declarative-incus.service")

      # The adopted network keeps the keys of the preseed and gets the keys
      # that only the reconciler sets.
      bridge = query("/1.0/networks/incusbr0")
      assert bridge["managed"], f"incusbr0 not managed by incus: {bridge}"
      for key, value in {
          "ipv4.address": "10.0.100.1/24",
          "ipv4.nat": "true",
          "ipv6.address": "none",
          "dns.domain": "incus.test",
          "raw.dnsmasq": "dhcp-option-force=26,1400",
      }.items():
          assert bridge["config"].get(key) == value, f"incusbr0 {key} not applied: {bridge['config']}"

      internal = query("/1.0/networks/internal")
      assert internal["config"].get("ipv4.address") == "10.0.200.1/24", f"internal network not applied: {internal}"

      # The volume refers to the adopted pool.
      volume = query("/1.0/storage-pools/default/volumes/custom/data")
      assert volume["description"] == "Data volume on the adopted pool", f"volume not applied: {volume}"

      profile = query("/1.0/profiles/default")
      assert profile["devices"] == {
          "eth0": {"type": "nic", "network": "incusbr0", "name": "eth0"},
          "root": {"type": "disk", "path": "/", "pool": "default"},
      }, f"default profile devices not applied: {profile['devices']}"

      project = query("/1.0/projects/tenant")
      assert project["config"].get("limits.instances") == "4", f"project not applied: {project}"
      web = query("/1.0/profiles/web?project=tenant")
      assert web["config"].get("limits.cpu") == "1", f"project profile not applied: {web}"

      address = machine.succeed("incus config get core.https_address").strip()
      assert address == ":8443", f"server config not applied: {address}"
      machine.wait_for_open_port(8443)

      # The certificate came from a host file, and must not be in the
      # generated config.
      trusted = [c for c in query("/1.0/certificates?recursion=1") if c["name"] == "metrics"]
      assert len(trusted) == 1 and trusted[0]["type"] == "metrics", f"metrics certificate not trusted: {trusted}"
      tfjson = machine.succeed("cat /var/lib/declarative-incus/declarative-terraform/main.tf.json")
      assert "BEGIN CERTIFICATE" not in tfjson, "certificate inlined into generated .tf.json"

      # Drift is reverted: a key that the config does not declare is removed.
      machine.succeed("incus network set incusbr0 user.stray=1")
      machine.succeed("systemctl restart declarative-incus.service")
      assert "1 changed" in last_apply(), f"drift not reverted: {last_apply()}"
      stray = query("/1.0/networks/incusbr0")["config"]
      assert "user.stray" not in stray, f"undeclared key kept: {stray}"

      # A restart of incus also runs the preseed and the reconciler again. The
      # preseed sets only keys the reconciler sets to the same values, so the
      # reapply must succeed *and* report 0/0/0.
      machine.succeed("systemctl restart incus.service")
      machine.wait_for_unit("declarative-incus.service")
      assert "0 added, 0 changed, 0 destroyed" in last_apply(), \
          f"reapply after an incus restart was not a no-op: {last_apply()}"
    '';
  };
}
