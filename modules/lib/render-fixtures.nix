# Render a pairing's fixtures through the real option system and renderer, as a
# build artifact.
#
# why: once the option surface is generated from a provider schema, "did this
# change what we send the provider?" can only be answered against rendered
# `.tf.json` -- option definitions alone say nothing about defaults, coercions,
# secret substitution, block wrapping or reference resolution. Build
# `<svc>-rendered-fixtures` before and after a change and diff the two; an empty
# diff is proof the wire format is untouched.
#
# The artifact carries no secrets: `<attr>File` inputs are host paths, and the
# renderer has already replaced their values with `${var.<id>}` references.
{ pkgs }:
let
  inherit (pkgs) lib;
in
{
  # name      pairing name, used for the output file
  # options   the option set a fixture is evaluated against (the pairing's
  #           `resourceOptions` plus whatever its provider block reads)
  # tfConfig  the pairing's `<svc>TfConfig`: cfg -> { config; credentials; }
  # fixtures  fixture name -> a `services.<svc>.runtime` config fragment
  renderFixtures =
    {
      name,
      options,
      tfConfig,
      fixtures,
    }:
    pkgs.writeText "${name}-rendered-fixtures.json" (
      builtins.toJSON (
        lib.mapAttrs (
          _: fixture:
          tfConfig
            (lib.evalModules {
              modules = [
                { inherit options; }
                fixture
              ];
            }).config
        ) fixtures
      )
    );
}
