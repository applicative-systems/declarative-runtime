# Aggregator module. Imports every service<->provider pairing plus the shared
# reconciliation machinery (see ./lib). Add new pairings under ../services/<svc>.
{
  imports = [
    ../services/forgejo/module.nix
    ../services/hetzner-dns/module.nix
    ../services/jellyfin/module.nix
    ../services/keycloak/module.nix
    ../services/proxmox-ve/module.nix
  ];
}
