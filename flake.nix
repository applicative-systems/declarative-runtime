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
        forgejo = import ./services/forgejo/lib.nix {
          inherit pkgs;
          nixTfSchema = inputs.nix-tf-schema;
        };
        keycloak = import ./services/keycloak/lib.nix {
          inherit pkgs;
          nixTfSchema = inputs.nix-tf-schema;
        };
      };

      # A NixOS module cannot reach a flake input by path, so the schema library
      # a pairing derives its resource surface from is threaded in as a module
      # argument. Wrapping the exported modules keeps that plumbing invisible to
      # anyone importing them.
      withSchemaLib = module: {
        imports = [ module ];
        _module.args.nixTfSchema = inputs.nix-tf-schema;
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

      # `<svc>-rendered-fixtures`: each pairing's fixtures rendered through the
      # real option system and renderer. Build before and after a change to the
      # resource surface and diff -- an empty diff proves the wire format is
      # untouched. The `baseUrl` here only has to be stable across the two
      # builds; the module's own default is what a real system uses.
      renderedFixtures =
        pkgs:
        let
          libs = pairingLibs pkgs;
          inherit (import ./modules/lib/render-fixtures.nix { inherit pkgs; }) renderFixtures;
          urlOption = default: lib.mkOption { inherit default; };
        in
        {
          forgejo-rendered-fixtures = renderFixtures {
            name = "forgejo";
            options = libs.forgejo.resourceOptions // {
              baseUrl = urlOption "http://localhost:3000";
            };
            tfConfig = libs.forgejo.forgejoTfConfig;
            fixtures = import ./services/forgejo/fixtures.nix;
          };

          keycloak-rendered-fixtures = renderFixtures {
            name = "keycloak";
            options = libs.keycloak.resourceOptions // {
              baseUrl = urlOption "http://localhost:8080";
              adminRealm = urlOption "master";
            };
            tfConfig = libs.keycloak.keycloakTfConfig;
            fixtures = import ./services/keycloak/fixtures.nix;
          };
        };

      # `<svc>-schema-coverage`: the pairing's coverage table. Building it forces
      # the generator's drift assertions on their own, so schema drift fails a
      # check that names it rather than whichever VM test happens to eval first.
      #
      # A pairing opts in by exporting `coverage`, i.e. by deriving its resource
      # surface from the vendored schema.
      schemaCoverage =
        pkgs:
        let
          inherit (import ./modules/lib/schema-report.nix { inherit pkgs; }) mkCoverageReport;
        in
        lib.mapAttrs' (
          svc: l:
          lib.nameValuePair "${svc}-schema-coverage" (mkCoverageReport {
            name = svc;
            inherit (l) coverage;
          })
        ) (lib.filterAttrs (_: l: l ? coverage) (pairingLibs pkgs));

      # `<svc>-options-doc`: the pairing's user-facing option surface as
      # `options.json`. Build it before and after a change and diff the two --
      # that is the record of what the API gained, lost or retyped, which
      # rendered `.tf.json` alone cannot show (an option nobody sets renders to
      # nothing either way).
      optionsDocs =
        pkgs:
        lib.mapAttrs' (
          svc: l:
          lib.nameValuePair "${svc}-options-doc"
            (pkgs.nixosOptionsDoc {
              inherit
                (
                  (lib.evalModules {
                    modules = [ { options.services.${svc}.runtime = l.resourceOptions; } ];
                  })
                )
                options
                ;
              warningsAreErrors = true;
            }).optionsJSON
        ) (pairingLibs pkgs);

      # `<svc>-schema-current`: the authoritative drift check. The eval-time
      # assertions in `modules/lib/tf-schema.nix` compare version strings; this
      # one compares content, so a provider that changes a schema without
      # changing its version still fails CI.
      #
      # A pairing opts in by vendoring the file; once its `lib.nix` derives the
      # resource surface from `schema.nix` the file is load-bearing and cannot
      # quietly disappear again.
      schemaChecks =
        pkgs:
        lib.mapAttrs'
          (
            name: fresh:
            let
              svc = lib.removeSuffix "-provider-schema" name;
            in
            lib.nameValuePair "${svc}-schema-current" (
              pkgs.runCommand "${svc}-schema-current" { nativeBuildInputs = [ pkgs.diffutils ]; } ''
                if ! diff -u ${./services}/${svc}/provider-schema.json ${fresh}; then
                  echo >&2
                  echo "services/${svc}/provider-schema.json is stale; run 'nix run .#update-provider-schemas'" >&2
                  exit 1
                fi
                touch "$out"
              ''
            )
          )
          (
            lib.filterAttrs (
              name: _:
              lib.pathExists (./services + "/${lib.removeSuffix "-provider-schema" name}/provider-schema.json")
            ) (providerSchemas pkgs)
          );
    in
    {
      # NixOS module entrypoint: enables a Nixpkgs service and reconciles its
      # runtime state via OpenTofu after the primary unit starts.
      nixosModules.default = withSchemaLib ./modules;
      nixosModules.forgejo = withSchemaLib ./services/forgejo/module.nix;
      nixosModules.keycloak = withSchemaLib ./services/keycloak/module.nix;

      nixosConfigurations = lib.mapAttrs' (
        name: cfg: lib.nameValuePair "example-${name}" (exampleSystem "x86_64-linux" cfg)
      ) examples;

      packages = lib.mapAttrs (
        system: pkgs:
        lib.mapAttrs (_name: cfg: (exampleSystem system cfg).config.system.build.vm) examples
        // providerSchemas pkgs
        // renderedFixtures pkgs
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
        // schemaChecks pkgs
        // schemaCoverage pkgs
        // optionsDocs pkgs
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
