# Pure-eval unit tests for the provider-agnostic import-plan generator
# (`mkImportEntries`) in ./default.nix. Exercised as a flake check
# (`checks.<system>.lib-import`), so import-block generation for every pairing
# is covered by one cheap eval instead of four VM boots -- the engine is
# identical across providers; only each provider's per-resource `importId`
# formula differs (and is exercised by that pairing's VM test).
#
# The synthetic resource surface below intentionally mirrors the shapes the real
# providers hit: a plain name id, a composite `<owner>/<name>` id resolved
# through a name reference (managed sibling *and* literal), an id composed from a
# sibling's own import id through a managed-only numeric-id reference
# (`<repo import id>/<branch>`), resources with no `importId` (skipped), and
# items whose `importId` returns null (skipped).
{ pkgs }:
let
  genlib = import ./. { inherit pkgs; };

  resourceTypes = {
    orgs = {
      type = "x_org";
      prefix = "org";
      nameAttr = "name";
      refs = { };
      # imported by name (defaulted from the key).
      importId = ctx: ctx.item.name;
    };
    users = {
      type = "x_user";
      prefix = "user";
      nameAttr = "login";
      refs = { };
      importId = ctx: ctx.item.login;
    };
    repos = {
      type = "x_repo";
      prefix = "repo";
      nameAttr = "name";
      # name reference: a managed org/user key, or a literal owner name.
      refs.owner = {
        attr = "owner";
        targets = [
          {
            collection = "orgs";
            field = "name";
          }
          {
            collection = "users";
            field = "login";
          }
        ];
        managedOnly = false;
      };
      # composite `<owner>/<name>`; skipped when owner is unset.
      importId =
        ctx:
        let
          owner = ctx.refName "owner";
        in
        if owner == null then null else "${owner}/${ctx.item.name}";
    };
    branches = {
      type = "x_branch";
      prefix = "branch";
      nameAttr = null;
      # managed-only numeric-id reference (the user names a managed repo).
      refs.repository = {
        attr = "repository_id";
        targets = [
          {
            collection = "repos";
            field = "id";
          }
        ];
        managedOnly = true;
      };
      # composed from the parent repo's own import id.
      importId =
        ctx:
        let
          repo = ctx.refImportId "repository";
        in
        if repo == null then null else "${repo}/${ctx.item.branch_name}";
    };
    # no `importId` -> never contributes an import block.
    secrets = {
      type = "x_secret";
      prefix = "secret";
      nameAttr = "name";
      refs = { };
    };
  };

  # Full config including the edge cases that must be *skipped*.
  cfg = {
    orgs.acme = {
      name = "acme";
    };
    users.bob = {
      login = "bob";
    };
    # explicit nameAttr overrides the key -> id is the override, not the key.
    users.alice = {
      login = "al";
    };
    # owner is a managed org -> resolves to the org's name.
    repos.widgets = {
      name = "widgets";
      owner = "acme";
    };
    # owner is a managed user key whose login differs from the key -> resolves
    # to the sibling's nameAttr value ("al"), not the key ("alice").
    repos.gadget = {
      name = "gadget";
      owner = "alice";
    };
    # owner is a literal (unmanaged) name -> used verbatim.
    repos.tools = {
      name = "tools";
      owner = "external";
    };
    # a managed user whose nameAttr (login) is explicitly null -- exactly what a
    # NixOS submodule produces when the user relies on the key default. refName
    # must fall back to the key ("carol"), so this repo imports as "carol/cr".
    users.carol = {
      login = null;
    };
    repos.carolRepo = {
      name = "cr";
      owner = "carol";
    };
    # owner unset -> importId returns null -> skipped.
    repos.orphan = {
      name = "orphan";
      owner = null;
    };
    # composes to "acme/widgets/main" through the managed repo's import id.
    branches.main = {
      branch_name = "main";
      repository = "widgets";
    };
    # references a repo that is not managed -> refImportId null -> skipped.
    branches.dangling = {
      branch_name = "x";
      repository = "nope";
    };
    # has no importId -> skipped.
    secrets.s1 = {
      name = "s1";
    };
  };

  got = genlib.mkImportEntries resourceTypes cfg;

  # sorted by `to`: branch < org < repo < user; repo_carolRepo < repo_gadget <
  # repo_tools < repo_widgets; user_alice < user_bob < user_carol.
  want = [
    {
      to = "x_branch.branch_main";
      id = "acme/widgets/main";
    }
    {
      to = "x_org.org_acme";
      id = "acme";
    }
    {
      to = "x_repo.repo_carolRepo";
      id = "carol/cr";
    }
    {
      to = "x_repo.repo_gadget";
      id = "al/gadget";
    }
    {
      to = "x_repo.repo_tools";
      id = "external/tools";
    }
    {
      to = "x_repo.repo_widgets";
      id = "acme/widgets";
    }
    {
      to = "x_user.user_alice";
      id = "al";
    }
    {
      to = "x_user.user_bob";
      id = "bob";
    }
    {
      to = "x_user.user_carol";
      id = "carol";
    }
  ];

  # A clean subset (no skip cases) proving mkTfConfig threads importEntries and
  # renders the same plan the standalone generator produces.
  cleanCfg = {
    orgs.acme = {
      name = "acme";
    };
    repos.widgets = {
      name = "widgets";
      owner = "acme";
    };
  };
  tf = genlib.mkTfConfig {
    inherit resourceTypes;
    providerName = "x";
    providerSource = "x/x";
    providerVersion = "0.0.0";
    providerBlock = _: { host = "local"; };
    runtimePrefix = "test";
    tokenVar = "x_token";
  } cleanCfg;
in
{
  lib-import =
    pkgs.runCommand "declarative-lib-import-test"
      {
        got = builtins.toJSON got;
        want = builtins.toJSON want;
        wired = builtins.toJSON tf.importEntries;
        wiredWant = builtins.toJSON (genlib.mkImportEntries resourceTypes cleanCfg);
      }
      ''
        fail=0
        if [ "$got" != "$want" ]; then
          echo "mkImportEntries plan mismatch" >&2
          echo "  got:  $got" >&2
          echo "  want: $want" >&2
          fail=1
        fi
        if [ "$wired" != "$wiredWant" ]; then
          echo "mkTfConfig did not thread importEntries" >&2
          echo "  got:  $wired" >&2
          echo "  want: $wiredWant" >&2
          fail=1
        fi
        if [ "$wired" = "[]" ]; then
          echo "expected a non-empty import plan from mkTfConfig" >&2
          fail=1
        fi
        [ "$fail" -eq 0 ] || exit 1
        echo "import plan matches expected" > "$out"
      '';
}
