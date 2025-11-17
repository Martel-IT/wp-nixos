#
# Function to generate the NixOS configurations for the Flake output.
#
{
  # `lib.nixosSystem` in the selected Nixpkgs.
  nixosSystem,
  # The Flake itself.
  wpbox
}:
let
  mkNode = system: config: nixosSystem {
    inherit system;
    modules = [
      wpbox.nixosModules
      config
    ];
  };
in {
  nixosConfigurations = {
    aarch64-linux = mkNode "aarch64-linux" ./aarch64-linux/configuration.nix;
    x86_64-linux = mkNode "x86_64-linux" ./x86_64-linux/configuration.nix;
    devm = mkNode "aarch64-linux" ./devm/configuration.nix;
  };
}