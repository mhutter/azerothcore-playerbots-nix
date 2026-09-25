{
  description = "AzerothCore (Playerbot fork) + mod-playerbots, packaged with Nix";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

    # Both trees are pinned together in flake.lock -> they always move in lockstep,
    # which is exactly what the mod-playerbots wiki demands.
    azerothcore-src = {
      url = "github:mod-playerbots/azerothcore-wotlk/Playerbot";
      flake = false;
    };
    mod-playerbots-src = {
      url = "github:mod-playerbots/mod-playerbots/master";
      flake = false;
    };
  };

  outputs =
    {
      self,
      nixpkgs,
      azerothcore-src,
      mod-playerbots-src,
    }:
    let
      system = "x86_64-linux";
      pkgs = import nixpkgs {
        inherit system;
        overlays = [ self.overlays.default ];
      };
    in
    {
      overlays.default = final: prev: {
        azerothcore-playerbots = final.callPackage ./pkgs/azerothcore-playerbots.nix {
          src = azerothcore-src;
          version = "0-unstable-${azerothcore-src.shortRev or "dirty"}";
          modules = {
            mod-playerbots = mod-playerbots-src;
            # further modules go here; copied into modules/<name>
          };
        };
        azerothcore-client-data = final.callPackage ./pkgs/client-data.nix { };
      };

      packages.${system} = {
        default = pkgs.azerothcore-playerbots;
        azerothcore-playerbots = pkgs.azerothcore-playerbots;
        client-data = pkgs.azerothcore-client-data;
      };

      nixosModules.default = import ./modules/azerothcore.nix self.overlays.default;

      checks.${system}.build = pkgs.azerothcore-playerbots;

      devShells.${system}.default = pkgs.mkShell {
        inputsFrom = [ pkgs.azerothcore-playerbots ];
        packages = with pkgs; [
          mysql84
          gdb
        ];
      };
    };
}
