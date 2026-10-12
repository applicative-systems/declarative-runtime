# tasansga/lldap provider specifics: executor, resource surface, provider block.
#
# The resource surface is *derived* from the vendored provider schema
# (./provider-schema.json, parsed by ./schema.nix) via
# ../../modules/lib/tf-schema.nix. What stays hand-written is only what a schema
# cannot state: the reference graph between resources, and the few facts the
# provider's own descriptions lack. A provider bump that adds, removes or
# retypes anything is then an eval-time error rather than an apply-time
# surprise.
#
# Shared helpers (option helpers, renderer, reconciler) live in modules/lib.
{ pkgs, nix-tf-schema }:
let
  genlib = import ../../modules/lib { inherit pkgs; };
  tfSchema = import ../../modules/lib/tf-schema.nix { inherit pkgs nix-tf-schema; };

  provider = pkgs.terraform-providers.tasansga_lldap;
  providerVersion = provider.version;
  # provider source address; also keys the vendored provider schema.
  providerSource = "tasansga/lldap";
  runtimePrefix = "services.lldap.runtime";
  # The password of the admin user the provider logs in as.
  tokenVar = "lldap_admin_password";
  executor = pkgs.opentofu.withPlugins (_: [ provider ]);

  # A reference to a user, a group, or an attribute of either. A user's id is
  # its user name; a group's id is a number that lldap assigns.
  userRef = {
    targets = [
      {
        type = "user";
        field = "username";
      }
    ];
    managedOnly = false;
  };
  groupRef = {
    targets = [
      {
        type = "group";
        field = "id";
      }
    ];
    managedOnly = false;
  };
  attributeRef = type: {
    targets = [
      {
        inherit type;
        # An attribute's id is its name.
        field = "id";
      }
    ];
    managedOnly = false;
  };

  # The tasansga/lldap resource surface. Per resource, only the facts the
  # schema does not carry (see modules/lib/tf-schema.nix for the full overlay
  # vocabulary). lldap has no token scopes.
  generated = tfSchema.mkResourceTypes {
    schema = import ./schema.nix;
    inherit provider runtimePrefix;
    source = providerSource;
    resources = {
      user.nameAttr = "username";
      group = {
        nameAttr = "display_name";
        description = "lldap groups. The built-in groups (`lldap_admin` and others) are not in this collection: lldap makes them.";
      };
      user_attribute = { };
      group_attribute = { };
      member = {
        refs = {
          user_id = userRef;
          group_id = groupRef;
        };
        description = "Single memberships of a user in a group. Other memberships of the user and the group are kept.";
      };
      group_memberships = {
        refs = {
          group_id = groupRef;
          user_ids = userRef;
        };
        description = "The full member list of a group. Members that are not in the list are removed, so do not also use `members` or `user_memberships` for the same group.";
      };
      user_memberships = {
        refs = {
          user_id = userRef;
          group_ids = groupRef;
        };
        description = "The full group list of a user. Groups that are not in the list are removed, so do not also use `members` or `group_memberships` for the same user.";
      };
      user_attribute_assignment.refs = {
        user_id = userRef;
        attribute_id = attributeRef "user_attribute";
      };
      group_attribute_assignment.refs = {
        group_id = groupRef;
        attribute_id = attributeRef "group_attribute";
      };
    };
  };
  inherit (generated) resourceTypes;

  lldapTfConfig = genlib.mkTfConfig {
    inherit
      resourceTypes
      providerVersion
      providerSource
      runtimePrefix
      tokenVar
      ;
    providerName = "lldap";
    providerBlock = cfg: {
      http_url = cfg.baseUrl;
      # The provider dials LDAP only to set a user's password.
      ldap_url = cfg.ldapUrl;
      username = cfg.adminUser;
      password = "\${var.${tokenVar}}";
      base_dn = cfg.baseDN;
    };
  };
in
{
  inherit
    provider
    providerSource
    resourceTypes
    lldapTfConfig
    ;
  # the generator's drift assertions and coverage data, for the pairing's checks
  # to force independently of any particular configuration.
  inherit (generated) checks coverage;
  resourceOptions = genlib.resourceOptions resourceTypes;
  mkReconcileService = args: genlib.mkReconcileService (args // { inherit executor tokenVar; });
}
