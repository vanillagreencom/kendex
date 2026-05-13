{
  description = "Cross-harness package manager for AI coding tools";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";

    flake-parts = {
      url = "github:hercules-ci/flake-parts";
      inputs.nixpkgs-lib.follows = "nixpkgs";
    };
  };

  outputs =
    inputs@{ self, flake-parts, ... }:
    flake-parts.lib.mkFlake { inherit inputs; } {
      systems = [
        "x86_64-linux"
        "aarch64-linux"
        "aarch64-darwin"
        "x86_64-darwin"
      ];

      perSystem =
        { pkgs, ... }:
        let
          version = (builtins.fromTOML (builtins.readFile ./cli/Cargo.toml)).package.version;
        in
        {
          packages.default = pkgs.rustPlatform.buildRustPackage {
            pname = "vstack";
            inherit version;

            src = self;

            sourceRoot = "source/cli";

            cargoHash = "sha256-ifmlOan4DTcxt5GbuYwNqFlPATNU5nul+E4wI9J/SPE=";

            nativeBuildInputs = with pkgs; [
              git
            ];

            meta = {
              description = "Cross-harness package manager for AI coding tools";
              homepage = "https://github.com/vanillagreencom/vstack";
              license = pkgs.lib.licenses.mit;
              mainProgram = "vstack";
              maintainers = [ ];
              platforms = pkgs.lib.platforms.linux ++ pkgs.lib.platforms.darwin;
            };
          };

          devShells.default = pkgs.mkShell {
            inputsFrom = [ self.packages.${pkgs.stdenv.hostPlatform.system}.default ];
          };
        };
    };
}
