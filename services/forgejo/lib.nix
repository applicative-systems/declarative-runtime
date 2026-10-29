# forgejo-provider specifics: executor, resource surface, provider block.
#
# The resource surface is *derived* from the vendored provider schema
# (./provider-schema.json, parsed by ./schema.nix) via
# ../../modules/lib/tf-schema.nix. What stays hand-written is only what a schema
# cannot state: the NixOS-facing collection descriptions, the reference graph
# between collections, the Forgejo token scope each resource needs, and the odd
# documented correction. A provider bump that adds, removes or retypes anything
# is then an eval-time error rather than an apply-time surprise.
#
# Shared helpers (option helpers, renderer, reconciler) live in modules/lib.
{ pkgs, nix-tf-schema }:
let
  genlib = import ../../modules/lib { inherit pkgs; };
  tfSchema = import ../../modules/lib/tf-schema.nix { inherit pkgs nix-tf-schema; };
  inherit (pkgs) lib;

  provider = import ./pkg.nix { inherit pkgs; };
  providerVersion = provider.version;
  # provider source address; also keys the vendored provider schema.
  providerSource = "svalabs/forgejo";
  runtimePrefix = "services.forgejo.runtime";
  tokenVar = "forgejo_api_token";
  executor = pkgs.opentofu.withPlugins (_: [ provider ]);

  # Reference specs, reused across resources and keyed there by the attribute
  # they fill. `targets` are the managed collections (in priority order) whose
  # key the user names; `field` is the referenced attribute. `managedOnly`
  # references (numeric ids) MUST resolve to a managed sibling -- there is no
  # literal a user could supply. Option name, list-ness and optionality come
  # from the schema.
  repoRef = {
    targets = [
      {
        type = "forgejo_repository";
        field = "id";
      }
    ];
    managedOnly = true;
    description = "Key of the managed repository (services.forgejo.runtime.repositories.<name>) this belongs to.";
  };
  orgNameRef = {
    targets = [
      {
        type = "forgejo_organization";
        field = "name";
      }
    ];
    managedOnly = false;
    # the schema marks `organization` optional because `organization_id` may
    # stand in for it; with `organization_id` omitted, it is the only way.
    required = true;
    description = "Owning organization: the key of a managed organization, or a literal organization name.";
  };
  userRef = {
    targets = [
      {
        type = "forgejo_user";
        field = "login";
      }
    ];
    managedOnly = false;
    description = "Target user: the key of a managed user, or a literal username.";
  };

  # The provider accepts an owning organization either by name or by numeric id
  # and requires exactly one of the two. `orgNameRef` already covers both a
  # managed sibling and a literal name, so the numeric twin is dropped rather
  # than offered as a way to violate that constraint.
  omitOrgId = [ "organization_id" ];

  # The svalabs/forgejo resource surface, keyed by resource type. Each type
  # becomes the collection `services.forgejo.runtime.<plural>`
  # (`forgejo_repository` -> `repositories`). Per type, only the facts the schema does not
  # carry (see modules/lib/tf-schema.nix for the full overlay vocabulary):
  #   prefix       unique Terraform label prefix
  #   nameAttr     attribute the collection key fills in, where it is not `name`
  #   scope        Forgejo token scope(s) required to manage the resource
  #   refs         parent links resolved to references against managed siblings
  #   description  the collection's NixOS option description
  generated = tfSchema.mkResourceTypes {
    schema = import ./schema.nix;
    inherit provider runtimePrefix;
    source = providerSource;
    resources = {
      forgejo_organization = {
        prefix = "org";
        scope = "write:organization";
      };
      forgejo_user = {
        prefix = "user";
        nameAttr = "login";
        # Create goes through the admin API (write:admin); the provider reads the
        # user back via /users/search (read:user), a separate scope category.
        scope = [
          "write:admin"
          "read:user"
        ];
      };
      forgejo_repository = {
        prefix = "repo";
        scope = "write:repository";
        refs.owner = {
          targets = [
            {
              type = "forgejo_organization";
              field = "name";
            }
            {
              type = "forgejo_user";
              field = "login";
            }
          ];
          managedOnly = false;
          description = "Repository owner: the key of a managed organization or user, a literal owner name, or null for the authenticated user.";
        };
      };
      forgejo_team = {
        prefix = "team";
        scope = "write:organization";
        refs.organization = orgNameRef;
        omit = omitOrgId;
      };
      forgejo_team_member = {
        prefix = "team_member";
        scope = "write:organization";
        refs = {
          team_id = {
            targets = [
              {
                type = "forgejo_team";
                field = "id";
              }
            ];
            managedOnly = true;
            description = "Key of the managed team (services.forgejo.runtime.teams.<name>) the member is added to.";
          };
          user = userRef;
        };
      };
      forgejo_collaborator = {
        prefix = "collab";
        scope = "write:repository";
        refs = {
          repository_id = repoRef;
          user = userRef;
        };
      };
      forgejo_branch_protection = {
        prefix = "branch_protection";
        scope = "write:repository";
        refs.repository_id = repoRef;
      };
      forgejo_deploy_key = {
        prefix = "deploy_key";
        scope = "write:repository";
        refs.repository_id = repoRef;
      };
      forgejo_repository_webhook = {
        prefix = "repo_webhook";
        scope = "write:repository";
        refs.repository_id = repoRef;
      };
      forgejo_repository_action_secret = {
        prefix = "repo_action_secret";
        scope = "write:repository";
        refs.repository_id = repoRef;
      };
      forgejo_repository_action_variable = {
        prefix = "repo_action_var";
        scope = "write:repository";
        refs.repository_id = repoRef;
      };
      forgejo_organization_action_secret = {
        prefix = "org_action_secret";
        scope = "write:organization";
        refs.organization = orgNameRef;
        omit = omitOrgId;
      };
      forgejo_organization_action_variable = {
        prefix = "org_action_var";
        scope = "write:organization";
        refs.organization = orgNameRef;
        omit = omitOrgId;
      };
      forgejo_ssh_key = {
        prefix = "ssh_key";
        scope = "write:admin";
        refs.user = userRef;
      };
      forgejo_gpg_key = {
        prefix = "gpg_key";
        scope = "write:user";
        description = "Forgejo GPG keys for the authenticated user.";
      };
    };
  };

  inherit (generated) resourceTypes;

  # union of token scopes for the declared resource collections (least-
  # privilege set for the config). currently dormant: the bootstrap mints
  # a maximally-scoped ("all") token to avoid having to re-mint. switch
  # to `requiredScopes cfg` + write:admin once on Forgejo >= 16, where
  # the admin token API can re-mint cleanly on scope change.
  requiredScopes =
    cfg:
    let
      used = lib.filterAttrs (c: _: (cfg.${c} or { }) != { }) resourceTypes;
      scopes = lib.unique (lib.flatten (lib.mapAttrsToList (_: spec: spec.scope) used));
    in
    if scopes == [ ] then "write:organization" else lib.concatStringsSep "," scopes;

  forgejoTfConfig = genlib.mkTfConfig {
    inherit
      resourceTypes
      providerVersion
      providerSource
      runtimePrefix
      tokenVar
      ;
    providerName = "forgejo";
    providerBlock = cfg: {
      host = cfg.baseUrl;
      api_token = "\${var.${tokenVar}}";
    };
  };
in
{
  inherit
    provider
    providerSource
    resourceTypes
    requiredScopes
    forgejoTfConfig
    ;
  # the generator's drift assertions and coverage data, for the pairing's checks
  # to force independently of any particular configuration.
  inherit (generated) checks coverage;
  resourceOptions = genlib.resourceOptions resourceTypes;
  mkReconcileService = args: genlib.mkReconcileService (args // { inherit executor tokenVar; });
}
