# forgejo-provider specifics: executor, resource types, provider block.
# shared helpers (option helpers, renderer, reconciler) live in modules/lib.
{ pkgs }:
let
  genlib = import ../../modules/lib { inherit pkgs; };
  inherit (genlib)
    oStr
    oBool
    oInt
    oListStr
    oSub
    rStr
    rBool
    rMapStr
    ;
  inherit (pkgs) lib;

  provider = import ./pkg.nix { inherit pkgs; };
  providerVersion = provider.version;
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

  # The full svalabs/forgejo resource surface. Per resource:
  #   type            the `forgejo_*` resource type
  #   prefix          unique Terraform label prefix
  #   nameAttr        attribute defaulted from the collection key (or null)
  #   scope           Forgejo token scope(s) required to manage the resource
  #   refs            parent links resolved to references against managed siblings
  #   secrets         secret-valued attributes gaining an `<attr>File` form
  #   requiredSecrets secrets the provider requires (one of `<attr>`/`<attr>File`)
  #   attrs           the settable attributes, each a typed option (no freeform)
  #   importId        (optional) declared-state -> provider import id (see
  #                   modules/lib mkImportEntries); omitted where the id is
  #                   server-assigned or the resource has no importer
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
      # imported by login.
      importId = ctx: ctx.item.login;
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
      # imported by "<owner>/<name>"; skipped when the owner is left implicit
      # (the authenticated user, whose name is not known at generation time).
      importId =
        ctx:
        let
          owner = ctx.refName "owner";
        in
        if owner == null then null else "${owner}/${ctx.item.name}";
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
      # imported by "<organization>/<team>".
      importId =
        ctx:
        let
          org = ctx.refName "organization";
        in
        if org == null then null else "${org}/${ctx.item.name}";
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
      # imported by "<owner>/<repo>/<branch>", composed from the parent
      # repository's own import id (skipped when that repo has no import id,
      # e.g. an implicit owner).
      importId =
        ctx:
        let
          repo = ctx.refImportId "repository";
        in
        if repo == null then null else "${repo}/${ctx.item.branch_name}";
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
    inherit resourceTypes providerVersion tokenVar;
    providerName = "forgejo";
    providerSource = "svalabs/forgejo";
    runtimePrefix = "services.forgejo.runtime";
    providerBlock = cfg: {
      host = cfg.baseUrl;
      api_token = "\${var.${tokenVar}}";
    };
  };
in
{
  inherit resourceTypes requiredScopes forgejoTfConfig;
  resourceOptions = genlib.resourceOptions resourceTypes;
  mkReconcileService = args: genlib.mkReconcileService (args // { inherit executor tokenVar; });
}
