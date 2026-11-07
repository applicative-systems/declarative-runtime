# Terraform label prefixes from before labels were the bare collection key
# (`<type>.<prefix>_<key>`, now `<type>.<key>`). The renderer emits a `moved`
# block for each declared resource of these types, so hosts that applied an
# older config keep their resources instead of a destroy and re-create.
#
# TODO: remove this table (and its `legacyLabelPrefixes` argument) once every
# host has applied a config with the bare labels.
{
  incus_certificate = "certificate";
  incus_cluster_group = "cluster_group";
  incus_network = "network";
  incus_network_acl = "network_acl";
  incus_network_address_set = "network_address_set";
  incus_network_forward = "network_forward";
  incus_network_integration = "network_integration";
  incus_network_lb = "network_lb";
  incus_network_peer = "network_peer";
  incus_network_zone = "network_zone";
  incus_network_zone_record = "network_zone_record";
  incus_profile = "profile";
  incus_project = "project";
  incus_server = "server";
  incus_storage_bucket = "storage_bucket";
  incus_storage_bucket_key = "storage_bucket_key";
  incus_storage_pool = "storage_pool";
  incus_storage_volume = "storage_volume";
}
