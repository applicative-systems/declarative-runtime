# Aggregator module. Imports every service<->provider pairing plus the shared
# reconciliation machinery (see ./lib). Add new pairings under ../services/<svc>.
{
  imports = [
    ../services/forgejo/module.nix
  ];
}
