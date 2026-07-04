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
