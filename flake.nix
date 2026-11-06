{
  description = "kendex: package manager for AI coding agents, skills, and hooks";

  # nixos-unstable, not a release branch: the workspace's rust-version is
  # newer than the rustc nixos-26.05 carries, and cargo refuses to build a
  # package for an older compiler. A consumer that makes this input follow
  # its own nixpkgs needs a rustc at least that new.
  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  outputs =
    { self, nixpkgs }:
    let
      # The Linux architectures the release builds the command for.
      systems = [
        "x86_64-linux"
        "aarch64-linux"
      ];
    in
    {
      packages = nixpkgs.lib.genAttrs systems (
        system:
        let
          kendex-cli = nixpkgs.legacyPackages.${system}.callPackage ./packaging/nix/kendex-cli.nix {
            src = self;
            sourceCommit = self.rev or null;
          };
        in
        {
          inherit kendex-cli;
          default = kendex-cli;
        }
      );
    };
}
