# The vendored svalabs/forgejo provider schema, parsed.
#
# Indirection, not decoration: Nix memoizes `import <path>` but not
# `builtins.readFile`, and `lib.nix` is instantiated once per system per check.
# Refresh with `nix run .#update-provider-schemas`.
builtins.fromJSON (builtins.readFile ./provider-schema.json)
