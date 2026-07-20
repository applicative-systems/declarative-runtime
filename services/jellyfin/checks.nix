# Jellyfin pairing checks, merged into the flake's per-system `checks`.
#
#   jellyfin — Full integration test: boots a VM with services.jellyfin +
#     services.jellyfin.runtime and lets the pairing converge at boot with no
#     manual setup. No apiKeyFile / adminPasswordFile is given, so a companion
#     oneshot mints a random admin password and the provider uses it to create
#     the admin account, complete the startup wizard, and apply the declared
#     resources (a user, a library and the system-configuration singleton).
#     `wait_for_unit` therefore proves the whole cold-boot chain, and the
#     assertions confirm the runtime state via the live Jellyfin API. A user
#     with a `passwordFile` proves per-secret credential indirection. Requires
#     KVM (a NixOS VM test).
#
#   jellyfin-references — Offline eval check for the reference-resolution engine
#     and the two provider-auth modes. Installing a jellyfin_plugin downloads
#     the package from its repository, which the sandboxed VM test cannot do, so
#     both cross-resource references (plugin -> plugin_repository by url,
#     plugin_configuration -> plugin by computed id) are exercised here at .tf.json
#     generation instead: a bad reference throws, and a good one must resolve to
#     the expected `${…}` interpolation.
#
#   jellyfin-import — Import-adoption test: boots an importable-only runtime (a
#     library and a plugin repository, both imported by name), lets the
#     reconciler create them, then deletes the tfstate and re-runs the
#     reconciler. The best-effort import pass must adopt the live resources
#     (0 added / 0 destroyed) rather than recreate them. Requires KVM.
{ pkgs, self }:
let
  inherit (pkgs) lib;
  tflib = import ./lib.nix { inherit pkgs; };

  # Raw cfg attrsets (the renderer reads attributes with `or null`, so it does
  # not need a module-evaluated submodule here).
  refJson =
    builtins.toJSON
      (tflib.jellyfinTfConfig {
        baseUrl = "http://localhost:8096";
        apiKeyFile = null;
        adminUsername = "admin";
        plugin_repositories.stable = {
          name = "Stable";
          url = "https://repo.jellyfin.org/files/plugin/manifest.json";
          enabled = true;
        };
        plugins.bookshelf = {
          version = "14.0.0.0";
          repository = "stable"; # name reference -> jellyfin_plugin_repository.<label>.url
        };
        plugin_configurations.tune = {
          plugin = "bookshelf"; # id reference -> jellyfin_plugin.<label>.id
          configuration_json = "{}";
        };
      }).config;

  apiKeyJson =
    builtins.toJSON
      (tflib.jellyfinTfConfig {
        baseUrl = "http://localhost:8096";
        apiKeyFile = "/run/secrets/jellyfin-api-key";
        adminUsername = "admin";
      }).config;

  passwordJson =
    builtins.toJSON
      (tflib.jellyfinTfConfig {
        baseUrl = "http://localhost:8096";
        apiKeyFile = null;
        adminUsername = "svc";
      }).config;

  has = needle: haystack: lib.hasInfix needle haystack;
in
{
  jellyfin-references =
    assert lib.assertMsg (has "\${jellyfin_plugin_repository.plugin_repo_stable.url}" refJson)
      "plugin.repository name reference did not resolve to the managed repository url";
    assert lib.assertMsg (has "\${jellyfin_plugin.plugin_bookshelf.id}" refJson)
      "plugin_configuration.plugin id reference did not resolve to the managed plugin id";
    assert lib.assertMsg (has "\"api_key\":\"\${var.jellyfin_token}\"" apiKeyJson)
      "apiKeyFile mode did not emit an api_key provider attribute";
    assert lib.assertMsg (
      !(has "\"password\"" apiKeyJson)
    ) "apiKeyFile mode must not emit a password provider attribute";
    assert lib.assertMsg (
      has "\"username\":\"svc\"" passwordJson
      && has "\"password\":\"\${var.jellyfin_token}\"" passwordJson
    ) "username/password mode did not emit username + password provider attributes";
    pkgs.runCommand "jellyfin-references-check" { } "touch $out";

  jellyfin = pkgs.testers.runNixOSTest {
    name = "declarative-jellyfin";

    nodes.machine =
      { pkgs, ... }:
      {
        imports = [ self.nixosModules.default ];

        # curl drives the post-convergence API assertions.
        environment.systemPackages = [ pkgs.curl ];

        # mock agenix secret: the viewer's password as a host file, fed to the
        # reconciler via LoadCredential and kept out of the world-readable store.
        environment.etc."jellyfin-viewer-password".text = "hackme";

        # library paths must exist and be readable by the jellyfin user.
        systemd.tmpfiles.rules = [ "d /srv/media/movies 0755 jellyfin jellyfin -" ];

        services.jellyfin = {
          enable = true;

          # No apiKeyFile / adminPasswordFile: the pairing mints a random admin
          # password at boot and the provider uses it to complete the startup
          # wizard, so the whole thing converges with zero manual setup.
          runtime = {
            enable = true;

            system_configuration.main = {
              server_name = "Declarative Jellyfin";
            };

            libraries.movies = {
              name = "Movies";
              collection_type = "movies";
              paths = [ "/srv/media/movies" ];
            };

            # Per-secret indirection: the password comes from a host file via
            # LoadCredential, so the literal never lands in the generated json.
            users.viewer = {
              passwordFile = "/etc/jellyfin-viewer-password";
              is_administrator = false;
            };
          };
        };

        virtualisation = {
          memorySize = 3072;
          diskSize = 4096;
        };
      };

    testScript = ''
      import json

      machine.start()

      # The whole chain must converge at boot with zero manual credential
      # handling:
      #   declarative-jellyfin-password.service (mint password)
      #   -> jellyfin.service -> declarative-jellyfin.service
      # wait_for_unit blocks until the run-once reconciler has completed the
      # startup wizard and applied every declared resource (a failed apply,
      # including a failed bootstrap/auth, fails the unit).
      machine.wait_for_unit("declarative-jellyfin.service")

      # Authenticate via Jellyfin's AuthenticateByName. The request body is
      # written to a file (json.dumps twice: once for the body, once to shell-
      # quote it) so no fragile inline shell quoting is needed.
      auth_hdr = 'Authorization: MediaBrowser Client="test", Device="test", DeviceId="test", Version="1.0.0"'

      def authenticate(username, password):
          body = json.dumps({"Username": username, "Pw": password})
          machine.succeed(f"printf '%s' {json.dumps(body)} > /tmp/auth.json")
          resp = json.loads(machine.succeed(
              "curl --fail -X POST http://localhost:8096/Users/AuthenticateByName "
              "-H 'Content-Type: application/json' "
              f"-H '{auth_hdr}' "
              "--data @/tmp/auth.json"
          ))
          return resp["AccessToken"]

      # system_configuration singleton: server_name is exposed on the anonymous
      # public info endpoint.
      info = json.loads(machine.succeed("curl --fail http://localhost:8096/System/Info/Public"))
      assert info.get("ServerName") == "Declarative Jellyfin", f"server_name not applied: {info.get('ServerName')}"

      # The auto-minted admin password authenticates against the live API,
      # proving the zero-setup bootstrap (wizard completion + admin creation)
      # worked. Its token drives the authenticated assertions below.
      admin_pw = machine.succeed("cat /var/lib/declarative-jellyfin-password/admin-password").strip()
      token = authenticate("admin", admin_pw)

      # User creation: the managed viewer is present in the full user list.
      users = json.loads(machine.succeed(f"curl --fail 'http://localhost:8096/Users?api_key={token}'"))
      names = [u["Name"] for u in users]
      assert "viewer" in names, f"viewer user not created: {names}"

      # Per-secret indirection: logging in as viewer with the host-file password
      # proves the secret reached Jellyfin; the literal must be absent from the
      # generated config.
      authenticate("viewer", "hackme")
      tfjson = machine.succeed("cat /var/lib/jellyfin/declarative-terraform/main.tf.json")
      assert "hackme" not in tfjson, "secret value leaked into generated .tf.json"

      # The declared library is present (an authenticated read).
      folders = json.loads(machine.succeed(
          f"curl --fail 'http://localhost:8096/Library/VirtualFolders?api_key={token}'"
      ))
      lib_names = [f["Name"] for f in folders]
      assert "Movies" in lib_names, f"library not applied: {lib_names}"

      # State is co-located under the base service's data directory and owned by
      # the jellyfin user (not an isolated DynamicUser).
      owner = machine.succeed("stat -c %U /var/lib/jellyfin/declarative-terraform/terraform.tfstate").strip()
      assert owner == "jellyfin", f"tfstate not under jellyfin's data dir / not jellyfin-owned: {owner}"

      # Re-applying must be idempotent: a second run must succeed *and* report
      # 0/0/0 (the last 'Apply complete!' line in the journal).
      machine.succeed("systemctl restart declarative-jellyfin.service")
      apply_lines = machine.succeed(
          "journalctl -u declarative-jellyfin.service --no-pager --output=cat "
          "| grep 'Apply complete'"
      ).strip().splitlines()
      assert apply_lines, "no 'Apply complete!' line in journal"
      assert "0 added, 0 changed, 0 destroyed" in apply_lines[-1], \
          f"reapply was not a no-op: {apply_lines[-1]}"
    '';
  };

  jellyfin-import = pkgs.testers.runNixOSTest {
    name = "declarative-jellyfin-import";

    nodes.machine =
      { pkgs, ... }:
      {
        imports = [ self.nixosModules.default ];
        environment.systemPackages = [ pkgs.curl ];
        systemd.tmpfiles.rules = [
          "d /srv/media/movies 0755 jellyfin jellyfin -"
          "d /srv/media/shows 0755 jellyfin jellyfin -"
        ];

        services.jellyfin = {
          enable = true;
          # Importable-only runtime: jellyfin_library imports by name (users,
          # api keys and plugin configs key on server-assigned GUIDs and are
          # omitted). Two libraries prove multi-resource adoption.
          runtime = {
            enable = true;
            libraries.movies = {
              name = "Movies";
              collection_type = "movies";
              paths = [ "/srv/media/movies" ];
            };
            libraries.shows = {
              name = "Shows";
              collection_type = "tvshows";
              paths = [ "/srv/media/shows" ];
            };
          };
        };

        virtualisation = {
          memorySize = 3072;
          diskSize = 4096;
        };
      };

    testScript = ''
      import json

      machine.start()
      machine.wait_for_unit("declarative-jellyfin.service")

      auth_hdr = 'Authorization: MediaBrowser Client="test", Device="test", DeviceId="test", Version="1.0.0"'
      admin_pw = machine.succeed("cat /var/lib/declarative-jellyfin-password/admin-password").strip()
      body = json.dumps({"Username": "admin", "Pw": admin_pw})
      machine.succeed(f"printf '%s' {json.dumps(body)} > /tmp/auth.json")
      token = json.loads(machine.succeed(
          "curl --fail -X POST http://localhost:8096/Users/AuthenticateByName "
          "-H 'Content-Type: application/json' "
          f"-H '{auth_hdr}' --data @/tmp/auth.json"
      ))["AccessToken"]

      def library_names():
          folders = json.loads(machine.succeed(
              f"curl --fail 'http://localhost:8096/Library/VirtualFolders?api_key={token}'"
          ))
          return [f["Name"] for f in folders]

      # Baseline: the declared library exists.
      assert {"Movies", "Shows"}.issubset(set(library_names())), "libraries not created at boot"

      # Simulate a lost / rebuilt tfstate, then re-run the reconciler.
      state = "/var/lib/jellyfin/declarative-terraform"
      machine.succeed("systemctl stop declarative-jellyfin.service")
      machine.succeed(f"rm -f {state}/terraform.tfstate {state}/terraform.tfstate.backup")
      machine.succeed(f"test ! -e {state}/terraform.tfstate")
      machine.succeed("systemctl start declarative-jellyfin.service")
      machine.wait_for_unit("declarative-jellyfin.service")

      # The reconciler must ADOPT the pre-existing resources, not recreate them.
      journal = machine.succeed(
          "journalctl -u declarative-jellyfin.service --no-pager --output=cat"
      )
      for addr in [
          "jellyfin_library.library_movies",
          "jellyfin_library.library_shows",
      ]:
          assert f"declarative-import: adopted {addr}" in journal, \
              f"{addr} was not adopted via import:\n{journal}"

      apply_lines = [line for line in journal.splitlines() if "Apply complete" in line]
      assert apply_lines, "no 'Apply complete!' line after state-loss re-apply"
      adopted = apply_lines[-1]
      assert "0 added" in adopted and "0 destroyed" in adopted, \
          f"state-loss re-apply recreated resources instead of adopting: {adopted}"

      # The library is intact (adopted, not duplicated or dropped).
      final = library_names()
      assert final.count("Movies") == 1 and final.count("Shows") == 1, \
          "libraries missing or duplicated after adoption"
    '';
  };
}
