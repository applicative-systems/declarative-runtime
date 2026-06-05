{
  description = "Declarative NixOS service configuration via paired Terraform providers";

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
    in
    {
      # NixOS module entrypoint: enables a Nixpkgs service and reconciles its
      # runtime state via OpenTofu after the primary unit starts.
      nixosModules.default = ./modules;
      nixosModules.forgejo = ./services/forgejo/module.nix;

      checks = forAllSystems (
        { pkgs, system }:
        # Per-service checks (one attrset per pairing under ./services/<svc>).
        (import ./services/forgejo/checks.nix { inherit pkgs self; })
        // {
          formatting = treefmtEval.${system}.config.build.check self;
        }
      );

      formatter = forAllSystems ({ system, ... }: treefmtEval.${system}.config.build.wrapper);
    };
}
