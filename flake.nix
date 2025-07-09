{
  inputs.nixpkgs.url = "nixpkgs-unstable"; # "nixpkgs";

  outputs = { self, nixpkgs }: let
    lib = nixpkgs.lib;
    systems = ["aarch64-linux" "x86_64-linux"];
    eachSystem = f:
      lib.foldAttrs lib.mergeAttrs {}
      (map (s: lib.mapAttrs (_: v: {${s} = v;}) (f s)) systems);
  in
    eachSystem (system: let
      pkgs = import nixpkgs {
        inherit system;
      };
    in {
      devShells.default = pkgs.mkShell {
        # inputsFrom = with neon; [neomacs zss];

        packages = with pkgs; [
          valgrind
          strace
          zon2nix

          python3
          pyright

          luajit
          pkg-config

          # Development
          alejandra
          zig
        ];
      };

      formatter = pkgs.alejandra;
    });
}
