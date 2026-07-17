# Proxmox VE <-> bpg/proxmox pairing.
#
# Proxmox VE itself is not in Nixpkgs; the "upstream" service unit is the one
# from SaumonNet/proxmox-nixos (`services.proxmox-ve.enable`, whose API is
# served by pveproxy.service on :8006). This module layers a run-once reconciler
# that applies declarative runtime state (VMs, images, pools, users, roles,
# ACLs, ...) against that API via OpenTofu and the bpg/proxmox provider.
#
# The reconciler is endpoint-driven: it targets `endpoint` (a local Proxmox VE
# host by default, but equally a remote one), so it does not hard-depend on the
# proxmox-ve module being present — it only *orders after* pveproxy.service when
# that unit exists. Proxmox serves a self-signed certificate over HTTPS and its
# root credential is set by the OS, so authentication cannot be self-bootstrapped
# (unlike Jellyfin): an API token or the root password must be provided.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  inherit (lib)
    mkEnableOption
    mkIf
    mkOption
    types
    ;

  cfg = config.services.proxmox-ve.runtime;
  tflib = import ./lib.nix { inherit pkgs; };

  serviceUser = "declarative-proxmox-ve";
  stateDir = "/var/lib/declarative-proxmox-ve";

  useApiToken = cfg.apiTokenFile != null;
  # The single sensitive credential the reconciler loads: an API token, or the
  # `username` account's password, depending on the auth mode.
  effectiveTokenFile = if useApiToken then cfg.apiTokenFile else cfg.passwordFile;

  tf = tflib.proxmoxTfConfig cfg;
in
{
  options.services.proxmox-ve.runtime = {
    enable = mkEnableOption (
      "declarative Proxmox VE configuration, applied via OpenTofu and the "
      + "bpg/proxmox provider against the Proxmox VE API after pveproxy.service starts"
    );

    endpoint = mkOption {
      type = types.str;
      default = "https://localhost:8006/";
      description = ''
        Base URL of the Proxmox VE API the provider targets. Defaults to the
        local node; point it at another host to manage a remote Proxmox VE.
      '';
    };

    insecure = mkOption {
      type = types.bool;
      default = true;
      description = ''
        Whether to skip TLS certificate verification. Proxmox VE ships a
        self-signed certificate by default, so this defaults to `true`; set it
        to `false` once the endpoint presents a trusted certificate.
      '';
    };

    apiTokenFile = mkOption {
      type = types.nullOr types.str;
      default = null;
      example = "/run/secrets/proxmox-api-token";
      description = ''
        Runtime path to a file containing a Proxmox VE API token in the form
        `user@realm!tokenid=uuid`.

        This is a path resolved on the target host (e.g. provisioned by
        sops-nix or agenix), NOT a store path: it is handed to the reconciler
        via systemd `LoadCredential=` and never copied into the Nix store.

        When set, the provider authenticates with this token and `username` /
        `passwordFile` are unused. Note that a handful of privileged operations
        (e.g. `root`-only VM options, privileged containers) are rejected for
        token auth by Proxmox — use password auth for those.
      '';
    };

    username = mkOption {
      type = types.str;
      default = "root@pam";
      description = ''
        Account the provider authenticates as when `apiTokenFile` is unset.
        Also used as the SSH user's fallback password source. Unused when
        `apiTokenFile` is set.
      '';
    };

    passwordFile = mkOption {
      type = types.nullOr types.str;
      default = null;
      example = "/run/secrets/proxmox-root-password";
      description = ''
        Runtime path to a file containing the `username` account's password,
        read via systemd `LoadCredential=` and never copied into the Nix store.

        Required when `apiTokenFile` is unset. When an `ssh` block is configured
        without its own credentials, the provider reuses this password for SSH.
      '';
    };

    ssh = mkOption {
      default = null;
      description = ''
        Optional SSH access for the provider. Most resources work through the
        API alone; SSH is only needed to upload snippets, import a disk from a
        local `source_file.path`, or configure container `idmap` entries. Leave
        null unless you use those.
      '';
      type = types.nullOr (
        types.submodule {
          options = {
            username = mkOption {
              type = types.str;
              default = "root";
              description = "SSH user on the Proxmox node.";
            };
            agent = mkOption {
              type = types.bool;
              default = false;
              description = "Whether to authenticate SSH via an ssh-agent (see `agentSocket`).";
            };
            agentSocket = mkOption {
              type = types.nullOr types.str;
              default = null;
              description = "Path to the ssh-agent socket. Defaults to `$SSH_AUTH_SOCK` when null.";
            };
          };
        }
      );
    };
  }
  // tflib.resourceOptions;

  config = mkIf cfg.enable {
    assertions = [
      {
        assertion = cfg.apiTokenFile != null || cfg.passwordFile != null;
        message = "services.proxmox-ve.runtime: set either apiTokenFile or passwordFile — the Proxmox API credential cannot be self-bootstrapped.";
      }
      {
        assertion = !(cfg.apiTokenFile != null && cfg.passwordFile != null);
        message = "services.proxmox-ve.runtime: set either apiTokenFile or passwordFile, not both.";
      }
    ];

    users.users.${serviceUser} = {
      isSystemUser = true;
      group = serviceUser;
      home = stateDir;
      description = "declarative Proxmox VE reconciler";
    };
    users.groups.${serviceUser} = { };
    systemd.tmpfiles.rules = [ "d ${stateDir} 0700 ${serviceUser} ${serviceUser} -" ];

    systemd.services.declarative-proxmox-ve =
      tflib.mkReconcileService {
        name = "declarative-proxmox-ve";
        tfConfig = tf.config;
        inherit (tf) credentials;
        # Ordered (softly) after the upstream unit below rather than requiring
        # it, so the reconciler also works against a remote endpoint and is
        # testable without a full Proxmox VE node.
        afterUnits = [ ];
        # No health probe: Proxmox serves self-signed HTTPS (the shared curl
        # probe does not skip TLS verification). The apply itself is retried
        # until the API answers.
        healthUrl = null;
        applyRetries = 30;
        applyRetryDelay = 10;
        tokenFile = effectiveTokenFile;
        user = serviceUser;
        group = serviceUser;
        inherit stateDir;
      }
      // {
        # Order after the Proxmox API when it is a local node, and after the
        # network for a remote endpoint. Soft (`wants`, not `requires`) so a
        # missing pveproxy.service (remote endpoint / test double) is not fatal.
        after = [
          "pveproxy.service"
          "network-online.target"
        ];
        wants = [
          "pveproxy.service"
          "network-online.target"
        ];
      };
  };
}
