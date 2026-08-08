# VStack

VStack is a distribution of agent-stack assets: reusable skills (`skills/`,
Bash 3.2 scripts plus markdown), agent definitions (`agents/`), lifecycle
hooks (`hooks/`), Pi extensions (`pi-extensions/`, TypeScript with committed
esbuild bundles), and a Rust CLI (`cli/`) that installs and refreshes these
into consuming repositories. Working conventions live in the root `AGENTS.md`.

## Review norms

- Tests deliberately use the OS tempdir (`mktemp`, `os.tmpdir`,
  `std::env::temp_dir`) with cleanup so fixtures cannot dirty the git tree.
  The repo's `<worktree>/tmp/` scratch rule governs agent working artifacts,
  not test fixtures — do not flag OS-tempdir use in tests.
- Consumer repos vendor the skills and Pi extensions and re-vendor in
  deliberate batches. Cross-repo consumer-sync impacts are coordination
  notes, not merge blockers; each extension's `CHANGELOG.md` is the
  consumer-facing delta contract.
- Fleet reviewer guidance — review economics, accepted residual classes,
  do-not-re-raise rules — lives in the root `review-bots.md`. Read it
  before reviewing and follow it.
