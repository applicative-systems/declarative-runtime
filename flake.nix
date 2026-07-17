{
  description = "declarative-runtime: declarative NixOS service runtime config via paired OpenTofu providers";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  # Proxmox VE itself is not in Nixpkgs; the `proxmox-vm` example runs it via
  # this out-of-tree flake. Per upstream guidance its `nixpkgs-stable` input is
  # left as-is (only its own tested revision is supported).
  inputs.proxmox-nixos.url = "github:SaumonNet/proxmox-nixos";

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

      # The proxmox-vm example additionally needs the proxmox-nixos module +
      # overlay, and is x86_64-only (proxmox-nixos supports no other system), so
      # it is built here rather than through the generic `examples` map above.
      proxmoxExample = lib.nixosSystem {
        system = "x86_64-linux";
        modules = [
          inputs.self.nixosModules.default
          inputs.proxmox-nixos.nixosModules.proxmox-ve
          { nixpkgs.overlays = [ inputs.proxmox-nixos.overlays.x86_64-linux ]; }
          ./examples/proxmox-vm/configuration.nix
        ];
      };
    in
    {
      # NixOS module entrypoint: enables a Nixpkgs service and reconciles its
      # runtime state via OpenTofu after the primary unit starts.
      nixosModules.default = ./modules;
      nixosModules.forgejo = ./services/forgejo/module.nix;
      nixosModules.keycloak = ./services/keycloak/module.nix;
      nixosModules.hetzner-dns = ./services/hetzner-dns/module.nix;
      nixosModules.jellyfin = ./services/jellyfin/module.nix;
      nixosModules.proxmox-ve = ./services/proxmox-ve/module.nix;

      nixosConfigurations =
        lib.mapAttrs' (
          name: cfg: lib.nameValuePair "example-${name}" (exampleSystem "x86_64-linux" cfg)
        ) examples
        // {
          example-proxmox-vm = proxmoxExample;
        };

      packages =
        lib.recursiveUpdate
          (lib.mapAttrs (
            system: _pkgs: lib.mapAttrs (_name: cfg: (exampleSystem system cfg).config.system.build.vm) examples
          ) inputs.nixpkgs.legacyPackages)
          {
            x86_64-linux.proxmox-vm = proxmoxExample.config.system.build.vm;
          };

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
        // (import ./services/hetzner-dns/checks.nix {
          inherit pkgs;
          inherit (inputs) self;
        })
        // (import ./services/jellyfin/checks.nix {
          inherit pkgs;
          inherit (inputs) self;
        })
        // (import ./services/proxmox-ve/checks.nix {
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
