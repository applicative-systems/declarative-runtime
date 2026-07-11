{
  description = "declarative-runtime: declarative NixOS service runtime config via paired OpenTofu providers";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  outputs =
    {
      self,
      nixpkgs,
    }:
    let
      inherit (nixpkgs) lib;
      systems = [
        "x86_64-linux"
        "aarch64-linux"
      ];
      forAllSystems =
        f:
        nixpkgs.lib.genAttrs systems (
          system:
          f {
            inherit system;
            pkgs = nixpkgs.legacyPackages.${system};
          }
        );
      # runnable examples (see ./examples/<name>/README.md). each `name`
      # surfaces as `nix run .#<name>` (the qemu vm) and as an eval-only
      # check, so option-name drift fails CI without paying for a full vm test.
      examples = {
        keycloak-forgejo = ./examples/keycloak-forgejo/configuration.nix;
      };
      exampleSystem =
        system: cfg:
        nixpkgs.lib.nixosSystem {
          inherit system;
          modules = [
            self.nixosModules.default
            cfg
          ];
        };
    in
    {
      # NixOS module entrypoint: enables a Nixpkgs service and reconciles its
      # runtime state via OpenTofu after the primary unit starts.
      nixosModules.default = ./modules;
      nixosModules.forgejo = ./services/forgejo/module.nix;
      nixosModules.keycloak = ./services/keycloak/module.nix;

      nixosConfigurations = nixpkgs.lib.mapAttrs' (
        name: cfg: nixpkgs.lib.nameValuePair "example-${name}" (exampleSystem "x86_64-linux" cfg)
      ) examples;

      packages = forAllSystems (
        { system, ... }:
        nixpkgs.lib.mapAttrs (name: cfg: (exampleSystem system cfg).config.system.build.vm) examples
      );

      checks = forAllSystems (
        { pkgs, system }:
        # Per-service checks (one attrset per pairing under ./services/<svc>).
        (import ./services/forgejo/checks.nix { inherit pkgs self; })
        // (import ./services/keycloak/checks.nix { inherit pkgs self; })
        // (nixpkgs.lib.mapAttrs' (
          name: cfg:
          nixpkgs.lib.nameValuePair "example-${name}" (exampleSystem system cfg).config.system.build.toplevel
        ) examples)
      );

      formatter = builtins.mapAttrs (
        _: pkgs:
        pkgs.treefmt.withConfig {
          settings = {
            tree-root-file = "flake.nix";
            on-unmatched = "info";
            formatter = {
              nixfmt = {
                command = lib.getExe pkgs.nixfmt;
                includes = [ "*.nix" ];
              };
              statix = {
                command = lib.getExe pkgs.statix;
                options = [ "fix" ];
                no-positional-arg-support = true;
                includes = [ "*.nix" ];
              };
              deadnix = {
                command = lib.getExe pkgs.deadnix;
                options = [ "--edit" ];
                includes = [ "*.nix" ];
              };
              prettier = {
                command = lib.getExe pkgs.prettier;
                options = [ "--write" ];
                includes = [ "*.md" ];
              };
            };
          };
        }
      ) nixpkgs.legacyPackages;
    };
}
