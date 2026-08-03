# `services.forgejo.runtime` fixtures, shared by the VM test in ./checks.nix and
# by the `forgejo-rendered-fixtures` package.
#
# why the indirection: `forgejo-rendered-fixtures` renders these through the
# real option system and renderer, so the `.tf.json` snapshot that guards
# refactors of the resource surface is produced from exactly the configuration
# the VM test proves converges against a live Forgejo.
{
  # Everything the VM test declares at boot. Spans both reference kinds (a
  # by-name organization reference, a numeric by-id repository reference), the
  # three nested single blocks, and per-secret `<attr>File` indirection.
  main = {
    organizations.acme = {
      visibility = "public";
      description = "ACME Corporation";
    };

    # owner references the managed organization by key -> ordered after it.
    # `internal_tracker` is a nested single block (the plugin-framework dialect:
    # a plain JSON object, no `[ ... ]` wrapping).
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

    # The other two nested blocks. A repository routes issues either to the
    # built-in tracker or to an external one, never both, so they need a
    # repository of their own.
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
    # (Same `<attr>File` mechanism backs action-secret data, repo auth_token,
    # and webhook authorization_header.)
    users.bob = {
      email = "bob@localhost.localdomain";
      passwordFile = "/etc/forgejo-bob-password";
      must_change_password = false;
    };
  };

  # What the VM test's `widenScope` specialisation adds on top of `main`.
  widenScope = {
    users.alice = {
      email = "alice@localhost.localdomain";
      passwordFile = "/etc/forgejo-alice-password";
      must_change_password = false;
    };
  };
}
