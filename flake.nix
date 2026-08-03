{
  description = "declarative-runtime: declarative NixOS service runtime config via paired OpenTofu providers";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  # Generic Terraform-schema <-> Nix conversion helpers, used to derive each
  # pairing's resource surface from its vendored provider schema.
  #
  # Pulled in source-only (`flake = false`): its own flake builds `lib` from
  # *its* nixpkgs pin for x86_64 alone, and we evaluate for aarch64 too. We
  # instantiate `conversion.nix` against our own `pkgs` instead, so there is one
  # nixpkgs in play and both systems work.
  inputs.nix-tf-schema = {
    url = "git+https://git.fediversity.eu/fediversity/nix-tf-schema";
    flake = false;
  };

  outputs =
    inputs:
    let
      inherit (inputs.nixpkgs) lib;
      # runnable examples (see ./examples/<name>/README.md). each `name`
      # surfaces as `nix run .#<name>` (the qemu vm) and as an eval-only
      # check, so option-name drift fails CI without paying for a full vm test.
      examples = {
        keycloak-forgejo = ./examples/keycloak-forgejo/configuration.nix;
      };
      exampleSystem =
        system: cfg:
        lib.nixosSystem {
          inherit system;
          modules = [
            inputs.self.nixosModules.default
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

      nixosConfigurations = lib.mapAttrs' (
        name: cfg: lib.nameValuePair "example-${name}" (exampleSystem "x86_64-linux" cfg)
      ) examples;

      packages = lib.mapAttrs (
        system: _pkgs: lib.mapAttrs (_name: cfg: (exampleSystem system cfg).config.system.build.vm) examples
      ) inputs.nixpkgs.legacyPackages;

      checks = lib.mapAttrs (
        system: pkgs:
        import ./services/forgejo/checks.nix {
          inherit pkgs;
          inherit (inputs) self;
        }
        // (import ./services/keycloak/checks.nix {
          inherit pkgs;
          inherit (inputs) self;
        })
        // (lib.mapAttrs' (
          name: cfg:
          lib.nameValuePair "example-${name}" (exampleSystem system cfg).config.system.build.toplevel
        ) examples)
        // {
          formatting = inputs.self.formatter.${system}.check inputs.self;
        }
      ) inputs.nixpkgs.legacyPackages;

      formatter = lib.mapAttrs (
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
      ) inputs.nixpkgs.legacyPackages;
    };
}
