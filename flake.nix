{
  description = "declarative-runtime: declarative NixOS service runtime config via paired OpenTofu providers";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    treefmt-nix.url = "github:numtide/treefmt-nix";
    treefmt-nix.inputs.nixpkgs.follows = "nixpkgs";
  };

  outputs =
    {
      self,
      nixpkgs,
      treefmt-nix,
    }:
    let
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
      treefmtEval = forAllSystems ({ pkgs, ... }: treefmt-nix.lib.evalModule pkgs ./treefmt.nix);
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
        // {
          formatting = treefmtEval.${system}.config.build.check self;
        }
      );

      formatter = forAllSystems ({ system, ... }: treefmtEval.${system}.config.build.wrapper);
    };
}
