# Garage <-> arsolitt/garagehq pairing.
#
# Enables the upstream `services.garage` module unchanged, and adds a run-once
# reconciler that applies declarative runtime state (buckets, access keys and
# the grants between them) against Garage's v2 admin API once `garage.service`
# is up.
#
# Garage stores no bucket or key until its cluster layout gives a node a role,
# and an admin token minted at runtime is stored in the cluster too. So the
# module bootstraps in this order, before the reconciler:
#
# 1. `declarative-garage-layout` (when `layout` is set) gives this node and its
#    `peers` their roles and applies the layout. One node applies the layout:
#    two nodes that apply the same version with different roles break the
#    cluster.
# 2. `declarative-garage-token` (when `tokenFile` is null) replaces the
#    reconciler's admin token with a new one, scoped to the functions the
#    provider calls. Garage keeps the token in the cluster, and the unit keeps
#    it in its runtime directory only, so it is never on disk.
#
# Both units use `garage json-api`, which calls the admin API through Garage's
# RPC as root, so they need no admin token of their own.
#
# `nix-tf-schema` is the schema-conversion library the resource surface is derived
# from; the flake injects it via `_module.args`, since a NixOS module cannot
# reach a flake input by path.
{
  config,
  lib,
  pkgs,
  nix-tf-schema,
  ...
}:
let
  inherit (lib)
    literalExpression
    mkEnableOption
    mkIf
    mkOption
    types
    ;

  cfg = config.services.garage.runtime;
  garage = config.services.garage;
  tflib = import ./lib.nix { inherit pkgs nix-tf-schema; };

  # `api_bind_addr` is `<host>:<port>` (the host possibly a bracketed IPv6
  # address); the port is what follows the last colon.
  adminBind = garage.settings.admin.api_bind_addr or null;
  defaultBaseUrl =
    if adminBind == null then null else "http://localhost:${lib.last (lib.splitString ":" adminBind)}";

  tf = tflib.garageTfConfig cfg;

  layoutUnit = "declarative-garage-layout";
  tokenUnit = "declarative-garage-token";
  bootstrapToken = cfg.tokenFile == null;
  tokenFile = if bootstrapToken then "/run/${tokenUnit}/token" else cfg.tokenFile;

  # Run a command until it succeeds, for two minutes at most (the budget of the
  # reconciler's health wait). A oneshot has no start timeout of its own.
  retry = ''
    retry() {
      for _ in $(seq 60); do
        if "$@"; then return 0; fi
        sleep 2
      done
      echo "$*: no success after two minutes" >&2
      return 1
    }
  '';

  # A role in the cluster layout, for this node and for its peers.
  roleOptions = {
    zone = mkOption {
      type = types.str;
      example = "dc1";
      description = "Zone of the node.";
    };
    capacity = mkOption {
      type = types.ints.positive;
      example = literalExpression "100 * 1000 * 1000 * 1000";
      description = "Storage capacity of the node, in bytes.";
    };
    tags = mkOption {
      type = types.listOf types.str;
      default = [ ];
      description = "Tags of the node.";
    };
  };

  bootstrapUnit = {
    after = [ "garage.service" ];
    requires = [ "garage.service" ];
    path = [
      garage.package
      pkgs.jq
    ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
    };
  };
in
{
  options.services.garage.runtime = {
    enable = mkEnableOption (
      "declarative Garage configuration, applied via OpenTofu and the garage "
      + "provider after garage.service starts"
    );

    baseUrl = mkOption {
      type = types.nullOr types.str;
      default = defaultBaseUrl;
      defaultText = literalExpression ''"http://localhost:<port of services.garage.settings.admin.api_bind_addr>"'';
      description = "Base URL of the local Garage admin API the provider targets.";
    };

    tokenFile = mkOption {
      type = types.nullOr types.str;
      default = garage.settings.admin.admin_token_file or null;
      defaultText = literalExpression "config.services.garage.settings.admin.admin_token_file";
      example = "/run/secrets/garage-admin-token";
      description = ''
        Runtime path to a file containing a Garage admin API token.

        This is a path resolved on the target host (e.g. provisioned by
        sops-nix or agenix), NOT a store path: it is handed to the reconciler
        via systemd `LoadCredential=` and never copied into the Nix store.

        Defaults to the file Garage itself reads its admin token from. When
        `null`, the `declarative-garage-token` unit mints a token each time it
        starts, scoped to the admin API functions the provider calls, and
        deletes the token it minted before.
      '';
    };

    layout = mkOption {
      type = types.nullOr (
        types.submodule {
          options = roleOptions // {
            peers = mkOption {
              type = types.listOf (
                types.submodule {
                  options = roleOptions // {
                    id = mkOption {
                      type = types.strMatching "[0-9a-f]{64}";
                      description = "Node id, which is the part of `garage node id` before the `@`.";
                    };
                  };
                }
              );
              default = [ ];
              description = ''
                Roles of the other nodes of the cluster. This node assigns
                them, so the other nodes need no `services.garage.runtime`.
                This node must reach them, for example through
                `services.garage.settings.bootstrap_peers`.
              '';
            };
          };
        }
      );
      default = null;
      example = {
        zone = "dc1";
        capacity = 1000 * 1000 * 1000;
      };
      description = ''
        Role of this node in the cluster layout. When set, the
        `declarative-garage-layout` unit gives this node this role and each of
        `peers` its role, and applies the layout, before the reconciler runs.
        It does nothing when all of these nodes already have these roles, and
        it does not remove a node from the layout.

        Set this on one node of a cluster only.

        When `null`, the operator makes the layout. Garage stores no bucket or
        key, and mints no admin token, until the layout gives a node a role.
      '';
    };
  }
  // tflib.resourceOptions;

  config = mkIf cfg.enable {
    assertions = [
      {
        assertion = garage.enable;
        message = "services.garage.runtime requires services.garage.enable = true.";
      }
      {
        # The provider speaks the v2 admin API, which Garage serves from 2.0.
        assertion = lib.versionAtLeast garage.package.version "2";
        message = "services.garage.runtime requires Garage 2.0 or later (services.garage.package = pkgs.garage_2).";
      }
      {
        assertion = cfg.baseUrl != null;
        message = "services.garage.runtime requires the admin API: set services.garage.settings.admin.api_bind_addr, or services.garage.runtime.baseUrl.";
      }
    ];

    systemd.services.${layoutUnit} = mkIf (cfg.layout != null) (
      bootstrapUnit
      // {
        description = "Give the nodes their roles in the Garage cluster layout";
        script = ''
          ${retry}
          retry garage json-api GetClusterLayout > /dev/null
          node=$(garage node id -q)
          roles=$(jq -n --arg id "''${node%%@*}" \
            --argjson layout ${lib.escapeShellArg (builtins.toJSON cfg.layout)} \
            '[ ($layout | del(.peers)) + { id: $id } ] + $layout.peers')
          layout=$(garage json-api GetClusterLayout)
          # A current role also carries computed fields, so compare only the
          # fields this unit sets.
          changes=$(jq --argjson roles "$roles" '
            .roles as $current
            | [ $roles[]
                | . as $role
                | select($current | any(with_entries(select(.key | IN($role | keys[]))) == $role) | not) ]
          ' <<< "$layout")
          if [ "$(jq length <<< "$changes")" = 0 ]; then
            echo "the nodes have their roles in layout version $(jq .version <<< "$layout")"
            exit 0
          fi
          garage json-api UpdateClusterLayout \
            "$(jq -n --argjson roles "$changes" '{ roles: $roles }')" > /dev/null
          garage json-api ApplyClusterLayout \
            "$(jq '{ version: (.version + 1) }' <<< "$layout")" | jq -r '.message[]'
        '';
      }
    );

    systemd.services.${tokenUnit} = mkIf bootstrapToken (
      bootstrapUnit
      // {
        description = "Mint the admin token of the Garage reconciler";
        after = bootstrapUnit.after ++ lib.optional (cfg.layout != null) "${layoutUnit}.service";
        serviceConfig = bootstrapUnit.serviceConfig // {
          RuntimeDirectory = tokenUnit;
          RuntimeDirectoryMode = "0700";
          UMask = "0077";
        };
        script = ''
          ${retry}
          has_quorum() {
            garage json-api GetClusterHealth | jq -e '.status != "unavailable"' > /dev/null
          }
          # Garage stores the token in the cluster, which needs a layout and a
          # quorum of nodes. A cluster with a node down still has a quorum.
          retry has_quorum
          garage json-api ListAdminTokens \
            | jq -c '.[] | select(.name == "${tokenUnit}" and .id != null) | { id }' \
            | while read -r id; do garage json-api DeleteAdminToken "$id" > /dev/null; done
          garage json-api CreateAdminToken ${
            lib.escapeShellArg (
              builtins.toJSON {
                name = tokenUnit;
                neverExpires = true;
                scope = tflib.adminScope;
              }
            )
          } | jq -r .secretToken > "$RUNTIME_DIRECTORY/token"
        '';
      }
    );

    systemd.services.declarative-garage = tflib.mkReconcileService {
      name = "declarative-garage";
      tfConfig = tf.config;
      inherit (tf) credentials;
      afterUnits = [
        "garage.service"
      ]
      ++ lib.optional (cfg.layout != null) "${layoutUnit}.service"
      ++ lib.optional bootstrapToken "${tokenUnit}.service";
      # 200 only once the cluster has a layout, which no bucket or key can be
      # made without.
      healthUrl = "${cfg.baseUrl}/health";
      inherit tokenFile;
      # The reconciler only uses the admin API, so it runs as a dynamic user of
      # its own. Its state cannot go below `/var/lib/garage`: that is the
      # state directory of Garage's dynamic user, and systemd cannot make a
      # state directory of a different unit in it.
      user = "declarative-garage";
      group = "declarative-garage";
      dynamicUser = true;
      stateDir = "/var/lib/declarative-garage";
    };
  };
}
