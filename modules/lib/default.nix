# shared helpers for the pairings: tf-label/file helpers and the run-once
# reconciler unit. provider-specific bits live in services/<svc>/lib.nix.
{ pkgs }:
let
  inherit (pkgs) lib;
in
rec {
  # turn an arbitrary string into a valid Terraform block label. always
  # prefixed so the result starts with a letter.
  tfLabel =
    prefix: name:
    "${prefix}_"
    + lib.stringAsChars (c: if builtins.match "[A-Za-z0-9_-]" c != null then c else "_") name;

  # write the config as a .tf.json file in the nix store. must contain no
  # secrets -- the store is world-readable.
  tfJsonFile = name: config: pkgs.writeText "${name}.tf.json" (builtins.toJSON config);

  # build the run-once reconciler systemd service.
  #
  #   name        unit + generated-config name (e.g. "declarative-forgejo")
  #   tfConfig    the .tf.json config to apply
  #   afterUnits  units to order/require after (the service's main unit)
  #   healthUrl   url polled until the service answers, before applying
  #   tokenFile   path to the admin token on the host, read via LoadCredential
  #   executor    OpenTofu wrapped with the pairing's provider (offline)
  #   tokenVar    name of the sensitive tf variable carrying the token; also
  #               the LoadCredential id -- exported as TF_VAR_<tokenVar>
  #   credentials extra TF_VAR_<id> -> host path pairs for per-resource
  #               secrets, handled the same way as tokenFile
  #   user/group  the service's user/group; the reconciler runs as them
  #   stateDir    base dir for the reconciler; tfstate lives in a
  #               `declarative-terraform` subdir of it
  #   dynamicUser set when the base service uses systemd DynamicUser=true
  #               (the `User=` name only exists per-unit). the reconciler
  #               then runs with DynamicUser=true too, so it picks up the
  #               same hashed UID as the main unit, and systemd creates
  #               the work dir via StateDirectory= (derived from stateDir).
  #               requires stateDir to live under /var/lib.
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
    }:
    let
      confFile = tfJsonFile name tfConfig;
      # admin token + per-resource secrets, all read via LoadCredential
      # so they never land in the world-readable store.
      allCredentials = {
        ${tokenVar} = tokenFile;
      }
      // credentials;
      # tfstate lives in this subdir of stateDir.
      workDir = "${stateDir}/declarative-terraform";
      # under DynamicUser= systemd creates the dir via StateDirectory=
      # (relative to /var/lib). derive both from stateDir so the script
      # path and the unit declaration cannot drift.
      stateDirectoryRelative = lib.removePrefix "/var/lib/" workDir;
    in
    assert lib.assertMsg (!dynamicUser || lib.hasPrefix "/var/lib/" stateDir)
      "mkReconcileService: dynamicUser=true requires stateDir to live under /var/lib (got '${stateDir}'), so systemd can express the work dir as a relative StateDirectory=.";
    {
      description = "Declarative reconciliation for ${name} (OpenTofu)";
      after = afterUnits;
      requires = afterUnits;
      wantedBy = [ "multi-user.target" ];
      # re-apply when the generated config changes.
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
        # run as the service's own user so tfstate sits next to its data.
        User = user;
        Group = group;
        # secrets stay out of the store; loaded into $CREDENTIALS_DIRECTORY at runtime.
        LoadCredential = lib.mapAttrsToList (id: path: "${id}:${path}") allCredentials;
      }
      // lib.optionalAttrs dynamicUser {
        # services like Keycloak use DynamicUser=true and have no
        # persistent state dir. systemd hashes the User= name to a
        # stable UID that's shared across units and owns the state dir.
        DynamicUser = true;
        StateDirectory = stateDirectoryRelative;
        StateDirectoryMode = "0700";
      };
      script = ''
        set -euo pipefail
        umask 077

        # work in a subdir of the service's state dir; created 0700 on
        # first run, owned by the service user.
        mkdir -p ${lib.escapeShellArg workDir}
        cd ${lib.escapeShellArg workDir}

        # refresh the generated config (tfstate persists across runs).
        install -m 0600 ${confFile} ./main.tf.json

        # wait for the service to actually answer before applying.
        for _ in $(seq 1 60); do
          if curl -fsS -o /dev/null "${healthUrl}"; then
            break
          fi
          sleep 2
        done

        # pass each credential to tofu as TF_VAR_<id>.
        for id in ${lib.escapeShellArgs (lib.attrNames allCredentials)}; do
          export "TF_VAR_$id=$(cat "$CREDENTIALS_DIRECTORY/$id")"
        done
        tofu init -no-color
        tofu apply -auto-approve -input=false -no-color
      '';
    };
}
