# Forgejo pairing check, returned as a single-entry attrset merged into the
# flake's per-system `checks`.
#
#   forgejo — Full integration test: boots a VM with services.forgejo +
#     services.forgejo.runtime and lets the pairing converge at boot with no
#     manual setup. The module's own machinery bootstraps the admin API token (a
#     companion oneshot), then the run-once reconciler applies the config. The
#     declared resources span both reference kinds — a repository and team that
#     reference an organization by name, and an Actions variable that references
#     a repository by its numeric id — so a successful apply proves reference
#     resolution and apply ordering. A user with a `passwordFile` also proves
#     per-secret credential indirection — the value is loaded from a host file
#     and kept out of the generated `.tf.json`. Requires KVM (a NixOS VM test).
{ pkgs, self }:
{
  forgejo = pkgs.testers.runNixOSTest {
    name = "declarative-forgejo";

    nodes.machine =
      { pkgs, ... }:
      {
        imports = [ self.nixosModules.default ];

        # curl drives the post-convergence API assertions.
        environment.systemPackages = [ pkgs.curl ];

        # mock agenix secrets: passwords supplied as host files, fed to the
        # reconciler via LoadCredential and never the world-readable store.
        environment.etc."forgejo-bob-password".text = "hackme";
        environment.etc."forgejo-alice-password".text = "hackme";

        services.forgejo = {
          enable = true;
          settings.server = {
            HTTP_PORT = 3000;
            DOMAIN = "localhost";
          };
          # Accept the "hackme" test password (6 chars; default minimum is 8).
          settings.security.MIN_PASSWORD_LENGTH = 6;

          # No tokenFile: the pairing bootstraps its own admin token at boot. The
          # token is minted once with the maximal "all" scope, so it covers every
          # declared resource without ever needing to be re-scoped.
          runtime = {
            enable = true;

            organizations.acme = {
              visibility = "public";
              description = "ACME Corporation";
            };

            # owner references the managed organization by key -> ordered after it.
            # `internal_tracker` is a nested single block (the plugin-framework
            # dialect: a plain JSON object, no `[ ... ]` wrapping).
            repositories.widgets = {
              owner = "acme";
              description = "Widget factory";
              private = false;
              has_issues = true;
              internal_tracker = {
                enable_time_tracker = true;
                allow_only_contributors_to_track_time = false;
                enable_issue_dependencies = true;
              };
            };

            # The other two nested blocks. A repository routes issues either to
            # the built-in tracker or to an external one, never both, so they
            # need a repository of their own.
            repositories.gadgets = {
              owner = "acme";
              description = "Gadget factory";
              private = false;
              has_issues = true;
              has_wiki = true;
              external_tracker = {
                external_tracker_url = "https://tracker.example.com/acme/gadgets";
                external_tracker_format = "https://tracker.example.com/acme/gadgets/{index}";
                external_tracker_style = "numeric";
              };
              external_wiki.external_wiki_url = "https://wiki.example.com/acme/gadgets";
            };

            # organization references the managed org by key (string-name ref).
            teams.engineers = {
              organization = "acme";
              description = "Engineering";
              units_map = {
                "repo.code" = "read";
              };
            };
            organization_action_variables.ci_region = {
              organization = "acme";
              data = "eu-west";
            };

            # repository references the managed repo by key -> emitted as a
            # ${forgejo_repository.widgets.id} numeric reference.
            repository_action_variables.build_flag = {
              repository = "widgets";
              data = "release";
            };

            # Per-secret indirection: bob's password comes from a host file via
            # LoadCredential, so the literal never lands in the generated .tf.json.
            # (Same `<attr>File` mechanism backs action-secret data, repo
            # auth_token, and webhook authorization_header.)
            users.bob = {
              email = "bob@localhost.localdomain";
              passwordFile = "/etc/forgejo-bob-password";
              must_change_password = false;
            };
          };
        };

        virtualisation = {
          memorySize = 3072;
          diskSize = 4096;
        };

        # Exercises that the maximal "all" token needs no re-minting: declaring a
        # user requires write:admin + read:user -- scopes the token already has --
        # so activation mustt just apply the new resource with the same token.
        specialisation.widenScope.configuration = {
          services.forgejo.runtime.users.alice = {
            email = "alice@localhost.localdomain";
            passwordFile = "/etc/forgejo-alice-password";
            must_change_password = false;
          };
        };
      };

    testScript = ''
      import json

      machine.start()

      # The whole chain must converge at boot with zero manual token handling:
      #   forgejo.service -> declarative-forgejo-token.service -> declarative-forgejo.service
      # wait_for_unit blocks until the run-once reconciler has applied every
      # declared resource successfully (a failed apply fails the unit).
      machine.wait_for_unit("declarative-forgejo.service")

      # Concrete checks on the anonymously-readable resources (org + public repo);
      # the team and Actions variables are covered by the apply succeeding above.
      org = machine.succeed("curl --fail http://localhost:3000/api/v1/orgs/acme")
      assert '"ACME Corporation"' in org, f"org description not applied: {org}"

      repo = machine.succeed("curl --fail http://localhost:3000/api/v1/repos/acme/widgets")
      assert '"Widget factory"' in repo, f"repo description not applied: {repo}"

      # Nested single blocks reach Forgejo as plain objects.
      widgets = json.loads(repo)
      assert widgets["internal_tracker"] == {
          "enable_time_tracker": True,
          "allow_only_contributors_to_track_time": False,
          "enable_issue_dependencies": True,
      }, f"internal_tracker not applied: {widgets.get('internal_tracker')}"

      gadgets = json.loads(machine.succeed("curl --fail http://localhost:3000/api/v1/repos/acme/gadgets"))
      assert gadgets["external_tracker"] == {
          "external_tracker_url": "https://tracker.example.com/acme/gadgets",
          "external_tracker_format": "https://tracker.example.com/acme/gadgets/{index}",
          "external_tracker_style": "numeric",
          "external_tracker_regexp_pattern": "",
      }, f"external_tracker not applied: {gadgets.get('external_tracker')}"
      assert gadgets["external_wiki"] == {
          "external_wiki_url": "https://wiki.example.com/acme/gadgets",
      }, f"external_wiki not applied: {gadgets.get('external_wiki')}"

      # Per-secret indirection: bob's password was supplied as a host file and
      # must not appear in the generated config; logging in as bob proves the
      # value still reached Forgejo intact.
      machine.succeed("curl --fail -u bob:hackme http://localhost:3000/api/v1/user")
      tfjson = machine.succeed("cat /var/lib/forgejo/declarative-terraform/main.tf.json")
      assert "hackme" not in tfjson, "secret value leaked into generated .tf.json"

      # State is co-located under the base service's primary state directory and
      # owned by the service user (not an isolated DynamicUser).
      owner = machine.succeed("stat -c %U /var/lib/forgejo/declarative-terraform/terraform.tfstate").strip()
      assert owner == "forgejo", f"tfstate not under forgejo's state dir / not forgejo-owned: {owner}"

      # Re-applying must be idempotent: a second run must succeed *and*
      # report 0/0/0 (the last 'Apply complete!' line in the journal).
      machine.succeed("systemctl restart declarative-forgejo.service")
      apply_lines = machine.succeed(
          "journalctl -u declarative-forgejo.service --no-pager --output=cat "
          "| grep 'Apply complete'"
      ).strip().splitlines()
      assert apply_lines, "no 'Apply complete!' line in journal"
      assert "0 added, 0 changed, 0 destroyed" in apply_lines[-1], \
          f"reapply was not a no-op: {apply_lines[-1]}"

      # Adding an admin-scoped resource (a user needs write:admin + read:user)
      # mus work because the scopen is the maximal "all" token
      machine.succeed("/run/current-system/specialisation/widenScope/bin/switch-to-configuration test")
      machine.wait_until_succeeds("curl --fail http://localhost:3000/api/v1/users/alice")
    '';
  };
}
