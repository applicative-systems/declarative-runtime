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
    user.alice = {
      email = "alice@example.com";
      display_name = "Alice Liddell";
      first_name = "Alice";
      last_name = "Liddell";
      # The password comes from a host file via LoadCredential, so the literal
      # never lands in the generated .tf.json.
      passwordFile = "/etc/lldap-alice-password";
    };
    user.bob.email = "bob@example.com";
    user.carol.email = "carol@example.com";

    group.developers = { };
    group.ops = { };
    group.readers = { };

    user_attribute.department = {
      attribute_type = "STRING";
      is_visible = true;
      is_editable = false;
    };
    group_attribute.cost-centers = {
      attribute_type = "INTEGER";
      is_list = true;
    };

    # user_id and group_id reference the managed user and group by their keys ->
    # emitted as `${lldap_user.<k>.username}` and `${lldap_group.<k>.id}`.
    member.alice_developers = {
      user_id = "alice";
      group_id = "developers";
    };
    group_memberships.ops = {
      group_id = "ops";
      user_ids = [
        "alice"
        "bob"
      ];
    };
    user_memberships.carol = {
      user_id = "carol";
      group_ids = [ "readers" ];
    };

    user_attribute_assignment.alice_department = {
      user_id = "alice";
      attribute_id = "department";
      value = [ "engineering" ];
    };
    group_attribute_assignment.ops_cost_centers = {
      group_id = "ops";
      attribute_id = "cost-centers";
      value = [
        "1200"
        "1300"
      ];
    };
  };
}
