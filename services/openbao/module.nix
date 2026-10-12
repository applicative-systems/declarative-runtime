# OpenBao <-> hashicorp/vault pairing.
#
# Enables the upstream `services.openbao` module unchanged, and adds a run-once
# reconciler that applies declarative runtime state (mounts, auth methods,
# policies, identities, PKI and more) against the OpenBao API once
# `openbao.service` is up.
#
# The provider token is not bootstrapped here. A new OpenBao server must be
# initialized and unsealed, which gives the root token and the unseal keys:
# that step stays with the operator. `tokenFile` then holds a token that can do
# what the declared state needs, such as a root token or a token with a broad
# policy.
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

  cfg = config.services.openbao.runtime;
  openbao = config.services.openbao;
  tflib = import ./lib.nix { inherit pkgs nix-tf-schema; };

  # The first TCP listener, in name order. A wildcard address listens on all
  # interfaces, so the reconciler uses the loopback address.
  tcpListeners = lib.filter (l: l.type == "tcp") (lib.attrValues (openbao.settings.listener or { }));
  listener = if tcpListeners == [ ] then null else lib.head tcpListeners;
  # `address` is `<host>:<port>` (the host possibly a bracketed IPv6
  # address); the port is what follows the last colon.
  listenerPort = lib.last (lib.splitString ":" listener.address);
  listenerHost = lib.removeSuffix ":${listenerPort}" listener.address;
  wildcards = [
    ""
    "0.0.0.0"
    "[::]"
  ];
  tlsDisabled = lib.elem (listener.tls_disable or false) [
    true
    1
    "true"
    "1"
  ];
  defaultAddress =
    if listener == null then
      null
    else
      "${if tlsDisabled then "http" else "https"}://${
        if lib.elem listenerHost wildcards then "127.0.0.1" else listenerHost
      }:${listenerPort}";

  tf = tflib.openbaoTfConfig cfg;
in
{
  options.services.openbao.runtime = {
    enable = mkEnableOption (
      "declarative OpenBao configuration, applied via OpenTofu and the vault "
      + "provider after openbao.service starts"
    );

    address = mkOption {
      type = types.nullOr types.str;
      default = defaultAddress;
      defaultText = literalExpression ''"<http or https>://<host>:<port of the first TCP listener in services.openbao.settings.listener>"'';
      example = "https://bao.example.com:8200";
      description = ''
        Address of the OpenBao API the provider targets.

        Defaults to the first TCP listener in name order: `http` when the
        listener sets `tls_disable`, else `https`. A wildcard listen address
        becomes `127.0.0.1`. With TLS, the server certificate must be valid
        for the host in this address.
      '';
    };

    caCertFile = mkOption {
      type = types.nullOr types.str;
      default = null;
      example = "/run/secrets/openbao-ca.pem";
      description = ''
        Runtime path to a PEM file of the CA that signed the OpenBao server
        certificate. Null trusts the system CA bundle.
      '';
    };

    tokenFile = mkOption {
      type = types.nullOr types.str;
      default = null;
      example = "/run/secrets/openbao-token";
      description = ''
        Runtime path to a file containing an OpenBao token. Its policies must
        allow every change that the declared state makes.

        This is a path resolved on the target host (e.g. provisioned by
        sops-nix or agenix), NOT a store path: it is handed to the reconciler
        via systemd `LoadCredential=` and never copied into the Nix store.
      '';
    };
  }
  // tflib.resourceOptions;

  config = mkIf cfg.enable {
    assertions = [
      {
        assertion = openbao.enable;
        message = "services.openbao.runtime requires services.openbao.enable = true.";
      }
      {
        assertion = cfg.address != null;
        message = "services.openbao.runtime requires an address: add a TCP listener to services.openbao.settings.listener, or set services.openbao.runtime.address.";
      }
      {
        assertion = cfg.tokenFile != null;
        message = "services.openbao.runtime requires a token: set services.openbao.runtime.tokenFile.";
      }
    ];

    systemd.services.declarative-openbao =
      lib.recursiveUpdate
        (tflib.mkReconcileService {
          name = "declarative-openbao";
          tfConfig = tf.config;
          inherit (tf) credentials;
          afterUnits = [ "openbao.service" ];
          # 200 only once the server is initialized, unsealed and active.
          healthUrl = "${cfg.address}/v1/sys/health";
          inherit (cfg) tokenFile;
          # The reconciler only uses the API, so it runs as a dynamic user of its
          # own. Its state cannot go below `/var/lib/openbao`: that is the state
          # directory of OpenBao's dynamic user, and systemd cannot make a state
          # directory of a different unit in it.
          user = "declarative-openbao";
          group = "declarative-openbao";
          dynamicUser = true;
          stateDir = "/var/lib/declarative-openbao";
        })
        (
          lib.optionalAttrs (cfg.caCertFile != null) {
            # The health probe must trust the same CA as the provider.
            environment.CURL_CA_BUNDLE = cfg.caCertFile;
          }
        );
  };
}
