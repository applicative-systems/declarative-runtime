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

      # the pairings, by service name. each `lib.nix` exposes the packaged
      # provider and its source address, which is all the schema tooling needs.
      pairingLibs = pkgs: {
        forgejo = import ./services/forgejo/lib.nix { inherit pkgs; };
        keycloak = import ./services/keycloak/lib.nix { inherit pkgs; };
      };

      # `<svc>-provider-schema`: the normalized schema of the pinned provider,
      # extracted in a sandbox (`tofu providers schema -json`). This is the
      # source for the vendored `services/<svc>/provider-schema.json`; it is
      # never imported at eval time, because the flake evaluates for aarch64 too
      # and IFD would mean running a foreign-arch provider binary.
      providerSchemas =
        pkgs:
        let
          conv = pkgs.callPackage "${inputs.nix-tf-schema}/conversion.nix" { };
        in
        lib.mapAttrs' (
          svc: l:
          lib.nameValuePair "${svc}-provider-schema" (
            conv.mkProviderSchemaFile {
              inherit (l) provider;
              source = l.providerSource;
            }
          )
        ) (pairingLibs pkgs);
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
        system: pkgs:
        lib.mapAttrs (_name: cfg: (exampleSystem system cfg).config.system.build.vm) examples
        // providerSchemas pkgs
      ) inputs.nixpkgs.legacyPackages;

      # `nix run .#update-provider-schemas` after a nixpkgs bump moves a
      # provider: refresh the vendored schemas, then `nix flake check` reports
      # every resource and attribute that changed.
      apps = lib.mapAttrs (_system: pkgs: {
        update-provider-schemas = {
          type = "app";
          program = lib.getExe (
            pkgs.writeShellApplication {
              name = "update-provider-schemas";
              runtimeInputs = [ pkgs.git ];
              text = ''
                root=$(git rev-parse --show-toplevel)
                ${lib.concatLines (
                  lib.mapAttrsToList (name: drv: ''
                    install -Dm0644 ${drv} "$root/services/${lib.removeSuffix "-provider-schema" name}/provider-schema.json"
                    echo "updated services/${lib.removeSuffix "-provider-schema" name}/provider-schema.json"
                  '') (providerSchemas pkgs)
                )}
              '';
            }
          );
        };
      }) inputs.nixpkgs.legacyPackages;

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
