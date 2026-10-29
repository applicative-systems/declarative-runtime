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
  # literal a user could supply. Option name, list-ness, optionality and
  # description come from the schema.
  repoRef = {
    targets = [
      {
        type = "forgejo_repository";
        field = "id";
      }
    ];
    managedOnly = true;
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
    # the provider's own text tells the user to set `organization_id` as an
    # alternative, which this module omits.
    description = "Name of the owning organization. Changing this forces a new resource to be created.";
  };
  userRef = {
    targets = [
      {
        type = "forgejo_user";
        field = "login";
      }
    ];
    managedOnly = false;
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
        scope = "write:organization";
      };
      forgejo_user = {
        nameAttr = "login";
        # Create goes through the admin API (write:admin); the provider reads the
        # user back via /users/search (read:user), a separate scope category.
        scope = [
          "write:admin"
          "read:user"
        ];
      };
      forgejo_repository = {
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
          description = "Owner of the repository (user or organization), or null for the authenticated user. Changing this forces a new resource to be created.";
        };
      };
      forgejo_team = {
        scope = "write:organization";
        refs.organization = orgNameRef;
        omit = omitOrgId;
      };
      forgejo_team_member = {
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
          };
          user = userRef;
        };
      };
      forgejo_collaborator = {
        scope = "write:repository";
        refs = {
          repository_id = repoRef;
          user = userRef;
        };
      };
      forgejo_branch_protection = {
        scope = "write:repository";
        refs.repository_id = repoRef;
      };
      forgejo_deploy_key = {
        scope = "write:repository";
        refs.repository_id = repoRef;
      };
      forgejo_repository_webhook = {
        scope = "write:repository";
        refs.repository_id = repoRef;
      };
      forgejo_repository_action_secret = {
        scope = "write:repository";
        refs.repository_id = repoRef;
      };
      forgejo_repository_action_variable = {
        scope = "write:repository";
        refs.repository_id = repoRef;
      };
      forgejo_organization_action_secret = {
        scope = "write:organization";
        refs.organization = orgNameRef;
        omit = omitOrgId;
      };
      forgejo_organization_action_variable = {
        scope = "write:organization";
        refs.organization = orgNameRef;
        omit = omitOrgId;
      };
      forgejo_ssh_key = {
        scope = "write:admin";
        refs.user = userRef;
      };
      forgejo_gpg_key = {
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
    legacyLabelPrefixes = import ./legacy-label-prefixes.nix;
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
