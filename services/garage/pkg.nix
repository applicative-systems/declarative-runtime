# Arsolitt/garagehq Terraform/OpenTofu provider, built from source.
#
# Not packaged in the pinned nixpkgs, so we vendor it here using the nixpkgs
# `terraform-providers.mkProvider` builder. That produces the standard provider
# mirror layout (libexec/terraform-providers/<source-address>/<version>/<os>_<arch>/...)
# that `opentofu.withPlugins` walks to assemble the offline plugin dir, so the
# reconciler resolves the provider with no registry access, same as an in-nixpkgs
# provider.
#
# To update: bump `rev`, then refresh `hash` (source) and `vendorHash` (Go
# module set) together.
#
# `go.mod` asks for Go 1.26.10, which is newer than the Go of `buildGoModule`.
{ pkgs }:
pkgs.terraform-providers.mkProvider {
  owner = "Arsolitt";
  repo = "terraform-provider-garagehq";
  rev = "v1.3.1";
  spdx = "MIT";
  hash = "sha256-lifONrWL/QdVTpZnl7oXPiwxveCuayGBUkyvrwHQbvM=";
  vendorHash = "sha256-lmudKUXeHHDVSLKozobHMuwjkSdXZyPhfLfIg+tXs+4=";
  mkProviderGoModule = pkgs.buildGoLatestModule;
  homepage = "https://registry.terraform.io/providers/arsolitt/garagehq";
}
