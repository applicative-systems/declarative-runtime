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

        # Stand-in for an operator-managed secret file (sops/agenix in production):
        # bob's password, fed to the reconciler via LoadCredential, never the store.
        environment.etc."forgejo-bob-password".text = "hackme";

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
            password = "hackme";
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

      # Re-applying must be idempotent (a second run must also succeed).
      machine.succeed("systemctl restart declarative-forgejo.service")

      # Adding an admin-scoped resource (a user needs write:admin + read:user)
      # mus work because the scopen is the maximal "all" token
      machine.succeed("/run/current-system/specialisation/widenScope/bin/switch-to-configuration test")
      machine.wait_until_succeeds("curl --fail http://localhost:3000/api/v1/users/alice")
    '';
  };
}
