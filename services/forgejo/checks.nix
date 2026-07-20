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
#
#   forgejo-import — Import-adoption test: boots an importable-only runtime
#     (user + repository + branch protection, all with derivable import ids),
#     lets the reconciler create them, then deletes the tfstate and re-runs the
#     reconciler. The best-effort import pass must *adopt* the live resources
#     into the fresh state (0 added / 0 destroyed) rather than recreate them,
#     and the pairing must then reconverge to a no-op. Requires KVM.
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
            repositories.widgets = {
              owner = "acme";
              description = "Widget factory";
              private = false;
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

  forgejo-import = pkgs.testers.runNixOSTest {
    name = "declarative-forgejo-import";

    nodes.machine =
      { pkgs, ... }:
      {
        imports = [ self.nixosModules.default ];
        environment.systemPackages = [ pkgs.curl ];
        environment.etc."forgejo-bob-password".text = "hackme";

        services.forgejo = {
          enable = true;
          settings.server = {
            HTTP_PORT = 3000;
            DOMAIN = "localhost";
          };
          settings.security.MIN_PASSWORD_LENGTH = 6;

          # Importable-only runtime: every declared resource has a derivable
          # import id -- forgejo_user by login, forgejo_repository by
          # "<owner>/<name>", forgejo_branch_protection by
          # "<owner>/<repo>/<branch>" (composed from the repo's own import id).
          # Organizations/teams/secrets are omitted: the provider gives them no
          # id-string importer, so a lost state could not re-adopt them.
          runtime = {
            enable = true;

            users.bob = {
              email = "bob@localhost.localdomain";
              passwordFile = "/etc/forgejo-bob-password";
              must_change_password = false;
            };

            # owner is the managed user -> import id "bob/widgets".
            repositories.widgets = {
              owner = "bob";
              description = "Widget factory";
              private = false;
              auto_init = true;
            };

            # composed from the repo's import id -> "bob/widgets/main".
            branch_protections.main = {
              repository = "widgets";
              branch_name = "main";
              enable_push = true;
            };
          };
        };

        virtualisation = {
          memorySize = 3072;
          diskSize = 4096;
        };
      };

    testScript = ''
      machine.start()

      # Cold boot converges the importable-only config: the reconciler *creates*
      # bob, bob/widgets and its branch protection (the first-boot import pass
      # finds nothing to adopt yet).
      machine.wait_for_unit("declarative-forgejo.service")

      token = machine.succeed("cat /var/lib/declarative-forgejo-token/api-token").strip()

      def auth(path):
          return machine.succeed(
              f"curl --fail -H 'Authorization: token {token}' http://localhost:3000{path}"
          )

      # Baseline: the three declared resources exist.
      auth("/api/v1/users/bob")
      auth("/api/v1/repos/bob/widgets")
      auth("/api/v1/repos/bob/widgets/branch_protections/main")

      # Simulate a lost / rebuilt tfstate, then re-run the reconciler.
      state = "/var/lib/forgejo/declarative-terraform"
      machine.succeed("systemctl stop declarative-forgejo.service")
      machine.succeed(f"rm -f {state}/terraform.tfstate {state}/terraform.tfstate.backup")
      machine.succeed(f"test ! -e {state}/terraform.tfstate")
      machine.succeed("systemctl start declarative-forgejo.service")
      machine.wait_for_unit("declarative-forgejo.service")

      # The reconciler must ADOPT the pre-existing resources into the fresh
      # state via `tofu import`, not recreate them.
      journal = machine.succeed(
          "journalctl -u declarative-forgejo.service --no-pager --output=cat"
      )
      for addr in [
          "forgejo_user.user_bob",
          "forgejo_repository.repo_widgets",
          "forgejo_branch_protection.branch_protection_main",
      ]:
          assert f"declarative-import: adopted {addr}" in journal, \
              f"{addr} was not adopted via import:\n{journal}"

      # The adoption apply must add and destroy nothing (nothing recreated).
      apply_lines = [line for line in journal.splitlines() if "Apply complete" in line]
      assert apply_lines, "no 'Apply complete!' line after state-loss re-apply"
      adopted = apply_lines[-1]
      assert "0 added" in adopted and "0 destroyed" in adopted, \
          f"state-loss re-apply recreated resources instead of adopting: {adopted}"

      # Resources are intact (adopted, not duplicated or dropped).
      auth("/api/v1/users/bob")
      auth("/api/v1/repos/bob/widgets")
      auth("/api/v1/repos/bob/widgets/branch_protections/main")

      # A further reconcile adopts nothing new and recreates nothing: the
      # imported resources stay imported. (A residual in-place update is
      # expected -- forgejo_user's password is write-only, so the provider can
      # never read it back and reconciles it on every apply; that is not a
      # recreation, so we assert on added/destroyed, not changed.)
      machine.succeed("systemctl restart declarative-forgejo.service")
      stable = machine.succeed(
          "journalctl -u declarative-forgejo.service --no-pager --output=cat "
          "| grep 'Apply complete'"
      ).strip().splitlines()[-1]
      assert "0 added" in stable and "0 destroyed" in stable, \
          f"post-adoption reconcile recreated resources: {stable}"
    '';
  };
}
