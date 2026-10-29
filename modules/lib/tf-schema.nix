# derive a pairing's `resourceTypes` record from its vendored provider schema.
#
# why: a hand-written resource surface makes provider drift invisible. an
# attribute added, removed or retyped upstream only surfaces when `tofu apply`
# fails on someone's machine -- if at all. reflecting the schema instead turns
# every such change into an eval-time error at `nix flake check`, and leaves a
# pairing carrying only what a schema cannot express: the NixOS-facing
# descriptions, the reference graph between collections, and a short list of
# documented corrections (the "overlay").
#
# split of responsibility: `nix-tf-schema` knows schema facts (which attributes
# are settable, both nesting dialects, TF type -> Nix type). everything here is
# about `resourceTypes` shape, secret indirection, and drift assertions. the
# renderer in ./default.nix consumes the result unchanged.
{
  pkgs,
  nix-tf-schema,
}:
let
  inherit (pkgs) lib;
  ty = lib.types;
  conv = pkgs.callPackage "${nix-tf-schema}/conversion.nix" { };

  inherit (lib)
    attrNames
    concatMapAttrs
    concatStringsSep
    elem
    filter
    flatten
    length
    mapAttrsToList
    optionalAttrs
    subtractLists
    unique
    ;

  # schema `format_version`s this generator knows how to read.
  knownFormatVersions = [ "1.0" ];

  # terraform type constructors that make an attribute a collection.
  collectionTypes = [
    "list"
    "set"
    "map"
  ];

  # `[ "list" "string" ]` -> `list(string)`, for generated descriptions.
  renderTfType =
    l: if length l <= 1 then lib.head l else "${lib.head l}(${renderTfType (lib.tail l)})";

  sortStrings = lib.sort builtins.lessThan;

  # elements occurring more than once, deduplicated.
  duplicates = xs: unique (filter (x: lib.count (y: y == x) xs > 1) xs);

  quoteList = xs: concatStringsSep ", " (map (x: "`${x}`") xs);

  # the option name a reference input takes, from the attribute it fills: the
  # user names a managed key, not an id, so the id suffix goes.
  #   realm_id -> realm, parent_flow_alias -> parent_flow, group_ids -> groups
  refOptionName =
    attr:
    let
      strip = suffix: lib.removeSuffix suffix attr;
    in
    if lib.hasSuffix "_ids" attr then
      "${strip "_ids"}s"
    else if lib.hasSuffix "_id" attr then
      strip "_id"
    else if lib.hasSuffix "_alias" attr then
      strip "_alias"
    else
      attr;
in
{
  /*
    Build a pairing's `resourceTypes` (and its drift assertions) from a vendored
    provider schema plus a per-resource-type overlay.

      schema         parsed `provider-schema.json` (normalized: `format_version`,
                     `source`, `version`, `resource_schemas`)
      provider       the packaged provider derivation; its `version` must match
                     the vendored schema
      source         provider source address, e.g. "svalabs/forgejo"
      runtimePrefix  "services.<svc>.runtime" -- for error messages
      resources      schema resource type -> overlay (see below)
      unsupported    schema resource type -> non-empty reason for not modelling it
      omitEverywhere dotted paths dropped from every collection that declares
                     them. For dialect artifacts that repeat across the whole
                     provider -- the sdk/v2 synthetic `id`, say -- not as a
                     shortcut for per-collection `omit`.

    Each resource becomes the collection `services.<svc>.runtime.<name>`, where
    `<name>` is the resource type without the provider's name, in the plural
    (`keycloak_realm` -> `realms`, `forgejo_repository` -> `repositories`).

    Every field is optional and exists only to state what a schema cannot;
    `{ }` models a resource as the schema has it. The collection key is the
    Terraform label. There is deliberately no way to declare an option with no
    schema counterpart -- `refs` is the sole exception, and that is what makes
    the drift check total.

      refs           schema attribute -> reference spec (see below)
      description    what the resource is, for the collection's NixOS option.
                     Defaults to the provider's own description, else to a
                     stub; the sentence on what a key means is always
                     generated, so it does not go here.

      nameAttr       attribute the collection key fills in. Defaults to `name`
                     when the resource has a settable string `name`, else null;
                     set it only to differ from that default.
      scope          provider token scope(s) the resource needs, or null

      oneOfRefs      ExactlyOneOf groups of `refs` attributes (a Go validator,
                     absent from schemas)
      omit           dotted paths to drop entirely
      extraSecrets   paths to treat as secret although not marked `sensitive`
      notSecrets     `sensitive` paths not to treat as secret
      forceOptional  paths required upstream but nullable here
      requiredAttrs  extra non-empty checks
      extraAttrs     last-resort typed overrides; keys must name real attributes

    A reference spec is
    `{ targets; managedOnly; required ? <schema>; description ? <schema>; }`,
    keyed by the schema attribute it fills. Each target is
    `{ type; field; }`: a modelled resource type, and the attribute of it that
    the reference resolves to. The option the user sets is named
    after that attribute (`realm_id` -> `realm`, `group_ids` -> `groups`), and
    whether it takes a list comes from the attribute's type. `required` defaults
    to the attribute's own flag and may only be set to differ from it -- for
    a reference that stands in for an `ExactlyOneOf` pair, say. `description`
    replaces the attribute's own description, and only that: the sentences on
    which keys the option takes, and on any `oneOfRefs` group, are generated.

    Returns `{ resourceTypes; checks; coverage; }`. `checks` is a list of
    null-or-throw, `deepSeq`'d into `resourceTypes`, so merely forcing the
    latter fires every assertion -- a pairing cannot use the surface without
    also checking it. `coverage` is report data for `<svc>-schema-coverage`.
  */
  mkResourceTypes =
    {
      schema,
      provider,
      source,
      runtimePrefix,
      resources,
      unsupported ? { },
      omitEverywhere ? [ ],
    }:
    let
      check = cond: msg: if cond then null else throw "${runtimePrefix}: ${msg}";

      # `svalabs/forgejo` -> `forgejo`: every resource type starts with it.
      providerName = lib.last (lib.splitString "/" source);

      # the English plural of the snake_case resource name, which is what a
      # NixOS user expects to read as an attrset of instances.
      pluralize =
        s:
        if lib.hasSuffix "s" s then
          s
        else if builtins.match ".*[^aeiou]y" s != null then
          "${lib.removeSuffix "y" s}ies"
        else if builtins.match ".*(sh|ch|x)" s != null then
          "${s}es"
        else
          "${s}s";

      collectionName = type: pluralize (lib.removePrefix "${providerName}_" type);

      withDefaults =
        o:
        {
          scope = null;
          refs = { };
          oneOfRefs = [ ];
          omit = [ ];
          extraSecrets = [ ];
          notSecrets = [ ];
          forceOptional = [ ];
          requiredAttrs = [ ];
          extraAttrs = { };
        }
        // o;

      # -----------------------------------------------------------------------
      # one collection
      # -----------------------------------------------------------------------

      mkOne =
        type: rawOverlay:
        let
          o = withDefaults rawOverlay // {
            inherit type;
          };
          collection = collectionName type;
          ctx = "${runtimePrefix}.${collection}";
          # the type check has to come first: everything below indexes the
          # schema by it.
          resourceSchema =
            schema.resource_schemas.${type}
              or (throw "${runtimePrefix}: `resources` models `${type}`, which provider ${source} ${provider.version} does not have");

          # top-level nodes, and every node by dotted path.
          tree = conv.settableTree resourceSchema;
          paths = conv.settablePaths resourceSchema;

          isStringAttr =
            attr: tree ? ${attr} && tree.${attr}.kind == "attr" && flatten tree.${attr}.tfType == [ "string" ];
          defaultNameAttr = if isStringAttr "name" then "name" else null;
          nameAttr = o.nameAttr or defaultNameAttr;

          description = concatStringsSep "\n\n" [
            (o.description or resourceSchema.block.description or "`${type}` resources.")
            (
              if nameAttr == null then
                "Each key is an arbitrary label."
              else
                "Each key sets the instance's `${nameAttr}`, unless the instance sets `${nameAttr}` itself."
            )
          ];

          # attributes the reference inputs occupy: the user names a sibling
          # collection key and generation fills these in, so they must not also
          # be settable options.
          refConsumed = attrNames o.refs;
          # the global list is filtered to what this resource has, so it needs
          # no per-collection opt-in; the check that it names something real
          # runs once, provider-wide.
          droppedPaths = o.omit ++ refConsumed ++ filter (p: paths ? ${p}) omitEverywhere;
          isDropped = path: lib.any (d: path == d || lib.hasPrefix "${d}." path) droppedPaths;

          isSecret =
            path: node:
            node.kind == "attr" && (node.sensitive || elem path o.extraSecrets) && !(elem path o.notSecrets);

          isCollectionNode =
            node:
            if node.kind == "attr" then
              elem (lib.head (flatten node.tfType)) collectionTypes
            else
              !node.singleBlock && elem node.nesting collectionTypes;

          isNameAttr = path: nameAttr != null && path == nameAttr;

          # an option is emitted required (no default) only when nothing else
          # can supply it later. the four escapes:
          #   nameAttr        -- the attrset key fills it, post-injection
          #                      (./default.nix re-imposes it via requiredAttrs)
          #   secrets         -- the `<attr>File` sibling may satisfy it instead
          #   collections     -- listOf/attrsOf default to []/{} and cannot say
          #                      "unset"; an empty value would silently strip
          #                      server-side state
          #   forceOptional   -- explicit, documented exceptions
          isRequired =
            path: node:
            node.required
            && !(elem path o.forceOptional)
            && !(isSecret path node)
            && !(isNameAttr path)
            && !(isCollectionNode node);

          tfTypeLabel =
            node:
            if node.kind == "attr" then
              renderTfType (flatten node.tfType)
            else if node.singleBlock then
              "single-item ${node.nesting} block"
            else
              "${node.nesting} block";

          describe =
            path: node:
            if node.description != "" then
              node.description
            else
              "Provider attribute `${path}` (`${tfTypeLabel node}`); the provider schema carries no description for it.";

          fileOption =
            attr:
            lib.mkOption {
              type = ty.nullOr ty.str;
              default = null;
              description = "Runtime path to a file holding `${attr}` (loaded via systemd LoadCredential=; never copied to the store). Mutually exclusive with a literal `${attr}`.";
            };

          mkNodeOption =
            path: node:
            let
              nixType =
                if node.kind == "attr" then
                  conv.fromTfTypes (flatten node.tfType)
                else
                  let
                    sub = ty.submodule { options = mkOptions path node.children; };
                  in
                  if node.singleBlock then
                    sub
                  else
                    {
                      single = sub;
                      group = sub;
                      list = ty.listOf sub;
                      set = ty.listOf sub; # nix has no unordered collection type
                      map = ty.attrsOf sub;
                    }
                    .${node.nesting};
            in
            lib.mkOption (
              (
                if isRequired path node then
                  { type = nixType; }
                else
                  {
                    type = ty.nullOr nixType;
                    default = null;
                  }
              )
              // {
                description = describe path node;
              }
            );

          # nested secrets get their `<attr>File` sibling here; top-level ones
          # get theirs from `resourceOptions` in ./default.nix, off `secrets`.
          mkOptions =
            prefix: nodes:
            concatMapAttrs (
              name: node:
              let
                path = if prefix == "" then name else "${prefix}.${name}";
              in
              if isDropped path then
                { }
              else
                {
                  ${name} = mkNodeOption path node;
                }
                // optionalAttrs (prefix != "" && isSecret path node) {
                  "${name}File" = fileOption name;
                }
            ) nodes;

          topLevel = filter (p: !(isDropped p)) (attrNames tree);

          secrets = sortStrings (filter (p: isSecret p tree.${p}) topLevel);
          requiredSecrets = filter (p: tree.${p}.required && !(elem p o.forceOptional)) secrets;

          requiredAttrs = unique (
            filter (
              p:
              let
                node = tree.${p};
              in
              node.required
              && !(elem p o.forceOptional)
              && !(isSecret p node)
              && (isNameAttr p || isCollectionNode node)
            ) topLevel
            ++ o.requiredAttrs
          );

          # MaxItems:1 blocks: the user writes one object, terraform reads a
          # one-element list. only the sdk/v2 dialect produces these.
          blockAttrs = sortStrings (filter (p: paths.${p}.singleBlock && !(isDropped p)) (attrNames paths));

          sensitivePaths = filter (p: paths.${p}.sensitive) (attrNames paths);
          allPaths = attrNames paths;

          namesPaths =
            label: xs: universe:
            let
              unknown = subtractLists universe xs;
            in
            check (unknown == [ ])
              "${ctx}: ${label} names ${
                if length unknown == 1 then "an attribute" else "attributes"
              } `${o.type}` does not have: ${quoteList unknown}";

          checks = [
            (namesPaths "`omit`" o.omit allPaths)
            (namesPaths "`extraSecrets`" o.extraSecrets allPaths)
            (namesPaths "`notSecrets`" o.notSecrets allPaths)
            (namesPaths "`forceOptional`" o.forceOptional allPaths)
            (namesPaths "`requiredAttrs`" o.requiredAttrs (attrNames tree))
            (namesPaths "`extraAttrs`" (attrNames o.extraAttrs) (attrNames tree))
            (namesPaths "`refs`" refConsumed (attrNames tree))
            (check (duplicates refOptionNames == [ ])
              "${ctx}: refs ${quoteList refConsumed} derive the same option name ${quoteList (duplicates refOptionNames)}"
            )
            (check (filter (n: elem n topLevel) refOptionNames == [ ])
              "${ctx}: ref option ${
                quoteList (filter (n: elem n topLevel) refOptionNames)
              } would shadow a settable attribute of the same name"
            )
            (check (filter (p: elem p sensitivePaths) o.extraSecrets == [ ])
              "${ctx}: `extraSecrets` lists ${
                quoteList (filter (p: elem p sensitivePaths) o.extraSecrets)
              }, which the schema already marks sensitive"
            )
            (check (subtractLists sensitivePaths o.notSecrets == [ ])
              "${ctx}: `notSecrets` may only list sensitive attributes; ${quoteList (subtractLists sensitivePaths o.notSecrets)} ${
                if length (subtractLists sensitivePaths o.notSecrets) == 1 then "is" else "are"
              } not sensitive"
            )
            (check (nameAttr == null || isStringAttr nameAttr)
              "${ctx}: `nameAttr` must name a settable top-level string attribute; `${toString nameAttr}` is not one"
            )
            (check (!(o ? nameAttr) || o.nameAttr != defaultNameAttr)
              "${ctx}: `nameAttr = ${
                if defaultNameAttr == null then "null" else ''"${defaultNameAttr}"''
              }` is the default; drop it"
            )
          ]
          ++ mapAttrsToList (
            attr: refSpec:
            check (lib.all (t: resources ? ${t.type}) refSpec.targets)
              "${ctx}: ref `${attr}` targets ${
                quoteList (filter (t: !(resources ? ${t})) (map (t: t.type) refSpec.targets))
              }, which ${runtimePrefix} does not model"
          ) o.refs
          ++ mapAttrsToList (
            attr: refSpec:
            check (!(refSpec ? required) || !(tree ? ${attr}) || refSpec.required != tree.${attr}.required)
              "${ctx}: ref `${attr}` sets `required = ${lib.boolToString refSpec.required}`, which the schema already says; drop it"
          ) o.refs
          ++ map (
            group:
            check (lib.all (r: o.refs ? ${r}) group)
              "${ctx}: `oneOfRefs` names ${
                quoteList (filter (r: !(o.refs ? ${r})) group)
              }, which ${ctx} does not declare as refs"
          ) o.oneOfRefs;

          # the overlay keys refs by schema attribute; the renderer wants them
          # keyed by the option the user sets, with list-ness and optionality
          # read off the schema.
          refs = lib.mapAttrs' (
            attr: r:
            let
              node = tree.${attr} or null;
              option = refOptionName attr;
              list =
                node != null
                && node.kind == "attr"
                && elem (lib.head (flatten node.tfType)) [
                  "list"
                  "set"
                ];
              # what the attribute is, then how the user names it.
              what = r.description or (if node != null then node.description else "");
              targetList = concatStringsSep " or " (
                map (
                  t: "`${runtimePrefix}.${collectionName t.type}.<key>` (resolved to its `${t.field}`)"
                ) r.targets
              );
              how = concatStringsSep " " (
                [
                  "${if list then "Each entry is the" else "The"} key of a managed ${targetList}${
                    lib.optionalString (!r.managedOnly)
                      ", or a literal `${attr}` ${if list then "element" else "value"}"
                  }."
                ]
                ++ lib.optional (option != attr) "It fills the provider attribute `${attr}`."
                ++ map (
                  group: "Set exactly one of ${concatStringsSep " and " (map (a: "`${refOptionName a}`") group)}."
                ) (filter (elem attr) o.oneOfRefs)
              );
            in
            lib.nameValuePair option {
              inherit attr list;
              inherit (r) managedOnly;
              description = concatStringsSep "\n\n" (
                filter (s: s != "") [
                  what
                  how
                ]
              );
              # the renderer addresses a target by its collection.
              targets = map (t: {
                collection = collectionName t.type;
                inherit (t) field;
              }) r.targets;
              required = r.required or (node != null && node.required);
            }
          ) o.refs;

          refOptionNames = map refOptionName refConsumed;

          spec = {
            inherit (o)
              type
              scope
              ;
            inherit nameAttr description refs;
            oneOfRefs = map (map refOptionName) o.oneOfRefs;
            inherit
              secrets
              requiredSecrets
              requiredAttrs
              blockAttrs
              ;
            attrs = mkOptions "" tree // o.extraAttrs;
          };

          # what the pairing covers, for the generated coverage report.
          coverage = {
            inherit (o) type;
            inherit description;
            options = length (attrNames spec.attrs);
            attributes = length (attrNames tree);
            omitted = sortStrings o.omit;
            refs = sortStrings (attrNames o.refs);
            inherit secrets blockAttrs;
          };
        in
        {
          inherit
            spec
            checks
            coverage
            allPaths
            ;
        };

      built = lib.mapAttrs' (type: o: lib.nameValuePair (collectionName type) (mkOne type o)) resources;

      # -----------------------------------------------------------------------
      # provider-wide assertions
      # -----------------------------------------------------------------------

      allTypes = attrNames resources;
      allCollections = map collectionName allTypes;
      foreignTypes = filter (t: !(lib.hasPrefix "${providerName}_" t)) allTypes;
      schemaTypes = attrNames schema.resource_schemas;
      unsupportedTypes = attrNames unsupported;

      unclaimed = subtractLists (allTypes ++ unsupportedTypes) schemaTypes;

      # a path is worth omitting provider-wide only while some resource still
      # declares it; once none does, the entry is stale.
      claimedPaths = unique (lib.concatLists (mapAttrsToList (_: r: r.allPaths) built));
      staleOmit = subtractLists claimedPaths omitEverywhere;

      globalChecks = [
        # identity: the cheap guards that fire the instant nixpkgs moves the
        # provider under us. `<svc>-schema-current` is the authoritative check
        # for content changes within a single version.
        (check (
          schema.source == source
        ) "vendored schema is for provider `${schema.source}`, but this pairing is `${source}`")
        (check (schema.version == provider.version)
          "vendored schema is for ${source} ${schema.version}, but the packaged provider is ${provider.version}; run `nix run .#update-provider-schemas`"
        )
        (check (elem schema.format_version knownFormatVersions) "unrecognized schema `format_version` `${schema.format_version}` (known: ${quoteList knownFormatVersions})")

        (check (staleOmit == [ ])
          "`omitEverywhere` lists ${quoteList staleOmit}, which no modelled resource of ${source} ${provider.version} declares"
        )

        (check (foreignTypes == [ ])
          "`resources` names ${quoteList foreignTypes}, which ${
            if length foreignTypes == 1 then "does" else "do"
          } not start with `${providerName}_`"
        )
        (check (
          duplicates allCollections == [ ]
        ) "collection ${quoteList (duplicates allCollections)} would hold more than one resource type")

        # schema -> overlay: a provider bump names every new resource here.
        (check (unclaimed == [ ])
          "provider ${source} ${provider.version} has ${toString (length unclaimed)} resource(s) that are neither modelled nor listed in `unsupported`: ${quoteList unclaimed}"
        )
        (check (subtractLists schemaTypes unsupportedTypes == [ ])
          "`unsupported` names ${quoteList (subtractLists schemaTypes unsupportedTypes)}, which provider ${source} ${provider.version} does not have"
        )
        (check (filter (t: elem t allTypes) unsupportedTypes == [ ])
          "${quoteList (filter (t: elem t allTypes) unsupportedTypes)} ${
            if length (filter (t: elem t allTypes) unsupportedTypes) == 1 then "is" else "are"
          } both modelled and listed in `unsupported`"
        )
        (check (filter (t: unsupported.${t} == "") unsupportedTypes == [ ])
          "`unsupported` entries need a non-empty reason; ${
            quoteList (filter (t: unsupported.${t} == "") unsupportedTypes)
          } ${
            if length (filter (t: unsupported.${t} == "") unsupportedTypes) == 1 then "has" else "have"
          } none"
        )
      ];

      checks = globalChecks ++ lib.concatLists (mapAttrsToList (_: r: r.checks) built);
    in
    {
      # forcing the surface forces every assertion: a pairing cannot use the
      # generated options without also having checked them for drift.
      resourceTypes = builtins.deepSeq checks (lib.mapAttrs (_: r: r.spec) built);
      inherit checks;

      coverage = builtins.deepSeq checks {
        inherit
          source
          runtimePrefix
          unsupported
          omitEverywhere
          ;
        inherit (provider) version;
        schemaResources = length schemaTypes;
        collections = lib.mapAttrs (_: r: r.coverage) built;
      };
    };
}
