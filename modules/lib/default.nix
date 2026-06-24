# shared helpers for the pairings: tf-label/file helpers, option helpers,
# resourceTypes -> nixos-options generator, .tf.json renderer + secret
# walker, and the run-once reconciler unit. provider-specific bits
# (resourceTypes contents, the provider block) live in services/<svc>/lib.nix.
{ pkgs }:
let
  inherit (pkgs) lib;
  ty = lib.types;
in
rec {

  # ---------------------------------------------------------------------------
  # option helpers
  # ---------------------------------------------------------------------------

  # o* for optional, r* for required.
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
  oAttrsStr =
    description:
    lib.mkOption {
      type = ty.nullOr (ty.attrsOf ty.str);
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
  oListSub =
    options: description:
    lib.mkOption {
      type = ty.nullOr (ty.listOf (ty.submodule { inherit options; }));
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

  # ---------------------------------------------------------------------------
  # tf-label + tf-json helpers
  # ---------------------------------------------------------------------------

  # turn an arbitrary string into a valid Terraform block label. always
  # prefixed so the result starts with a letter.
  tfLabel =
    prefix: name:
    "${prefix}_"
    + lib.stringAsChars (c: if builtins.match "[A-Za-z0-9_-]" c != null then c else "_") name;

  # write the config as a .tf.json file in the nix store. must contain no
  # secrets -- the store is world-readable.
  tfJsonFile = name: config: pkgs.writeText "${name}.tf.json" (builtins.toJSON config);

  # drop null-valued attrs (unset options) and the `_module` bookkeeping
  # key recursively, so the generated JSON carries only what was set.
  cleanNulls =
    v:
    if builtins.isAttrs v then
      lib.mapAttrs (_: cleanNulls) (lib.filterAttrs (_: x: x != null) (removeAttrs v [ "_module" ]))
    else if builtins.isList v then
      map cleanNulls v
    else
      v;

  # ---------------------------------------------------------------------------
  # resourceTypes -> nixos options
  # ---------------------------------------------------------------------------

  # one option collection per resource: attrsOf a typed submodule. options
  # are the resource's typed attrs + ref inputs + `<attr>File` siblings
  # for each top-level secret. no freeformType -- unknown attrs are eval
  # errors.
  resourceOptions =
    resourceTypes:
    lib.mapAttrs (
      _: spec:
      lib.mkOption {
        type = ty.attrsOf (
          ty.submodule {
            options =
              (spec.attrs or { })
              // lib.mapAttrs (
                _: refSpec:
                let
                  base = if refSpec.list or false then ty.listOf ty.str else ty.str;
                in
                if refSpec.required or false then
                  lib.mkOption {
                    type = base;
                    description = refSpec.description;
                  }
                else
                  lib.mkOption {
                    type = ty.nullOr base;
                    default = null;
                    description = refSpec.description;
                  }
              ) spec.refs
              // lib.listToAttrs (
                map (
                  attr:
                  lib.nameValuePair "${attr}File" (
                    lib.mkOption {
                      type = ty.nullOr ty.str;
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

  # ---------------------------------------------------------------------------
  # tf-config renderer
  # ---------------------------------------------------------------------------

  # build the .tf.json + credentials map for one pairing.
  #
  #   resourceTypes     per-service resource specs
  #   providerName      "forgejo" | "keycloak" — tf provider block name
  #   providerSource    "svalabs/forgejo" | "keycloak/keycloak"
  #   providerVersion   pinned to the packaged provider's version
  #   providerBlock     cfg -> attrs (provider's tf block contents)
  #   runtimePrefix     "services.<svc>.runtime" — for error messages
  #   tokenVar          name of the primary sensitive tf variable
  #   extraSensitiveVars  extra sensitive-tf-var names (default [])
  #
  # returns: cfg -> { config; credentials; }
  mkTfConfig =
    {
      resourceTypes,
      providerName,
      providerSource,
      providerVersion,
      providerBlock,
      runtimePrefix,
      tokenVar,
      extraSensitiveVars ? [ ],
    }:
    cfg:
    let
      # make a string valid as a tf variable / LoadCredential id.
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
          throw "${runtimePrefix}: reference '${val}' does not match any managed ${
            lib.concatMapStringsSep " or " (t: t.collection) refSpec.targets
          }"
        else
          val;

      # walk the value tree, swap every `<attr>File = "/path"` for
      # `<attr> = "${var.<id>}"` and collect [{ id; file; }] entries.
      # works at any depth (top-level attrs, nested submodules, list
      # elements). throws if both `<attr>` and `<attr>File` are set.
      substituteSecrets =
        c: spec: key:
        let
          mkId = pathParts: secretId spec key (varSafe (lib.concatStringsSep "_" pathParts));
          go =
            pathParts: v:
            if builtins.isAttrs v then
              let
                fileKeys = builtins.filter (k: lib.hasSuffix "File" k) (builtins.attrNames v);
                fileEntries = map (
                  k:
                  let
                    attr = lib.removeSuffix "File" k;
                    id = mkId (pathParts ++ [ attr ]);
                  in
                  {
                    inherit attr id;
                    file = v.${k};
                    bareConflict = v ? ${attr};
                  }
                ) fileKeys;
                conflict = builtins.filter (e: e.bareConflict) fileEntries;
                fileMap = lib.listToAttrs (
                  map (
                    e:
                    lib.nameValuePair e.attr {
                      inherit (e) id;
                      ref = "\${var.${e.id}}";
                    }
                  ) fileEntries
                );
                # walk each key: drop `*File` entries; for bare attrs in
                # fileMap, replace with `${var.<id>}`; otherwise recurse.
                processed = lib.concatMapAttrs (
                  k: x:
                  if lib.hasSuffix "File" k then
                    { }
                  else if fileMap ? ${k} then
                    { ${k} = fileMap.${k}.ref; }
                  else
                    { ${k} = (go (pathParts ++ [ k ]) x).value; }
                ) v;
                # add bare attrs from fileMap that aren't already in v
                # (user supplied `<attr>File` but no literal).
                synthesized = lib.listToAttrs (
                  map (a: lib.nameValuePair a fileMap.${a}.ref) (
                    builtins.filter (a: !(v ? ${a})) (builtins.attrNames fileMap)
                  )
                );
                localSecrets = map (e: { inherit (e) id file; }) fileEntries;
                childSecrets = lib.concatLists (
                  lib.mapAttrsToList (
                    k: x: if lib.hasSuffix "File" k || fileMap ? ${k} then [ ] else (go (pathParts ++ [ k ]) x).secrets
                  ) v
                );
              in
              if conflict != [ ] then
                throw "${runtimePrefix}.${c}.${key}: set either '${
                  lib.concatStringsSep "." (pathParts ++ [ (builtins.head conflict).attr ])
                }' or '${
                  lib.concatStringsSep "." (pathParts ++ [ ((builtins.head conflict).attr + "File") ])
                }', not both"
              else
                {
                  value = processed // synthesized;
                  secrets = localSecrets ++ childSecrets;
                }
            else if builtins.isList v then
              let
                # include the list index in the path so two elements with
                # the same `<attr>File` key don't collide on credential id.
                mapped = lib.imap0 (i: e: go (pathParts ++ [ (toString i) ]) e) v;
              in
              {
                value = map (m: m.value) mapped;
                secrets = lib.concatLists (map (m: m.secrets) mapped);
              }
            else
              {
                value = v;
                secrets = [ ];
              };
        in
        go [ ];

      renderItem =
        c: spec: key: item:
        let
          # drop ref keys (re-injected as refAttrs below). *File siblings
          # are kept -- substituteSecrets handles them after cleanNulls.
          virtuals = builtins.attrNames spec.refs;
          base = removeAttrs item ([ "_module" ] ++ virtuals);
          nameInject = lib.optionalAttrs (spec.nameAttr != null && (item.${spec.nameAttr} or null) == null) {
            ${spec.nameAttr} = key;
          };
          refAttrs = lib.concatMapAttrs (
            refName: refSpec:
            let
              v = item.${refName} or null;
            in
            lib.optionalAttrs (v != null) {
              ${refSpec.attr} =
                if refSpec.list or false then map (resolveRef refSpec) v else resolveRef refSpec v;
            }
          ) spec.refs;
          # required secret: literal or `<attr>File` must be set.
          reqSecretChecks = map (
            attr:
            if (item.${attr} or null) == null && (item.${attr + "File"} or null) == null then
              throw "${runtimePrefix}.${c}.${key}: set either '${attr}' or '${attr}File' (required)"
            else
              null
          ) (spec.requiredSecrets or [ ]);
          # required map / list attrs: nixos modules default attrsOf / listOf
          # to {} / [] rather than treating "unset" as undefined; enforce
          # non-empty here.
          reqAttrChecks = map (
            attr:
            let
              # nameAttr inherits the collection key when the user omits it,
              # so check the post-injection value -- not the raw item.
              v = (item // nameInject).${attr} or null;
            in
            if v == null || v == { } || v == [ ] || v == "" then
              throw "${runtimePrefix}.${c}.${key}: '${attr}' is required and must be non-empty"
            else
              null
          ) (spec.requiredAttrs or [ ]);
          # wrap nested MaxItems:1 blocks in `[ obj ]` so terraform reads
          # them as blocks. spec.blockAttrs lists dotted paths; recurses
          # through attrsets and list elements.
          wrapBlocks =
            path: v:
            if builtins.isAttrs v then
              lib.mapAttrs (
                k: x:
                let
                  childPath = if path == "" then k else "${path}.${k}";
                  wrapped = wrapBlocks childPath x;
                in
                if builtins.elem childPath (spec.blockAttrs or [ ]) && builtins.isAttrs wrapped then
                  [ wrapped ]
                else
                  wrapped
              ) v
            else if builtins.isList v then
              map (wrapBlocks path) v
            else
              v;
          cleaned = cleanNulls (base // nameInject // refAttrs);
          substituted = substituteSecrets c spec key cleaned;
          wrapped = wrapBlocks "" substituted.value;
        in
        # deepSeq forces the checks to run.
        # (they're not nixos assertions because we generate the .tf.json
        # outside a full system build too.)
        builtins.deepSeq [ reqSecretChecks reqAttrChecks ] {
          label = tfLabel spec.prefix key;
          value = wrapped;
          inherit (substituted) secrets;
        };

      nonEmpty = lib.filterAttrs (c: _: (cfg.${c} or { }) != { }) resourceTypes;
      # for each collection: [ { label; value; secrets } ... ].
      renderedPerCollection = lib.mapAttrs (
        c: items: lib.mapAttrsToList (key: item: renderItem c resourceTypes.${c} key item) items
      ) (lib.intersectAttrs nonEmpty cfg);
      resourceBlocks = lib.mapAttrs' (
        c: items:
        lib.nameValuePair resourceTypes.${c}.type (
          lib.listToAttrs (map (r: lib.nameValuePair r.label r.value) items)
        )
      ) renderedPerCollection;

      # every secret across the config (for sensitive tf vars + the
      # id -> host path map fed to LoadCredential).
      allSecrets = lib.concatLists (
        lib.concatLists (lib.mapAttrsToList (_: items: map (r: r.secrets) items) renderedPerCollection)
      );
      secretIds = map (e: e.id) allSecrets;

      sensitiveVar = {
        type = "string";
        sensitive = true;
      };

      config = {
        terraform.required_providers.${providerName} = {
          source = providerSource;
          version = providerVersion;
        };
        variable = {
          ${tokenVar} = sensitiveVar;
        }
        // lib.listToAttrs (map (v: lib.nameValuePair v sensitiveVar) extraSensitiveVars)
        // lib.listToAttrs (map (e: lib.nameValuePair e.id sensitiveVar) allSecrets);
        provider.${providerName} = providerBlock cfg;
      }
      // lib.optionalAttrs (resourceBlocks != { }) { resource = resourceBlocks; };

      credentials =
        if lib.length secretIds != lib.length (lib.unique secretIds) then
          throw "${runtimePrefix}: secret credential id collision (${toString secretIds}); rename the colliding resource keys"
        else
          lib.listToAttrs (map (e: lib.nameValuePair e.id e.file) allSecrets);
    in
    {
      inherit config credentials;
    };

  # ---------------------------------------------------------------------------
  # run-once reconciler systemd service
  # ---------------------------------------------------------------------------

  # build the run-once reconciler systemd service.
  #
  #   name        unit + generated-config name (e.g. "declarative-forgejo")
  #   tfConfig    the .tf.json config to apply
  #   afterUnits  units to order/require after (the service's main unit)
  #   healthUrl   url polled until the service answers, before applying
  #   tokenFile   path to the admin token on the host, read via LoadCredential
  #   executor    OpenTofu wrapped with the pairing's provider (offline)
  #   tokenVar    name of the sensitive tf variable carrying the token; also
  #               the LoadCredential id -- exported as TF_VAR_<tokenVar>
  #   credentials extra TF_VAR_<id> -> host path pairs for per-resource
  #               secrets, handled the same way as tokenFile
  #   user/group  the service's user/group; the reconciler runs as them
  #   stateDir    base dir for the reconciler; tfstate lives in a
  #               `declarative-terraform` subdir of it
  #   dynamicUser set when the base service uses systemd DynamicUser=true
  #               (the `User=` name only exists per-unit). the reconciler
  #               then runs with DynamicUser=true too, so it picks up the
  #               same hashed UID as the main unit, and systemd creates
  #               the work dir via StateDirectory= (derived from stateDir).
  #               requires stateDir to live under /var/lib.
  mkReconcileService =
    {
      name,
      tfConfig,
      afterUnits,
      healthUrl,
      tokenFile,
      executor,
      tokenVar,
      user,
      group,
      stateDir,
      credentials ? { },
      dynamicUser ? false,
    }:
    let
      confFile = tfJsonFile name tfConfig;
      # admin token + per-resource secrets, all read via LoadCredential
      # so they never land in the world-readable store.
      allCredentials = {
        ${tokenVar} = tokenFile;
      }
      // credentials;
      # tfstate lives in this subdir of stateDir.
      workDir = "${stateDir}/declarative-terraform";
      # under DynamicUser= systemd creates the dir via StateDirectory=
      # (relative to /var/lib). derive both from stateDir so the script
      # path and the unit declaration cannot drift.
      stateDirectoryRelative = lib.removePrefix "/var/lib/" workDir;
    in
    assert lib.assertMsg (!dynamicUser || lib.hasPrefix "/var/lib/" stateDir)
      "mkReconcileService: dynamicUser=true requires stateDir to live under /var/lib (got '${stateDir}'), so systemd can express the work dir as a relative StateDirectory=.";
    {
      description = "Declarative reconciliation for ${name} (OpenTofu)";
      after = afterUnits;
      requires = afterUnits;
      wantedBy = [ "multi-user.target" ];
      # re-apply when the generated config changes.
      restartTriggers = [ confFile ];
      path = [
        executor
        pkgs.curl
        pkgs.coreutils
      ];
      environment = {
        TF_IN_AUTOMATION = "1";
        TF_INPUT = "0";
      };
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        # run as the service's own user so tfstate sits next to its data.
        User = user;
        Group = group;
        # secrets stay out of the store; loaded into $CREDENTIALS_DIRECTORY at runtime.
        LoadCredential = lib.mapAttrsToList (id: path: "${id}:${path}") allCredentials;
      }
      // lib.optionalAttrs dynamicUser {
        # services like Keycloak use DynamicUser=true and have no
        # persistent state dir. systemd hashes the User= name to a
        # stable UID that's shared across units and owns the state dir.
        DynamicUser = true;
        StateDirectory = stateDirectoryRelative;
        StateDirectoryMode = "0700";
      };
      script = ''
        set -euo pipefail
        umask 077

        # work in a subdir of the service's state dir; created 0700 on
        # first run, owned by the service user.
        mkdir -p ${lib.escapeShellArg workDir}
        cd ${lib.escapeShellArg workDir}

        # refresh the generated config (tfstate persists across runs).
        install -m 0600 ${confFile} ./main.tf.json

        # wait for the service to actually answer before applying.
        for _ in $(seq 1 60); do
          if curl -fsS -o /dev/null "${healthUrl}"; then
            break
          fi
          sleep 2
        done

        # pass each credential to tofu as TF_VAR_<id>.
        for id in ${lib.escapeShellArgs (lib.attrNames allCredentials)}; do
          export "TF_VAR_$id=$(cat "$CREDENTIALS_DIRECTORY/$id")"
        done
        tofu init -no-color
        tofu apply -auto-approve -input=false -no-color
      '';
    };
}
