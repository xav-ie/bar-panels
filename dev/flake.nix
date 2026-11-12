{
  description = "Development flake for BarPanels: pinned builds, checks and the README previews";

  # Kept out of the main flake so its consumers don't inherit these inputs.
  inputs = {
    bar-panels.url = "path:..";
    nixpkgs.url = "github:nixos/nixpkgs/7fd4004d0511991fff3a0524856a9be09e28c5f0";
    treefmt-nix.url = "github:numtide/treefmt-nix";
    treefmt-nix.inputs.nixpkgs.follows = "nixpkgs";
  };

  outputs =
    {
      bar-panels,
      nixpkgs,
      treefmt-nix,
      ...
    }:
    let
      system = "aarch64-darwin";
      pkgs = nixpkgs.legacyPackages.${system};
      root = bar-panels.outPath;
      lib = pkgs.callPackage "${root}/default.nix" { };

      # Draws the README's sample panels with the library (Previews/main.swift).
      previews-bin = pkgs.stdenv.mkDerivation {
        pname = "bar-panels-previews";
        version = "0.1.0";
        src = "${root}/Previews";
        nativeBuildInputs = [ pkgs.swift ];
        buildPhase = ''
          swiftc -O -I ${lib}/lib -L ${lib}/lib -lBarPanels main.swift \
            -o bar-panels-previews
        '';
        installPhase = ''
          mkdir -p $out/bin
          cp bar-panels-previews $out/bin/
        '';
      };

      # `nix run ./dev#previews` from the repo root rewrites assets/*.png. It
      # needs a logged-in Mac session (each sample flashes on screen while it's
      # captured), so it can't run as a check.
      previews = pkgs.writeShellApplication {
        name = "previews";
        runtimeInputs = [
          previews-bin
          pkgs.oxipng
        ];
        text = ''
          dir=''${1:-assets}
          mkdir -p "$dir"
          bar-panels-previews "$dir"
          oxipng --opt max --strip safe --quiet "$dir"/*.png
          echo "Wrote $dir/*.png"
        '';
      };

      fmt = treefmt-nix.lib.evalModule pkgs {
        projectRootFile = "flake.nix";
        programs = {
          nixfmt.enable = true;
          prettier.enable = true;
          swift-format.enable = true;
        };
        settings.global.excludes = [ "*.lock" ];
      };
    in
    {
      packages.${system} = {
        bar-panels = lib;
        inherit previews previews-bin;
        default = lib;
      };

      apps.${system}.previews = {
        type = "app";
        program = "${previews}/bin/previews";
      };

      formatter.${system} = fmt.config.build.wrapper;

      devShells.${system}.default = pkgs.mkShell {
        packages = [
          fmt.config.build.wrapper
          pkgs.actionlint
          pkgs.zizmor
        ];
      };

      checks.${system} = {
        bar-panels = lib;
        # The previews build against the library's public API, so this also
        # catches a change that breaks code using it.
        inherit previews-bin;
        formatting = fmt.config.build.check bar-panels;
      };
    };
}
