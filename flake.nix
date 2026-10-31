{
  description = "Quinta Roblox launcher with a bundled Darling runtime";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  outputs =
    { self, nixpkgs }:
    let
      system = "x86_64-linux";
      pkgs = import nixpkgs { inherit system; };
      quinta = pkgs.callPackage ./packaging/nix { };
      runtimeCheck = package: {
        type = "app";
        program = "${
          pkgs.callPackage ./packaging/nix/check-runtime.nix { quinta = package; }
        }/bin/quinta-runtime-check";
        meta.description = "Check Quinta's ${package.runtime} runtime in a disposable prefix";
      };
    in
    {
      packages.${system} = {
        inherit quinta;
        default = quinta;
        quinta-regular = quinta.override { runtime = "regular"; };
      };

      apps.${system} = {
        default = {
          type = "app";
          program = "${quinta}/bin/quinta";
          meta.description = quinta.meta.description;
        };
        check-runtime = runtimeCheck quinta;
        check-runtime-regular = runtimeCheck self.packages.${system}.quinta-regular;
      };

      overlays.default = final: prev: {
        quinta = final.callPackage ./packaging/nix { };
      };

      nixosModules.default = import ./packaging/nix/module.nix self;

      checks.${system} = {
        inherit quinta;
        regular = self.packages.${system}.quinta-regular;
      };

      formatter.${system} = pkgs.nixfmt;
    };
}
