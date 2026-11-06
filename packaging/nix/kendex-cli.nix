# The kendex command alone, built from this checkout. The repository's
# flake.nix calls this with the source tree and the commit it was fetched
# at; the version is the Cargo workspace's own and the dependencies are
# Cargo.lock's, so neither has a second copy here.
{
  lib,
  rustPlatform,
  pkg-config,
  makeBinaryWrapper,
  versionCheckHook,
  dbus,
  gitMinimal,
  src,
  # The commit a pinned flake input was fetched at, or null for a tree with
  # uncommitted changes. A build of a commit names it the way the Arch
  # kendex-cli-git package's does; a dirty tree has no commit to name.
  sourceCommit ? null,
}:

let
  workspace = lib.importTOML (src + "/Cargo.toml");
in
rustPlatform.buildRustPackage {
  pname = "kendex-cli";
  inherit (workspace.workspace.package) version;
  inherit src;

  cargoLock.lockFile = src + "/Cargo.lock";

  # The CLI package alone. The workspace also holds the desktop app, whose
  # Tauri and WebKit libraries this package deliberately does not depend on.
  cargoBuildFlags = [
    "-p"
    "kendex-cli"
  ];

  # The suites run on the repository's own CI route; they drive harness
  # CLIs, Git remotes and a fixture home a Nix build sandbox does not have.
  doCheck = false;

  # The installed, wrapped command prints its version once with an empty
  # environment, so a command that cannot start from its own closure fails
  # this build instead of reaching a consumer.
  doInstallCheck = true;
  nativeInstallCheckInputs = [ versionCheckHook ];

  env = lib.optionalAttrs (sourceCommit != null) {
    KENDEX_SOURCE_COMMIT = sourceCommit;
  };

  # The command links libdbus-1 through the keyring crate's
  # sync-secret-service backend, and libdbus-sys finds it with pkg-config.
  nativeBuildInputs = [
    pkg-config
    makeBinaryWrapper
  ];
  buildInputs = [ dbus ];

  # The command materializes catalogs with git, 2.41 or newer for
  # `--attr-source`. The minimal build keeps HTTPS fetches and drops the
  # Perl, Python and manual pages the full one would add to the closure.
  # Prefixed, not replaced, so the harness CLIs and tools a package runs
  # still resolve from the person's own PATH.
  postInstall = ''
    wrapProgram $out/bin/kendex --prefix PATH : ${lib.makeBinPath [ gitMinimal ]}
  '';

  meta = {
    description = "Package manager for AI coding agents, skills, and hooks (CLI only)";
    homepage = "https://kendex.ai";
    license = lib.licenses.mit;
    mainProgram = "kendex";
  };
}
