# Keycloak-provider specifics: the keycloak-wrapped OpenTofu executor and the
# .tf.json generation for a Keycloak pairing. The provider-agnostic helpers
# (label/file/reconciler) live in modules/lib and are specialized here for the
# keycloak/keycloak provider (in nixpkgs as
# `pkgs.terraform-providers.keycloak_keycloak`).
#
# The first-wave resource surface is `keycloak_realm` only; follow-ups add
# clients, scopes, roles, groups, users, identity providers, and mappers in
# the same shape (the `resourceTypes` record is extended; the renderer is
# already provider-agnostic).
#
# Two divergences from the forgejo template, forced by upstream Keycloak's
# shape:
#
#   1. Auth is OAuth2 client-credentials, not a single API token. Two
#      sensitive Terraform variables are emitted: `keycloak_client_secret`
#      (the primary, threaded through the generic reconciler as `tokenVar`)
#      and `keycloak_client_id` (an extra credential id flowed through the
#      generic reconciler's `credentials` map). Both are fed from systemd
#      `LoadCredential=` at apply time, never written to the world-readable
#      store.
#
#   2. The upstream NixOS keycloak module runs as `DynamicUser=true` with no
#      persistent state directory. The module therefore enables the new
#      `dynamicUser`/`stateDirectory` modes of `mkReconcileService` so the
#      reconciler is allocated the same hashed UID as `keycloak.service` and
#      writes its Terraform state into a systemd-managed StateDirectory at
#      `/var/lib/keycloak/declarative-terraform`.
#
# Imported as `import ./lib.nix { inherit pkgs; }` from the Keycloak module
# and checks.
{ pkgs }:
let
  inherit (pkgs) lib;
  genlib = import ../../modules/lib { inherit pkgs; };
  inherit (genlib) tfLabel;

  # In-nixpkgs provider; pin `required_providers` to its packaged version so
  # the offline plugin mirror always matches the manifest.
  provider = pkgs.terraform-providers.keycloak_keycloak;
  providerVersion = provider.version;

  # OAuth2 client-credentials grant: two paired sensitive variables.
  # `tokenVar` is the primary credential flowed through the generic
  # reconciler; `clientIdVar` is exported so module.nix can wire the matching
  # bootstrap-produced (or operator-supplied) file into the reconciler's
  # `credentials` map.
  tokenVar = "keycloak_client_secret";
  clientIdVar = "keycloak_client_id";

  # OpenTofu wrapped with the keycloak/keycloak provider. The provider binary
  # lives in the wrapper's NIX_TERRAFORM_PLUGIN_DIR, so `tofu init`/`apply`
  # resolve it with no registry access.
  executor = pkgs.opentofu.withPlugins (_: [ provider ]);

  ty = lib.types;

  # Per-attribute option constructors. `o*` declare an *optional* attribute
  # (`nullOr T`, default null -> omitted from the generated `.tf.json` when
  # unset); `r*` declare a *required* attribute (no default -> a missing value
  # is an eval-time error). Each carries the exact value shape the provider
  # accepts.
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

  # The full keycloak/keycloak resource surface (first wave: realm only). Per
  # resource:
  #   type            the `keycloak_*` resource type
  #   prefix          unique Terraform label prefix
  #   nameAttr        attribute defaulted from the collection key (or null)
  #   scope           reserved for future per-resource scoping; null under
  #                   client-credentials auth
  #   refs            parent links resolved to references against managed
  #                   siblings
  #   secrets         secret-valued attributes gaining an `<attr>File` form
  #   requiredSecrets secrets the provider requires (one of `<attr>`/`<attr>File`)
  #   attrs           the settable attributes, each a typed option (no
  #                   freeform)
  resourceTypes = {
    realms = {
      type = "keycloak_realm";
      prefix = "realm";
      nameAttr = "realm";
      scope = null;
      refs = { };
      description = "Keycloak realms, keyed by realm name.";
      attrs = {
        realm = oStr "Realm name. Defaults to the attribute key.";
        enabled = oBool "Is the realm enabled?";
        display_name = oStr "User-facing display name.";
        display_name_html = oStr "HTML-formatted display name.";
      };
    };
  };

  # One option collection per resource: an `attrsOf` strictly-typed submodule.
  # The submodule's options are the resource's settable attributes, plus the
  # reference inputs (resolved into Terraform references at generation) and
  # one `<attr>File` input per secret. No `freeformType`: an undeclared
  # attribute is a definition error.
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

  # Recursively drop null-valued attributes (unset options) and the submodule
  # bookkeeping key `_module`, so the generated JSON carries only what the
  # user actually set -- at every nesting level, including any typed nested
  # objects added by later resources.
  cleanNulls =
    v:
    if builtins.isAttrs v then
      lib.mapAttrs (_: cleanNulls) (lib.filterAttrs (_: x: x != null) (removeAttrs v [ "_module" ]))
    else if builtins.isList v then
      map cleanNulls v
    else
      v;

  # Build the Terraform JSON config for a Keycloak pairing from the module's
  # cfg, together with the (id -> host path) credential map for any
  # host-file-sourced secrets. Returns { config; credentials; }.
  #
  # Contains NO provider secret: the `client_id`/`client_secret` pair and
  # every `<attr>File` secret are supplied at apply time as sensitive input
  # variables fed from systemd `LoadCredential=`, never written to the store.
  # A *literal* secret attribute (e.g. a value set directly) still lands in
  # the world-readable store -- use the matching `<attr>File` option to avoid
  # that.
  keycloakTfConfig =
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
          throw "services.keycloak.runtime: reference '${val}' does not match any managed ${
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
              throw "services.keycloak.runtime.${c}.${key}: set either '${attr}' or '${attr}File', not both"
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
              throw "services.keycloak.runtime.${c}.${key}: set either '${attr}' or '${attr}File' (required)"
            else
              null
          ) (spec.requiredSecrets or [ ]);
          # Required map/list attributes: the module system gives `attrsOf`/
          # `listOf` an empty-value default ({}/[]) rather than treating a
          # missing value as undefined, so a "required" collection is enforced
          # here.
          reqAttrChecks = map (
            attr:
            let
              v = item.${attr} or null;
            in
            if v == null || v == { } || v == [ ] then
              throw "services.keycloak.runtime.${c}.${key}: '${attr}' is required and must be non-empty"
            else
              null
          ) (spec.requiredAttrs or [ ]);
        in
        # deepSeq forces the validation thunks (whose results are otherwise
        # unused) so a violated check `throw`s here. These live in the
        # generator, not in NixOS `config.assertions`, because assertions only
        # fire during a full NixOS system evaluation -- whereas
        # `keycloakTfConfig` is also called standalone (e.g. tests, `nix
        # eval`), where assertions would be silently skipped and a malformed
        # config would surface opaquely at `tofu apply`.
        lib.nameValuePair (tfLabel spec.prefix key) (
          builtins.deepSeq [ reqSecretChecks reqAttrChecks ] (
            cleanNulls (base // nameInject // refAttrs // secretAttrs)
          )
        );

      nonEmpty = lib.filterAttrs (c: _: (cfg.${c} or { }) != { }) resourceTypes;
      resourceBlocks = lib.mapAttrs' (
        c: spec: lib.nameValuePair spec.type (lib.mapAttrs' (renderItem c spec) cfg.${c})
      ) nonEmpty;

      # Every host-file-sourced secret across the config, for the sensitive
      # input variables and the (id -> host path) credential map.
      allSecrets = lib.concatLists (
        lib.mapAttrsToList (
          c: spec: lib.concatLists (lib.mapAttrsToList (key: item: itemSecrets c spec key item) cfg.${c})
        ) nonEmpty
      );
      secretIds = map (e: e.id) allSecrets;

      config = {
        terraform.required_providers.keycloak = {
          source = "keycloak/keycloak";
          version = providerVersion;
        };
        variable = {
          ${tokenVar} = {
            type = "string";
            sensitive = true;
          };
          ${clientIdVar} = {
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
        provider.keycloak = {
          url = cfg.baseUrl;
          realm = "master";
          client_id = "\${var.${clientIdVar}}";
          client_secret = "\${var.${tokenVar}}";
        };
      }
      // lib.optionalAttrs (resourceBlocks != { }) { resource = resourceBlocks; };

      credentials =
        if lib.length secretIds != lib.length (lib.unique secretIds) then
          throw "services.keycloak.runtime: secret credential id collision (${toString secretIds}); rename the colliding resource keys"
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
    keycloakTfConfig
    clientIdVar
    ;

  # The generic run-once reconciler, specialized with the keycloak executor
  # and the keycloak_client_secret credential.
  mkReconcileService = args: genlib.mkReconcileService (args // { inherit executor tokenVar; });
}
