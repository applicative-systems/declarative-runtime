# Jellyfin <-> ThePhaseless/jellyfin pairing.
#
# Enables the upstream `services.jellyfin` module unchanged, and adds a run-once
# reconciler that applies declarative runtime state (users, libraries, plugins,
# server configuration, ...) against the live Jellyfin API once jellyfin.service
# is up.
#
# Authentication mirrors the provider's two modes:
#   * apiKeyFile set        -> the provider authenticates with that API key
#                              (for an already-configured instance).
#   * apiKeyFile unset       -> the provider authenticates with adminUsername +
#     (the default)            an admin password. On a *fresh* instance it uses
#                              them to create the initial admin and complete the
#                              startup wizard, so the pairing converges from a
#                              cold boot with zero manual setup. The password is
#                              either the operator's `adminPasswordFile`, or a
#                              random one minted once by a companion oneshot
#                              (declarative-jellyfin-password.service) and reused
#                              across reboots.
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

  cfg = config.services.jellyfin.runtime;
  jellyfin = config.services.jellyfin;
  tflib = import ./lib.nix { inherit pkgs; };

  defaultBaseUrl = "http://localhost:8096";

  # Companion oneshot that mints the reconciler's admin password. Only wired in
  # when the operator supplies neither an API key nor their own password file.
  passwordServiceName = "declarative-jellyfin-password";
  useApiKey = cfg.apiKeyFile != null;
  bootstrapPassword = !useApiKey && cfg.adminPasswordFile == null;
  effectivePasswordFile =
    if bootstrapPassword then
      "/var/lib/${passwordServiceName}/admin-password"
    else
      cfg.adminPasswordFile;
  # The single sensitive credential the reconciler loads: an API key, or the
  # admin password, depending on the auth mode.
  effectiveTokenFile = if useApiKey then cfg.apiKeyFile else effectivePasswordFile;

  tf = tflib.jellyfinTfConfig cfg;
in
{
  options.services.jellyfin.runtime = {
    enable = mkEnableOption (
      "declarative Jellyfin configuration, applied via OpenTofu and the "
      + "ThePhaseless/jellyfin provider after jellyfin.service starts"
    );

    baseUrl = mkOption {
      type = types.str;
      default = defaultBaseUrl;
      description = "Base URL of the local Jellyfin API the provider targets.";
    };

    apiKeyFile = mkOption {
      type = types.nullOr types.str;
      default = null;
      example = "/run/secrets/jellyfin-api-key";
      description = ''
        Runtime path to a file containing a Jellyfin API key with administrative
        privileges.

        This is a path resolved on the target host (e.g. provisioned by
        sops-nix or agenix), NOT a store path: it is handed to the reconciler
        via systemd `LoadCredential=` and never copied into the Nix store.

        When set, the provider authenticates with this API key and does not use
        username/password. An API key only exists once the Jellyfin startup
        wizard has been completed, so use this for an already-configured
        instance; leave it null to let the pairing bootstrap a fresh server.
      '';
    };

    adminUsername = mkOption {
      type = types.str;
      default = "admin";
      description = ''
        Administrator account the provider authenticates as when `apiKeyFile`
        is unset. On a fresh instance the provider creates this account and
        completes the startup wizard. Unused when `apiKeyFile` is set.
      '';
    };

    adminPasswordFile = mkOption {
      type = types.nullOr types.str;
      default = null;
      example = "/run/secrets/jellyfin-admin-password";
      description = ''
        Runtime path to a file containing the `adminUsername` password, read via
        systemd `LoadCredential=` and never copied into the Nix store.

        Used only when `apiKeyFile` is unset. When this is also null (the
        default), the pairing mints a random admin password once, persists it
        under /var/lib, and reuses it across reboots -- so the server bootstraps
        itself with no operator secret at all.
      '';
    };
  }
  // tflib.resourceOptions;

  config = mkIf cfg.enable {
    assertions = [
      {
        assertion = jellyfin.enable;
        message = "services.jellyfin.runtime requires services.jellyfin.enable = true.";
      }
      {
        assertion = !(useApiKey && cfg.adminPasswordFile != null);
        message = "services.jellyfin.runtime: set either apiKeyFile or adminPasswordFile, not both (API-key auth does not use a password).";
      }
    ];

    systemd.services = {
      # Jellyfin answers /System/Info/Public (200) before its first-boot DB
      # migrations finish, and the provider does not retry the startup-wizard
      # POST that then briefly 503s -- so let the reconciler retry the apply,
      # and give the unit room for the readiness poll + retries.
      declarative-jellyfin = lib.recursiveUpdate (tflib.mkReconcileService {
        name = "declarative-jellyfin";
        tfConfig = tf.config;
        inherit (tf) credentials;
        afterUnits = [
          "jellyfin.service"
        ]
        ++ lib.optional bootstrapPassword "${passwordServiceName}.service";
        healthUrl = "${cfg.baseUrl}/System/Info/Public";
        tokenFile = effectiveTokenFile;
        applyRetries = 15;
        applyRetryDelay = 6;
        # Jellyfin runs as a static user with a persistent data dir; co-locate
        # the tfstate there so it is owned by the service user and backed up
        # alongside the library metadata.
        inherit (jellyfin) user group;
        stateDir = jellyfin.dataDir;
      }) { serviceConfig.TimeoutStartSec = "600"; };
    }
    // lib.optionalAttrs bootstrapPassword {
      ${passwordServiceName} = {
        description = "Mint the declarative-jellyfin admin password";
        # No jellyfin.service dependency: this only generates a local secret.
        # The reconciler orders itself after this unit via afterUnits.
        wantedBy = [ "multi-user.target" ];
        path = [ pkgs.coreutils ];
        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
          User = jellyfin.user;
          Group = jellyfin.group;
          StateDirectory = passwordServiceName;
          StateDirectoryMode = "0700";
        };
        script = ''
          set -euo pipefail
          umask 077

          # Mint the admin password exactly once. The persisted file is the
          # "already bootstrapped" marker: on the first apply the provider uses
          # it to create the admin and complete the wizard, and every later run
          # reuses the same value to authenticate. /var/lib survives reboots.
          pw_file="$STATE_DIRECTORY/admin-password"
          if [ ! -s "$pw_file" ]; then
            head -c 24 /dev/urandom | base64 | tr -d '\n' > "$pw_file"
          fi
        '';
      };
    };
  };
}
