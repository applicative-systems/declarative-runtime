# Terraform label prefixes from before labels were the bare collection key
# (`<type>.<prefix>_<key>`, now `<type>.<key>`). The renderer emits a `moved`
# block for each declared resource of these types, so hosts that applied an
# older config keep their resources instead of a destroy and re-create.
#
# TODO: remove this table (and its `legacyLabelPrefixes` argument) once every
# host has applied a config with the bare labels.
{
  forgejo_branch_protection = "branch_protection";
  forgejo_collaborator = "collab";
  forgejo_deploy_key = "deploy_key";
  forgejo_gpg_key = "gpg_key";
  forgejo_organization = "org";
  forgejo_organization_action_secret = "org_action_secret";
  forgejo_organization_action_variable = "org_action_var";
  forgejo_repository = "repo";
  forgejo_repository_action_secret = "repo_action_secret";
  forgejo_repository_action_variable = "repo_action_var";
  forgejo_repository_webhook = "repo_webhook";
  forgejo_ssh_key = "ssh_key";
  forgejo_team = "team";
  forgejo_team_member = "team_member";
  forgejo_user = "user";
}
