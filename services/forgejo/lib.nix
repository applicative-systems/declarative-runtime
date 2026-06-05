# Forgejo-provider specifics: the forgejo-wrapped OpenTofu executor and the
# .tf.json generation for a Forgejo pairing. The provider-agnostic helpers
# (label/file/reconciler) live in modules/lib and are specialized here for the
# svalabs/forgejo provider (vendored in ./pkg.nix).
#
# Every svalabs/forgejo *resource* is exposed as an option collection
# (`resourceOptions`): `attrsOf` a submodule whose options are the resource's
# settable attributes, each declared with the NixOS type the corresponding
# provider attribute accepts (so a wrong name, type, or missing required field is
# an eval-time error -- `nix flake check` -- not an apply-time one). The option
# set is derived from the provider schema (`tofu providers schema -json` for
# svalabs/forgejo 1.5.0); computed/output-only attributes are omitted. The
# attrset key becomes the Terraform label (and, for name-bearing resources, the
# default name/login). Parent links are resolved to Terraform references against
# other managed resources (see `resourceTypes.<c>.refs`), which both wires the
# `*_id` numeric attributes a user cannot know and orders `tofu apply` correctly.
#
# Imported as `import ./lib.nix { inherit pkgs; }` from the Forgejo module and
# checks.
{ pkgs }:
let
  inherit (pkgs) lib;
  genlib = import ../../modules/lib { inherit pkgs; };
  inherit (genlib) tfLabel;

  provider = import ./pkg.nix { inherit pkgs; };

  # Pin required_providers to the vendored provider version so the manifest
  # always matches the offline mirror.
  providerVersion = provider.version;

  # Terraform input variable (and LoadCredential id) carrying the admin token.
  tokenVar = "forgejo_api_token";

  # OpenTofu wrapped with the svalabs/forgejo provider. The provider lives in
  # the wrapper's NIX_TERRAFORM_PLUGIN_DIR, so `tofu init`/`apply` resolve it
  # with no registry access.
  executor = pkgs.opentofu.withPlugins (_: [ provider ]);

  ty = lib.types;

  # Per-attribute option constructors. `o*` declare an *optional* attribute
  # (`nullOr T`, default null -> omitted from the generated `.tf.json` when
  # unset); `r*` declare a *required* attribute (no default -> a missing value is
  # an eval-time error). Each carries the exact value shape the provider accepts.
  oStr =
    description:
    lib.mkOption {
      type = ty.nullOr ty.str;
      default = null;
      inherit description;
    };
  oBool =
    description:
    lib.mkOption {
      type = ty.nullOr ty.bool;
      default = null;
      inherit description;
    };
  oInt =
    description:
    lib.mkOption {
      type = ty.nullOr ty.int;
      default = null;
      inherit description;
    };
  oListStr =
    description:
    lib.mkOption {
      type = ty.nullOr (ty.listOf ty.str);
      default = null;
      inherit description;
    };
  oSub =
    options: description:
    lib.mkOption {
      type = ty.nullOr (ty.submodule { inherit options; });
      default = null;
      inherit description;
    };
  rStr =
    description:
    lib.mkOption {
      type = ty.str;
      inherit description;
    };
  rBool =
    description:
    lib.mkOption {
      type = ty.bool;
      inherit description;
    };
  rMapStr =
    description:
    lib.mkOption {
      type = ty.attrsOf ty.str;
      inherit description;
    };

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

  # The full svalabs/forgejo resource surface. Per resource:
  #   type            the `forgejo_*` resource type
  #   prefix          unique Terraform label prefix
  #   nameAttr        attribute defaulted from the collection key (or null)
  #   scope           Forgejo token scope(s) required to manage the resource
  #   refs            parent links resolved to references against managed siblings
  #   secrets         secret-valued attributes gaining an `<attr>File` form
  #   requiredSecrets secrets the provider requires (one of `<attr>`/`<attr>File`)
  #   attrs           the settable attributes, each a typed option (no freeform)
  resourceTypes = {
    organizations = {
      type = "forgejo_organization";
      prefix = "org";
      nameAttr = "name";
      scope = "write:organization";
      refs = { };
      description = "Forgejo organizations, keyed by organization name.";
      attrs = {
        name = oStr "Name of the organization. Defaults to the attribute key.";
        description = oStr "Description of the organization.";
        full_name = oStr "Full name of the organization.";
        location = oStr "Location of the organization.";
        repo_admin_change_team_access = oBool "Whether repository admins can add and remove team access.";
        visibility = oStr "Visibility: 'public' (default), 'limited', or 'private'.";
        website = oStr "Website of the organization.";
      };
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
      secrets = [ "password" ];
      requiredSecrets = [ "password" ];
      description = "Forgejo users, keyed by login. Requires administrative privileges.";
      attrs = {
        login = oStr "Login name of the user. Defaults to the attribute key.";
        email = rStr "Email address of the user.";
        password = oStr "Password of the user. Prefer `passwordFile` for a real secret.";
        full_name = oStr "Full name of the user.";
        description = oStr "Description of the user.";
        location = oStr "Location of the user.";
        website = oStr "Website of the user.";
        login_name = oStr "Login name used against the authentication source.";
        visibility = oStr "Visibility: 'public' (default), 'limited', or 'private'.";
        active = oBool "Is the user active?";
        admin = oBool "Is the user an administrator?";
        allow_create_organization = oBool "Allow the user to create organizations?";
        allow_git_hook = oBool "Allow the user to create Git hooks?";
        allow_import_local = oBool "Allow the user to import local repositories?";
        must_change_password = oBool "Require the user to change password on next login?";
        prohibit_login = oBool "Are user logins prohibited?";
        restricted = oBool "Is the user restricted?";
        send_notify = oBool "Send a notification to administrators on creation?";
        deactivate_on_destroy = oBool "Deactivate the user instead of deleting it?";
        max_repo_creation = oInt "Maximum number of repositories the user can create (-1 = no limit).";
        source_id = oInt "Numeric identifier of the user's authentication source.";
      };
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
      secrets = [ "auth_token" ];
      description = "Forgejo repositories, keyed by repository name.";
      attrs = {
        name = oStr "Name of the repository. Defaults to the attribute key.";
        description = oStr "Description of the repository.";
        website = oStr "Website of the repository.";
        default_branch = oStr "Default branch of the repository.";
        default_merge_style = oStr "Default merge style (effective only when pull requests are enabled).";
        default_update_style = oStr "Default pull-request update style.";
        trust_model = oStr "Trust model of the repository.";
        readme = oStr "Readme template to use when auto-initializing.";
        gitignores = oStr "Gitignore templates to use when auto-initializing.";
        issue_labels = oStr "Issue label set to use when auto-initializing.";
        license = oStr "License template to use when auto-initializing.";
        wiki_branch = oStr "Branch used for the repository wiki.";
        clone_addr = oStr "Migrate / clone source URL (creates a migrated repository).";
        service = oStr "Service to migrate from (effective only when `clone_addr` is set).";
        mirror_interval = oStr "Mirror sync interval (effective only when `mirror` is true).";
        lfs_endpoint = oStr "LFS endpoint to use during migration.";
        auth_token = oStr "API token for the migrate / clone URL. Prefer `auth_tokenFile`.";
        private = oBool "Is the repository private?";
        template = oBool "Is the repository a template?";
        archived = oBool "Is the repository archived?";
        archive_on_destroy = oBool "Archive the repository instead of deleting it?";
        auto_init = oBool "Auto-initialize the repository?";
        has_actions = oBool "Are integrated CI/CD pipelines enabled?";
        has_issues = oBool "Is the issue tracker enabled?";
        has_packages = oBool "Is the package registry enabled?";
        has_projects = oBool "Are repository projects enabled?";
        has_pull_requests = oBool "Are pull requests enabled?";
        has_releases = oBool "Are releases enabled?";
        has_wiki = oBool "Is the wiki enabled?";
        globally_editable_wiki = oBool "Is the wiki globally editable?";
        allow_merge_commits = oBool "Allow creating merge commits?";
        allow_squash_merge = oBool "Allow squash merges?";
        allow_rebase = oBool "Allow rebase then fast-forward?";
        allow_rebase_explicit = oBool "Allow rebase then create a merge commit?";
        allow_rebase_update = oBool "Allow updating a pull-request branch by rebase?";
        allow_fast_forward_only_merge = oBool "Allow fast-forward-only merges?";
        allow_manual_merge = oBool "Allow marking pull requests manually merged?";
        autodetect_manual_merge = oBool "Auto-detect manual pull-request merges?";
        default_allow_maintainer_edit = oBool "Allow maintainer edits on pull requests by default?";
        default_delete_branch_after_merge = oBool "Delete the branch after merge by default?";
        ignore_whitespace_conflicts = oBool "Ignore whitespace conflicts?";
        enable_prune = oBool "Prune obsolete remote-tracking refs when mirroring?";
        labels = oBool "Migrate labels (effective only when `clone_addr` is set)?";
        lfs = oBool "Migrate LFS files (effective only when `clone_addr` is set)?";
        milestones = oBool "Migrate milestones (effective only when `clone_addr` is set)?";
        mirror = oBool "Is the repository a mirror (effective only when `clone_addr` is set)?";
        external_tracker = oSub {
          external_tracker_url = rStr "External issue tracker URL.";
          external_tracker_format = rStr "External issue tracker URL format.";
          external_tracker_style = oStr "External issue tracker number format style.";
          external_tracker_regexp_pattern = oStr "Regular expression matching issue references.";
        } "External issue tracker settings (effective only when `has_issues` is true).";
        external_wiki = oSub {
          external_wiki_url = rStr "External wiki URL.";
        } "External wiki settings (effective only when `has_wiki` is true).";
        internal_tracker = oSub {
          enable_time_tracker = oBool "Enable time tracking.";
          allow_only_contributors_to_track_time = oBool "Let only contributors track time.";
          enable_issue_dependencies = oBool "Enable issue dependencies.";
        } "Built-in issue tracker settings (effective only when `has_issues` is true).";
      };
    };
    teams = {
      type = "forgejo_team";
      prefix = "team";
      nameAttr = "name";
      scope = "write:organization";
      refs.organization = orgNameRef;
      requiredAttrs = [ "units_map" ];
      description = "Forgejo organization teams, keyed by team name.";
      attrs = {
        name = oStr "Name of the team. Defaults to the attribute key.";
        units_map = rMapStr "Map of access units to permission level (e.g. { \"repo.code\" = \"read\"; }).";
        description = oStr "Description of the team.";
        permission = oStr "Permission within the organization. If 'admin' or 'owner', set every `units_map` unit to 'admin' too.";
        can_create_org_repo = oBool "Can the team create organization repositories?";
        includes_all_repositories = oBool "Does the team have access to all repositories?";
      };
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
      attrs = { };
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
      attrs = {
        permission = rStr "Permission of the collaborator: 'read', 'write', or 'admin'.";
      };
    };
    repository_webhooks = {
      type = "forgejo_repository_webhook";
      prefix = "repo_webhook";
      nameAttr = null;
      scope = "write:repository";
      refs.repository = repoRef;
      requiredAttrs = [ "config" ];
      secrets = [ "authorization_header" ];
      description = "Forgejo repository webhooks, keyed by an arbitrary label.";
      attrs = {
        type = rStr "Type of webhook (e.g. 'forgejo', 'gitea', 'slack').";
        config = rMapStr "Map of webhook configuration settings (e.g. url, content_type).";
        events = oListStr "Events that trigger the webhook.";
        branch_filter = oStr "Glob of branches the webhook reports on (empty or '*' = all).";
        active = oBool "Is the webhook active?";
        authorization_header = oStr "Authorization header sent to the target. Prefer `authorization_headerFile`.";
      };
    };
    branch_protections = {
      type = "forgejo_branch_protection";
      prefix = "branch_protection";
      nameAttr = null;
      scope = "write:repository";
      refs.repository = repoRef;
      description = "Forgejo branch protections, keyed by an arbitrary label.";
      attrs = {
        branch_name = rStr "Name of the branch (or glob) to protect.";
        required_approvals = oInt "Number of required approvals.";
        protected_file_patterns = oStr "Protected file patterns (semicolon-separated).";
        unprotected_file_patterns = oStr "Unprotected file patterns (semicolon-separated).";
        enable_push = oBool "Allow pushing to the branch?";
        enable_push_whitelist = oBool "Restrict push to whitelisted users/teams?";
        enable_merge_whitelist = oBool "Restrict merge to whitelisted users/teams?";
        enable_approvals_whitelist = oBool "Restrict approvals to whitelisted users/teams?";
        enable_status_check = oBool "Require status checks?";
        block_on_official_review_requests = oBool "Block merge on official review requests?";
        block_on_outdated_branch = oBool "Block merge if the pull request is outdated?";
        block_on_rejected_reviews = oBool "Block merge on rejected reviews?";
        dismiss_stale_approvals = oBool "Dismiss stale approvals?";
        require_signed_commits = oBool "Require signed commits?";
        push_whitelist_deploy_keys = oBool "Allow whitelisted deploy keys to push?";
        push_whitelist_usernames = oListStr "Users whitelisted for pushing.";
        push_whitelist_teams = oListStr "Teams whitelisted for pushing.";
        merge_whitelist_usernames = oListStr "Users whitelisted for merging.";
        merge_whitelist_teams = oListStr "Teams whitelisted for merging.";
        approvals_whitelist_usernames = oListStr "Users whitelisted for reviewing.";
        approvals_whitelist_teams = oListStr "Teams whitelisted for reviewing.";
        status_check_contexts = oListStr "Status check patterns required to pass.";
      };
    };
    deploy_keys = {
      type = "forgejo_deploy_key";
      prefix = "deploy_key";
      nameAttr = null;
      scope = "write:repository";
      refs.repository = repoRef;
      description = "Forgejo repository deploy keys, keyed by an arbitrary label.";
      attrs = {
        key = rStr "Armored SSH public key (no trailing newline).";
        title = rStr "Title of the deploy key.";
        read_only = rBool "Does the key have read-only access?";
      };
    };
    repository_action_secrets = {
      type = "forgejo_repository_action_secret";
      prefix = "repo_action_secret";
      nameAttr = "name";
      scope = "write:repository";
      refs.repository = repoRef;
      secrets = [ "data" ];
      requiredSecrets = [ "data" ];
      description = "Forgejo repository Actions secrets, keyed by secret name.";
      attrs = {
        name = oStr "Name of the secret. Defaults to the attribute key.";
        data = oStr "Value of the secret. Prefer `dataFile` to keep it out of the world-readable store.";
      };
    };
    repository_action_variables = {
      type = "forgejo_repository_action_variable";
      prefix = "repo_action_var";
      nameAttr = "name";
      scope = "write:repository";
      refs.repository = repoRef;
      description = "Forgejo repository Actions variables, keyed by variable name.";
      attrs = {
        name = oStr "Name of the variable. Defaults to the attribute key.";
        data = rStr "Value of the variable.";
      };
    };
    organization_action_secrets = {
      type = "forgejo_organization_action_secret";
      prefix = "org_action_secret";
      nameAttr = "name";
      scope = "write:organization";
      refs.organization = orgNameRef;
      secrets = [ "data" ];
      requiredSecrets = [ "data" ];
      description = "Forgejo organization Actions secrets, keyed by secret name.";
      attrs = {
        name = oStr "Name of the secret. Defaults to the attribute key.";
        data = oStr "Value of the secret. Prefer `dataFile` to keep it out of the world-readable store.";
      };
    };
    organization_action_variables = {
      type = "forgejo_organization_action_variable";
      prefix = "org_action_var";
      nameAttr = "name";
      scope = "write:organization";
      refs.organization = orgNameRef;
      description = "Forgejo organization Actions variables, keyed by variable name.";
      attrs = {
        name = oStr "Name of the variable. Defaults to the attribute key.";
        data = rStr "Value of the variable.";
      };
    };
    ssh_keys = {
      type = "forgejo_ssh_key";
      prefix = "ssh_key";
      nameAttr = null;
      scope = "write:admin";
      refs.user = userRef;
      description = "Forgejo user SSH keys, keyed by an arbitrary label. Requires administrative privileges.";
      attrs = {
        key = rStr "Armored SSH public key (no trailing newline).";
        title = rStr "Title of the SSH key.";
      };
    };
    gpg_keys = {
      type = "forgejo_gpg_key";
      prefix = "gpg_key";
      nameAttr = null;
      scope = "write:user";
      refs = { };
      description = "Forgejo GPG keys for the authenticated user, keyed by an arbitrary label.";
      attrs = {
        armored_public_key = rStr "Armored GPG public key.";
      };
    };
  };

  # One option collection per resource: an `attrsOf` strictly-typed submodule.
  # The submodule's options are the resource's settable attributes, plus the
  # reference inputs (resolved into Terraform references at generation) and one
  # `<attr>File` input per secret. No `freeformType`: an undeclared attribute is
  # a definition error.
  resourceOptions = lib.mapAttrs (
    _: spec:
    lib.mkOption {
      type = lib.types.attrsOf (
        lib.types.submodule {
          options =
            (spec.attrs or { })
            // lib.mapAttrs (
              _: refSpec:
              if refSpec.required or false then
                lib.mkOption {
                  type = lib.types.str;
                  description = refSpec.description;
                }
              else
                lib.mkOption {
                  type = lib.types.nullOr lib.types.str;
                  default = null;
                  description = refSpec.description;
                }
            ) spec.refs
            // lib.listToAttrs (
              map (
                attr:
                lib.nameValuePair "${attr}File" (
                  lib.mkOption {
                    type = lib.types.nullOr lib.types.str;
                    default = null;
                    description = "Runtime path to a file holding `${attr}` (loaded via systemd LoadCredential=; never copied to the store). Mutually exclusive with a literal `${attr}`.";
                  }
                )
              ) (spec.secrets or [ ])
            );
        }
      );
      default = { };
      description = spec.description;
    }
  ) resourceTypes;

  # Comma-separated union of token scopes for the declared resource collections
  # (a least-privilege set for the config).
  #
  # Currently unused: the bootstrap mints a maximally-scoped ("all") token to
  # avoid ever having to re-mint (see module.nix). Retained for Forgejo >= 16,
  # where the admin token API (PR #12323, v16.0.0) lets the bootstrap re-mint
  # cleanly on scope change and we can request `requiredScopes cfg` + write:admin
  # instead of the maximal scope.
  requiredScopes =
    cfg:
    let
      used = lib.filterAttrs (c: _: (cfg.${c} or { }) != { }) resourceTypes;
      scopes = lib.unique (lib.flatten (lib.mapAttrsToList (_: spec: spec.scope) used));
    in
    if scopes == [ ] then "write:organization" else lib.concatStringsSep "," scopes;

  # Recursively drop null-valued attributes (unset options) and the submodule
  # bookkeeping key `_module`, so the generated JSON carries only what the user
  # actually set -- at every nesting level, including the typed nested objects
  # (external_tracker, ...).
  cleanNulls =
    v:
    if builtins.isAttrs v then
      lib.mapAttrs (_: cleanNulls) (lib.filterAttrs (_: x: x != null) (removeAttrs v [ "_module" ]))
    else if builtins.isList v then
      map cleanNulls v
    else
      v;

  # Build the Terraform JSON config for a Forgejo pairing from the module's cfg,
  # together with the (id -> host path) credential map for any host-file-sourced
  # secrets. Returns { config; credentials; }.
  #
  # Contains NO provider secret: the admin token and every `<attr>File` secret
  # are supplied at apply time as sensitive input variables fed from systemd
  # `LoadCredential=`, never written to the store. A *literal* secret attribute
  # (e.g. `data`/`password` set directly) still lands in the world-readable
  # store -- use the matching `<attr>File` option to avoid that.
  forgejoTfConfig =
    cfg:
    let
      # Var-safe id (Terraform variable name + LoadCredential id) for a secret.
      varSafe = lib.stringAsChars (c: if builtins.match "[A-Za-z0-9_]" c != null then c else "_");
      secretId =
        spec: key: attr:
        "secret_${spec.prefix}_${varSafe key}_${attr}";

      resolveRef =
        refSpec: val:
        let
          tryTarget =
            t:
            let
              tspec = resourceTypes.${t.collection};
            in
            if (cfg.${t.collection} or { }) ? ${val} then
              "\${" + tspec.type + "." + tfLabel tspec.prefix val + "." + t.field + "}"
            else
              null;
          hits = builtins.filter (x: x != null) (map tryTarget refSpec.targets);
        in
        if hits != [ ] then
          builtins.head hits
        else if refSpec.managedOnly then
          throw "services.forgejo.runtime: reference '${val}' does not match any managed ${
            lib.concatMapStringsSep " or " (t: t.collection) refSpec.targets
          }"
        else
          val;

      # Host-file-sourced secrets of one item: [{ attr; id; path; }]. Throws if
      # both the literal attribute and its `<attr>File` are set.
      itemSecrets =
        c: spec: key: item:
        lib.concatMap (
          attr:
          let
            file = item.${attr + "File"} or null;
          in
          lib.optionals (file != null) (
            if (item.${attr} or null) != null then
              throw "services.forgejo.runtime.${c}.${key}: set either '${attr}' or '${attr}File', not both"
            else
              [
                {
                  inherit attr;
                  id = secretId spec key attr;
                  path = file;
                }
              ]
          )
        ) (spec.secrets or [ ]);

      renderItem =
        c: spec: key: item:
        let
          secretEntries = itemSecrets c spec key item;
          virtuals = builtins.attrNames spec.refs ++ map (s: "${s}File") (spec.secrets or [ ]);
          base = removeAttrs item ([ "_module" ] ++ virtuals);
          nameInject = lib.optionalAttrs (spec.nameAttr != null && (item.${spec.nameAttr} or null) == null) {
            ${spec.nameAttr} = key;
          };
          refAttrs = lib.concatMapAttrs (
            refName: refSpec:
            lib.optionalAttrs (item.${refName} or null != null) {
              ${refSpec.attr} = resolveRef refSpec item.${refName};
            }
          ) spec.refs;
          secretAttrs = lib.listToAttrs (map (e: lib.nameValuePair e.attr "\${var.${e.id}}") secretEntries);
          # A required secret must be supplied via either the literal or its file.
          reqSecretChecks = map (
            attr:
            if (item.${attr} or null) == null && (item.${attr + "File"} or null) == null then
              throw "services.forgejo.runtime.${c}.${key}: set either '${attr}' or '${attr}File' (required)"
            else
              null
          ) (spec.requiredSecrets or [ ]);
          # Required map/list attributes: the module system gives `attrsOf`/
          # `listOf` an empty-value default ({}/[]) rather than treating a missing
          # value as undefined, so a "required" collection is enforced here.
          reqAttrChecks = map (
            attr:
            let
              v = item.${attr} or null;
            in
            if v == null || v == { } || v == [ ] then
              throw "services.forgejo.runtime.${c}.${key}: '${attr}' is required and must be non-empty"
            else
              null
          ) (spec.requiredAttrs or [ ]);
        in
        # deepSeq forces the validation thunks (whose results are otherwise unused)
        # so a violated check `throw`s here. These live in the generator, not in
        # NixOS `config.assertions`, because assertions only fire during a full
        # NixOS system evaluation -- whereas `forgejoTfConfig` is also called
        # standalone (e.g. tests, `nix eval`), where assertions would be silently
        # skipped and a malformed config would surface opaquely at `tofu apply`.
        lib.nameValuePair (tfLabel spec.prefix key) (
          builtins.deepSeq [ reqSecretChecks reqAttrChecks ] (
            cleanNulls (base // nameInject // refAttrs // secretAttrs)
          )
        );

      nonEmpty = lib.filterAttrs (c: _: (cfg.${c} or { }) != { }) resourceTypes;
      resourceBlocks = lib.mapAttrs' (
        c: spec: lib.nameValuePair spec.type (lib.mapAttrs' (renderItem c spec) cfg.${c})
      ) nonEmpty;

      # Every host-file-sourced secret across the config, for the sensitive input
      # variables and the (id -> host path) credential map.
      allSecrets = lib.concatLists (
        lib.mapAttrsToList (
          c: spec: lib.concatLists (lib.mapAttrsToList (key: item: itemSecrets c spec key item) cfg.${c})
        ) nonEmpty
      );
      secretIds = map (e: e.id) allSecrets;

      config = {
        terraform.required_providers.forgejo = {
          source = "svalabs/forgejo";
          version = providerVersion;
        };
        variable = {
          ${tokenVar} = {
            type = "string";
            sensitive = true;
          };
        }
        // lib.listToAttrs (
          map (
            e:
            lib.nameValuePair e.id {
              type = "string";
              sensitive = true;
            }
          ) allSecrets
        );
        provider.forgejo = {
          host = cfg.baseUrl;
          api_token = "\${var.${tokenVar}}";
        };
      }
      // lib.optionalAttrs (resourceBlocks != { }) { resource = resourceBlocks; };

      credentials =
        if lib.length secretIds != lib.length (lib.unique secretIds) then
          throw "services.forgejo.runtime: secret credential id collision (${toString secretIds}); rename the colliding resource keys"
        else
          lib.listToAttrs (map (e: lib.nameValuePair e.id e.path) allSecrets);
    in
    {
      inherit config credentials;
    };
in
{
  inherit
    resourceTypes
    resourceOptions
    requiredScopes
    forgejoTfConfig
    ;

  # The generic run-once reconciler, specialized with the forgejo executor and
  # the forgejo_api_token credential.
  mkReconcileService = args: genlib.mkReconcileService (args // { inherit executor tokenVar; });
}
