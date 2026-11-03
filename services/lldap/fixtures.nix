# `services.lldap.runtime` fixtures, shared by the VM test in ./checks.nix and
# by the `lldap-rendered-fixtures` package.
#
# why the indirection: `lldap-rendered-fixtures` renders these through the
# real option system and renderer, so the `.tf.json` snapshot that guards
# refactors of the resource surface is produced from exactly the configuration
# the VM test proves converges against a live lldap.
{
  # Everything the VM test declares at boot. Spans all nine resources, each
  # kind of reference (to a user, a group and an attribute, single and as a
  # list), and per-secret `<attr>File` indirection.
  #
  # The three membership resources manage disjoint memberships: `ops` is
  # authoritative for its members, `carol` for her groups, and `alice` is in
  # `developers` through a single membership.
  main = {
    users.alice = {
      email = "alice@example.com";
      display_name = "Alice Liddell";
      first_name = "Alice";
      last_name = "Liddell";
      # The password comes from a host file via LoadCredential, so the literal
      # never lands in the generated .tf.json.
      passwordFile = "/etc/lldap-alice-password";
    };
    users.bob.email = "bob@example.com";
    users.carol.email = "carol@example.com";

    groups.developers = { };
    groups.ops = { };
    groups.readers = { };

    user_attributes.department = {
      attribute_type = "STRING";
      is_visible = true;
      is_editable = false;
    };
    group_attributes.cost-centers = {
      attribute_type = "INTEGER";
      is_list = true;
    };

    # user and group reference the managed user and group by their keys ->
    # emitted as `${lldap_user.<k>.username}` and `${lldap_group.<k>.id}`.
    members.alice_developers = {
      user = "alice";
      group = "developers";
    };
    group_memberships.ops = {
      group = "ops";
      users = [
        "alice"
        "bob"
      ];
    };
    user_memberships.carol = {
      user = "carol";
      groups = [ "readers" ];
    };

    user_attribute_assignments.alice_department = {
      user = "alice";
      attribute = "department";
      value = [ "engineering" ];
    };
    group_attribute_assignments.ops_cost_centers = {
      group = "ops";
      attribute = "cost-centers";
      value = [
        "1200"
        "1300"
      ];
    };
  };
}
