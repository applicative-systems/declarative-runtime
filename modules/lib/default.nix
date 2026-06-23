# Shared, provider-agnostic helpers for the declarative-service pairings: the
# .tf.json label/file helpers and the run-once OpenTofu reconciler unit.
#
# Provider-specific pieces — the provider-wrapped executor, the .tf.json
# provider/resource generation, the token variable name — live in each pairing's
# services/<svc>/lib.nix and are injected into the helpers below.
{ pkgs }:
let
  inherit (pkgs) lib;
in
rec {
  # Sanitize an arbitrary string into a valid Terraform block label
  # ([A-Za-z_][A-Za-z0-9_-]*). Always prefixed, so the result starts with a
  # letter regardless of the input.
  tfLabel =
    prefix: name:
    "${prefix}_"
    + lib.stringAsChars (c: if builtins.match "[A-Za-z0-9_-]" c != null then c else "_") name;

  # Render a config attrset to a .tf.json store file. Safe by construction: the
  # config must carry no secrets (anything in the store is world-readable).
  tfJsonFile = name: config: pkgs.writeText "${name}.tf.json" (builtins.toJSON config);

  # Build the run-once reconciler systemd service definition.
  #
  #   name       unit + generated-config name (e.g. "declarative-forgejo")
  #   tfConfig   the provider-specific config attrset to apply
  #   afterUnits units to order/require after (the service's primary unit)
  #   healthUrl  URL polled until the service answers, before applying
  #   tokenFile  runtime path to the admin token, exposed via LoadCredential
  #   executor   OpenTofu wrapped with the pairing's provider (offline mirror)
  #   tokenVar   Terraform input variable carrying the token; also the
  #              LoadCredential id, so `TF_VAR_<tokenVar>` is fed from it
  #   credentials extra TF_VAR_<id> -> host file path pairs (per-resource
  #              secrets); each is LoadCredential'd and exported like the token
  #   user/group the base service's user/group the reconciler runs as
  #   stateDir   the base service's primary state dir; Terraform state lives in
  #              a `declarative-terraform` subdir of it, co-located with the service
  #   dynamicUser  set when the base service runs as systemd DynamicUser (so the
  #                `User=` name only exists per-unit). Pairs with `stateDirectory`
  #                so the reconciler is allocated the same hashed UID as the
  #                primary unit and writes state into a managed StateDirectory.
  #   stateDirectory  relative path under /var/lib used as `StateDirectory=` when
  #                   `dynamicUser` is set. Must match `stateDir` (e.g. stateDir
  #                   `/var/lib/keycloak` with stateDirectory `keycloak/...`), so
  #                   the script's absolute path resolves to systemd's managed dir.
  mkReconcileService =
    {
      name,
      tfConfig,
      afterUnits,
      healthUrl,
      tokenFile,
      executor,
      tokenVar,
      user,
      group,
      stateDir,
      credentials ? { },
      dynamicUser ? false,
      stateDirectory ? null,
    }:
    let
      confFile = tfJsonFile name tfConfig;
      # Admin token + any per-resource secret files, each kept out of the store
      # and exposed to tofu as TF_VAR_<id> via systemd LoadCredential=.
      allCredentials = {
        ${tokenVar} = tokenFile;
      }
      // credentials;
      # Terraform state is co-located with the base service: a subdir of its
      # primary state directory, created and owned by the service user.
      workDir = "${stateDir}/declarative-terraform";
    in
    {
      description = "Declarative reconciliation for ${name} (OpenTofu)";
      after = afterUnits;
      requires = afterUnits;
      wantedBy = [ "multi-user.target" ];
      # Re-apply whenever the generated configuration changes.
      restartTriggers = [ confFile ];
      path = [
        executor
        pkgs.curl
        pkgs.coreutils
      ];
      environment = {
        TF_IN_AUTOMATION = "1";
        TF_INPUT = "0";
      };
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        # Run as the base service's user so Terraform state can live in (and be
        # backed up alongside) that service's primary state directory.
        User = user;
        Group = group;
        # Secrets stay out of the store: read from the credentials dir at runtime.
        LoadCredential = lib.mapAttrsToList (id: path: "${id}:${path}") allCredentials;
      }
      // lib.optionalAttrs dynamicUser {
        # Bases like Keycloak ship no persistent state dir and run as
        # systemd DynamicUser=true; the `User=` name is hashed to a stable UID
        # that's reused across units, and systemd creates/owns the state dir.
        DynamicUser = true;
        StateDirectory = stateDirectory;
        StateDirectoryMode = "0700";
      };
      script = ''
        set -euo pipefail
        umask 077

        # Work in a Terraform state dir under the base service's primary state
        # directory, created 0700 on first run and owned by the service user.
        mkdir -p ${lib.escapeShellArg workDir}
        cd ${lib.escapeShellArg workDir}

        # Refresh the generated config (state persists across runs).
        install -m 0600 ${confFile} ./main.tf.json

        # Gate on the service actually answering before applying.
        for _ in $(seq 1 60); do
          if curl -fsS -o /dev/null "${healthUrl}"; then
            break
          fi
          sleep 2
        done

        # Feed every credential to tofu as TF_VAR_<id>, read from the creds dir.
        for id in ${lib.escapeShellArgs (lib.attrNames allCredentials)}; do
          export "TF_VAR_$id=$(cat "$CREDENTIALS_DIRECTORY/$id")"
        done
        tofu init -no-color
        tofu apply -auto-approve -input=false -no-color
      '';
    };
}
