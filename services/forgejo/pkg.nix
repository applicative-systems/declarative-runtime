# svalabs/forgejo Terraform/OpenTofu provider, built from source.
#
# Not packaged in the pinned nixpkgs, so we vendor it here using the nixpkgs
# `terraform-providers.mkProvider` builder. That produces the standard provider
# mirror layout (libexec/terraform-providers/<source-address>/<version>/<os>_<arch>/…)
# that `opentofu.withPlugins` walks to assemble the offline plugin dir — so the
# reconciler resolves the provider with no registry access, same as an in-nixpkgs
# provider.
#
# To update: bump `rev`, then refresh `hash` (source) and `vendorHash` (Go
# module set) together.
{ pkgs }:
pkgs.terraform-providers.mkProvider {
  owner = "svalabs";
  repo = "terraform-provider-forgejo";
  rev = "v1.5.0";
  spdx = "MPL-2.0";
  hash = "sha256-t7RuVevm4VeWKVNONdRYdziP/Sk1gilc3ZJ32JJJ3CE=";
  vendorHash = "sha256-dC0MYltfE9mGQa9HFnxNdDo5B/gny7ZbbJPAdnMdcRs=";
  homepage = "https://registry.terraform.io/providers/svalabs/forgejo";
}
