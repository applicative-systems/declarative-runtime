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
{ pkgs, nixTfSchema }:
let
  genlib = import ../../modules/lib { inherit pkgs; };
  tfSchema = import ../../modules/lib/tf-schema.nix { inherit pkgs nixTfSchema; };
  inherit (pkgs) lib;

  provider = import ./pkg.nix { inherit pkgs; };
  providerVersion = provider.version;
  # provider source address; also keys the vendored provider schema.
  providerSource = "svalabs/forgejo";
  runtimePrefix = "services.forgejo.runtime";
  tokenVar = "forgejo_api_token";
  executor = pkgs.opentofu.withPlugins (_: [ provider ]);

  # Reference specs, reused across resources. `attr` is the Terraform attribute
  # emitted; `targets` are the managed collections (in priority order) whose key
  # the user names; `field` is the referenced attribute. `managedOnly` references
  # (numeric ids) MUST resolve to a managed sibling -- there is no literal a user
  # could supply. `required` declares the reference input as a required option.
  repoRef = {
    attr = "repository_id";
    targets = [
      {
        collection = "repositories";
        field = "id";
      }
    ];
    managedOnly = true;
    required = true;
    description = "Key of the managed repository (services.forgejo.runtime.repositories.<name>) this belongs to.";
  };
  orgNameRef = {
    attr = "organization";
    targets = [
      {
        collection = "organizations";
        field = "name";
      }
    ];
    managedOnly = false;
    required = true;
    description = "Owning organization: the key of a managed organization, or a literal organization name.";
  };
  userRef = {
    attr = "user";
    targets = [
      {
        collection = "users";
        field = "login";
      }
    ];
    managedOnly = false;
    required = true;
    description = "Target user: the key of a managed user, or a literal username.";
  };

  # The provider accepts an owning organization either by name or by numeric id
  # and requires exactly one of the two. `orgNameRef` already covers both a
  # managed sibling and a literal name, so the numeric twin is dropped rather
  # than offered as a way to violate that constraint.
  omitOrgId = [ "organization_id" ];

  # The svalabs/forgejo resource surface. Per collection, only the facts the
  # schema does not carry (see modules/lib/tf-schema.nix for the full overlay
  # vocabulary):
  #   type         the `forgejo_*` resource type in the schema
  #   prefix       unique Terraform label prefix
  #   nameAttr     attribute defaulted from the collection key (or null)
  #   scope        Forgejo token scope(s) required to manage the resource
  #   refs         parent links resolved to references against managed siblings
  #   description  the collection's NixOS option description
  generated = tfSchema.mkResourceTypes {
    schema = import ./schema.nix;
    inherit provider runtimePrefix;
    source = providerSource;
    resources = {
      organizations = {
        type = "forgejo_organization";
        prefix = "org";
        nameAttr = "name";
        scope = "write:organization";
        refs = { };
        description = "Forgejo organizations, keyed by organization name.";
      };
      users = {
        type = "forgejo_user";
        prefix = "user";
        nameAttr = "login";
        # Create goes through the admin API (write:admin); the provider reads the
        # user back via /users/search (read:user), a separate scope category.
        scope = [
          "write:admin"
          "read:user"
        ];
        refs = { };
        description = "Forgejo users, keyed by login. Requires administrative privileges.";
      };
      repositories = {
        type = "forgejo_repository";
        prefix = "repo";
        nameAttr = "name";
        scope = "write:repository";
        refs.owner = {
          attr = "owner";
          targets = [
            {
              collection = "organizations";
              field = "name";
            }
            {
              collection = "users";
              field = "login";
            }
          ];
          managedOnly = false;
          required = false;
          description = "Repository owner: the key of a managed organization or user, a literal owner name, or null for the authenticated user.";
        };
        description = "Forgejo repositories, keyed by repository name.";
      };
      teams = {
        type = "forgejo_team";
        prefix = "team";
        nameAttr = "name";
        scope = "write:organization";
        refs.organization = orgNameRef;
        omit = omitOrgId;
        description = "Forgejo organization teams, keyed by team name.";
      };
      team_members = {
        type = "forgejo_team_member";
        prefix = "team_member";
        nameAttr = null;
        scope = "write:organization";
        refs = {
          team = {
            attr = "team_id";
            targets = [
              {
                collection = "teams";
                field = "id";
              }
            ];
            managedOnly = true;
            required = true;
            description = "Key of the managed team (services.forgejo.runtime.teams.<name>) the member is added to.";
          };
          user = userRef;
        };
        description = "Forgejo team memberships, keyed by an arbitrary label.";
      };
      collaborators = {
        type = "forgejo_collaborator";
        prefix = "collab";
        nameAttr = null;
        scope = "write:repository";
        refs = {
          repository = repoRef;
          user = userRef;
        };
        description = "Forgejo repository collaborators, keyed by an arbitrary label.";
      };
      branch_protections = {
        type = "forgejo_branch_protection";
        prefix = "branch_protection";
        nameAttr = null;
        scope = "write:repository";
        refs.repository = repoRef;
        description = "Forgejo branch protections, keyed by an arbitrary label.";
      };
      deploy_keys = {
        type = "forgejo_deploy_key";
        prefix = "deploy_key";
        nameAttr = null;
        scope = "write:repository";
        refs.repository = repoRef;
        description = "Forgejo repository deploy keys, keyed by an arbitrary label.";
      };
      repository_webhooks = {
        type = "forgejo_repository_webhook";
        prefix = "repo_webhook";
        nameAttr = null;
        scope = "write:repository";
        refs.repository = repoRef;
        description = "Forgejo repository webhooks, keyed by an arbitrary label.";
      };
      repository_action_secrets = {
        type = "forgejo_repository_action_secret";
        prefix = "repo_action_secret";
        nameAttr = "name";
        scope = "write:repository";
        refs.repository = repoRef;
        description = "Forgejo repository Actions secrets, keyed by secret name.";
      };
      repository_action_variables = {
        type = "forgejo_repository_action_variable";
        prefix = "repo_action_var";
        nameAttr = "name";
        scope = "write:repository";
        refs.repository = repoRef;
        description = "Forgejo repository Actions variables, keyed by variable name.";
      };
      organization_action_secrets = {
        type = "forgejo_organization_action_secret";
        prefix = "org_action_secret";
        nameAttr = "name";
        scope = "write:organization";
        refs.organization = orgNameRef;
        omit = omitOrgId;
        description = "Forgejo organization Actions secrets, keyed by secret name.";
      };
      organization_action_variables = {
        type = "forgejo_organization_action_variable";
        prefix = "org_action_var";
        nameAttr = "name";
        scope = "write:organization";
        refs.organization = orgNameRef;
        omit = omitOrgId;
        description = "Forgejo organization Actions variables, keyed by variable name.";
      };
      ssh_keys = {
        type = "forgejo_ssh_key";
        prefix = "ssh_key";
        nameAttr = null;
        scope = "write:admin";
        refs.user = userRef;
        description = "Forgejo user SSH keys, keyed by an arbitrary label. Requires administrative privileges.";
      };
      gpg_keys = {
        type = "forgejo_gpg_key";
        prefix = "gpg_key";
        nameAttr = null;
        scope = "write:user";
        refs = { };
        description = "Forgejo GPG keys for the authenticated user, keyed by an arbitrary label.";
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
  # the generator's drift assertions, for the pairing's checks to force
  # independently of any particular configuration.
  inherit (generated) checks;
  resourceOptions = genlib.resourceOptions resourceTypes;
  mkReconcileService = args: genlib.mkReconcileService (args // { inherit executor tokenVar; });
}
