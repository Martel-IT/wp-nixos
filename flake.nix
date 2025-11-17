{
  description = "WPBox - NixOS WordPress Infrastructure with Auto-Tuning";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
  };

  outputs = { self, nixpkgs }:
  let

    modules = {
      nixosModules.imports = [
        ./modules
      ];
    };

    nodes = import ./nodes {
      nixosSystem = nixpkgs.lib.nixosSystem;
      wpbox = self; # Passes the flake itself
    };
  in

    modules // nodes;
}
