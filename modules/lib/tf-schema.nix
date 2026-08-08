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
  nixTfSchema,
}:
let
  inherit (pkgs) lib;
  ty = lib.types;
  conv = pkgs.callPackage "${nixTfSchema}/conversion.nix" { };

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
in
{
  /*
    Build a pairing's `resourceTypes` (and its drift assertions) from a vendored
    provider schema plus a per-collection overlay.

      schema         parsed `provider-schema.json` (normalized: `format_version`,
                     `source`, `version`, `resource_schemas`)
      provider       the packaged provider derivation; its `version` must match
                     the vendored schema
      source         provider source address, e.g. "svalabs/forgejo"
      runtimePrefix  "services.<svc>.runtime" -- for error messages
      resources      collection name -> overlay (see below)
      unsupported    schema resource type -> non-empty reason for not modelling it
      omitEverywhere dotted paths dropped from every collection that declares
                     them. For dialect artifacts that repeat across the whole
                     provider -- the sdk/v2 synthetic `id`, say -- not as a
                     shortcut for per-collection `omit`.

    An overlay's first six fields are mandatory; the rest default to empty and
    exist only to correct things a schema cannot state. There is deliberately no
    way to declare an option with no schema counterpart -- `refs` is the sole
    exception, and that is what makes the drift check total.

      type           schema key; must exist and be claimed exactly once
      prefix         unique Terraform label prefix
      nameAttr       attribute defaulted from the collection key, or null
      scope          provider token scope(s) the resource needs, or null
      refs           parent links (shape unchanged; see ./default.nix)
      description    the collection's NixOS option description

      oneOfRefs      ExactlyOneOf ref groups (a Go validator, absent from schemas)
      omit           dotted paths to drop entirely
      extraSecrets   paths to treat as secret although not marked `sensitive`
      notSecrets     `sensitive` paths not to treat as secret
      forceOptional  paths required upstream but nullable here
      requiredAttrs  extra non-empty checks
      extraAttrs     last-resort typed overrides; keys must name real attributes

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

      withDefaults =
        o:
        {
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
        collection: rawOverlay:
        let
          o = withDefaults rawOverlay;
          ctx = "${runtimePrefix}.${collection}";
          # the type check has to come first: everything below indexes the
          # schema by it.
          resourceSchema =
            schema.resource_schemas.${o.type}
              or (throw "${runtimePrefix}: collection '${collection}' models resource `${o.type}`, which provider ${source} ${provider.version} does not have");

          # top-level nodes, and every node by dotted path.
          tree = conv.settableTree resourceSchema;
          paths = conv.settablePaths resourceSchema;

          # attributes the reference inputs occupy: the user names a sibling
          # collection key and generation fills these in, so they must not also
          # be settable options.
          refConsumed = mapAttrsToList (_: r: r.attr) o.refs;
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

          isNameAttr = path: o.nameAttr != null && path == o.nameAttr;

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
            (namesPaths "`refs.*.attr`" refConsumed (attrNames tree))
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
            (check
              (
                o.nameAttr == null
                || (
                  tree ? ${o.nameAttr}
                  && tree.${o.nameAttr}.kind == "attr"
                  && flatten tree.${o.nameAttr}.tfType == [ "string" ]
                )
              )
              "${ctx}: `nameAttr` must name a settable top-level string attribute; `${toString o.nameAttr}` is not one"
            )
          ]
          ++ mapAttrsToList (
            refName: refSpec:
            check (lib.all (t: resources ? ${t.collection}) refSpec.targets)
              "${ctx}: ref `${refName}` targets ${
                quoteList (filter (c: !(resources ? ${c})) (map (t: t.collection) refSpec.targets))
              }, which ${runtimePrefix} does not define"
          ) o.refs
          ++ map (
            group:
            check (lib.all (r: o.refs ? ${r}) group)
              "${ctx}: `oneOfRefs` names ${
                quoteList (filter (r: !(o.refs ? ${r})) group)
              }, which ${ctx} does not declare as refs"
          ) o.oneOfRefs;

          spec = {
            inherit (o)
              type
              prefix
              nameAttr
              scope
              refs
              description
              oneOfRefs
              ;
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
            inherit (o) type prefix description;
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

      built = lib.mapAttrs mkOne resources;

      # -----------------------------------------------------------------------
      # provider-wide assertions
      # -----------------------------------------------------------------------

      allTypes = mapAttrsToList (_: o: o.type) resources;
      allPrefixes = mapAttrsToList (_: o: o.prefix) resources;
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

        (check (
          duplicates allTypes == [ ]
        ) "resource ${quoteList (duplicates allTypes)} claimed by more than one collection")
        (check (
          duplicates allPrefixes == [ ]
        ) "label prefix ${quoteList (duplicates allPrefixes)} used by more than one collection")

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
