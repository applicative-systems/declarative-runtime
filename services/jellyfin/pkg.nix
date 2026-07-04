# ThePhaseless/jellyfin Terraform/OpenTofu provider, built from source.
#
# Not packaged in the pinned nixpkgs, so we vendor it here using the nixpkgs
# `terraform-providers.mkProvider` builder. That produces the standard provider
# mirror layout (libexec/terraform-providers/<source-address>/<version>/<os>_<arch>/…)
# that `opentofu.withPlugins` walks to assemble the offline plugin dir — so the
# reconciler resolves the provider with no registry access, same as an in-nixpkgs
# provider. `provider-source-address` is derived from `homepage` and must match
# the `source = "ThePhaseless/jellyfin"` OpenTofu normalises to.
#
# To update: bump `rev`, then refresh `hash` (source) and `vendorHash` (Go
# module set) together.
{ pkgs }:
pkgs.terraform-providers.mkProvider {
  owner = "ThePhaseless";
  repo = "terraform-provider-jellyfin";
  rev = "v0.1.0";
  spdx = "MPL-2.0";
  hash = "sha256-kX7cguRxRcRYZy4+7I2ZzmZUVQeI68lrOO5ZZNwR110=";
  vendorHash = "sha256-mnzsEP4BdSf2pwrN/bEoVE2KTdjlqzi8OFQirCfX4GQ=";
  homepage = "https://registry.terraform.io/providers/ThePhaseless/jellyfin";
}
