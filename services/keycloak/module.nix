{ config, lib, ... }:
let
  cfg = config.services.keycloak.runtime;
in
{
  options = {
    services.keycloak.runtime = {
      enable = lib.mkEnableOption "declarative keycloak runtime config";
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = config.services.keycloak.runtime.enable -> config.services.keycloak.enable;
        message = "If the declarative keycloak runtime is enabled, the keycloak service must also be enabled.";
      }
    ];
  };
}
