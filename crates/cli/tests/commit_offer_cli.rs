//! The commit offer through the binary: every state the design's table
//! gives the CLI a detection for, driven by a real repository, a bare
//! `origin`, the repository's own hooks, and a fake `gh` on the child's
//! `PATH` whose answer is chosen by the `--repo` value every call is
//! bound to. The child has no terminal, so the interactive block is not
//! reachable here; its rows are pinned in `commands/commit_offer/tests.rs`.
#![cfg(unix)]

#[path = "../../test_util.rs"]
mod test_util;
use test_util::rooted;

use std::fs;
use std::os::unix::fs::PermissionsExt;
use std::path::{Path, PathBuf};
use std::process::{Command, Output};

use kendex_core::process::Hardened;

#[allow(clippy::expect_used)]
fn kendex(home: &Path, cwd: &Path, args: &[&str]) -> Output {
    Command::new(env!("CARGO_BIN_EXE_kendex"))
        .args(args)
        .current_dir(cwd)
        .env_clear()
        .envs(test_util::fixture_env(home))
        .env("KENDEX_BACKGROUND_REFRESH", "off")
        .env("PATH", path_with_fake_gh(home))
        .output()
        .expect("kendex binary runs")
}

fn said(output: &Output) -> String {
    format!(
        "{}{}",
        String::from_utf8_lossy(&output.stdout),
        String::from_utf8_lossy(&output.stderr)
    )
}

#[allow(clippy::unwrap_used)]
fn git(dir: &Path, args: &[&str]) -> String {
    let home = dir.to_str().unwrap();
    let out = Hardened::git(args, Some(dir))
        .env("HOME", home)
        .env("KENDEX_REAL_HOME", "1")
        .env("GIT_AUTHOR_NAME", "t")
        .env("GIT_AUTHOR_EMAIL", "t@t")
        .env("GIT_COMMITTER_NAME", "t")
        .env("GIT_COMMITTER_EMAIL", "t@t")
        .run()
        .unwrap();
    assert!(
        out.status.success(),
        "git {args:?}: {}",
        String::from_utf8_lossy(&out.stderr)
    );
    String::from_utf8_lossy(&out.stdout).into_owned()
}

/// A repository declaring the claude harness with its root `AGENTS.md`
/// committed: `apply --yes` renders the `CLAUDE.md` shim and the
/// inventory, which is the offer's two-file set. Nothing is installed, so
/// no record is written; the record joins the set where an install is
/// (`the_install_record_is_committed_with_the_renders`).
#[allow(clippy::unwrap_used)]
fn project(tmp: &tempfile::TempDir) -> PathBuf {
    let home = rooted(tmp);
    let project = home.join("dev/app");
    fs::create_dir_all(project.join(".claude")).unwrap();
    fs::write(
        project.join("kendex.toml"),
        "schema = 6\n\n[install]\nharnesses = [\"claude\"]\n",
    )
    .unwrap();
    fs::write(project.join("AGENTS.md"), "# app\n").unwrap();
    git(&project, &["init", "-q", "-b", "main"]);
    git(&project, &["config", "user.email", "t@t"]);
    git(&project, &["config", "user.name", "t"]);
    git(&project, &["config", "commit.gpgsign", "false"]);
    git(&project, &["config", "core.hooksPath", ".git/hooks"]);
    git(&project, &["add", "-A"]);
    git(&project, &["commit", "-q", "-m", "files"]);
    project
}

/// A bare repository the project calls `origin`, under a name the fake
/// `gh` reads its answer from.
#[allow(clippy::unwrap_used)]
fn origin(project: &Path, name: &str) -> PathBuf {
    let bare = project.parent().unwrap().join(format!("{name}.git"));
    git(
        project,
        &[
            "init",
            "-q",
            "--bare",
            "-b",
            "main",
            &bare.to_string_lossy(),
        ],
    );
    git(
        project,
        &["remote", "add", "origin", &bare.to_string_lossy()],
    );
    git(project, &["push", "-q", "-u", "origin", "main"]);
    bare
}

/// The shipped package launcher, the one owner of the owned-region
/// grammar. A fixture renderer answers `region-bounds` by calling it, so no
/// fixture carries a second copy of the bounds rule.
const PACKAGE_LAUNCHER: &str = concat!(
    env!("CARGO_MANIFEST_DIR"),
    "/../../skills/bot-instructions/scripts/bot-instructions"
);

#[allow(clippy::unwrap_used)]
fn executable(path: &Path, body: &str) {
    fs::create_dir_all(path.parent().unwrap()).unwrap();
    fs::write(path, body).unwrap();
    fs::set_permissions(path, fs::Permissions::from_mode(0o755)).unwrap();
}

/// A `gh` whose answers are chosen by the repository it was bound to.
/// The directory holds nothing but `gh`, so git resolves as before.
#[allow(clippy::unwrap_used)]
fn path_with_fake_gh(home: &Path) -> String {
    let dir = home.join("fake-bin");
    executable(&dir.join("gh"), FAKE_GH);
    format!(
        "{}:{}",
        dir.display(),
        std::env::var("PATH").unwrap_or_default()
    )
}

const FAKE_GH: &str = r#"#!/bin/sh
echo "$@" >> "$(dirname "$0")/calls"
repo=""
prev=""
for a in "$@"; do
  if [ "$prev" = "--repo" ]; then repo="$a"; fi
  prev="$a"
done
case "$1 $2" in
"pr list")
  case "$repo" in
    *notauth*) echo "To get started with GitHub CLI, please run:  gh auth login" >&2; exit 4;;
    *open*) echo '[{"number":41,"url":"https://github.com/acme/site/pull/41"}]'; exit 0;;
    *) echo '[]'; exit 0;;
  esac;;
"pr create")
  case "$repo" in
    *refuse*) echo "GraphQL: GitHub Actions is not permitted to create or approve pull requests (createPullRequest)" >&2; exit 1;;
    *) echo "https://github.com/acme/site/pull/41"; exit 0;;
  esac;;
esac
exit 1
"#;

fn apply(home: &Path, project: &Path, flags: &[&str]) -> (Output, String) {
    let mut args = vec!["apply", "--yes"];
    args.extend_from_slice(flags);
    let output = kendex(home, project, &args);
    let text = said(&output);
    (output, text)
}

fn head_subject(project: &Path) -> String {
    git(project, &["log", "-1", "--format=%s"])
        .trim()
        .to_owned()
}

/// No terminal and no flag: one line naming the flags, and the run exits
/// as the verb would. A flag that leaves is the same success with no line.
#[test]
fn without_a_terminal_the_line_names_the_flags_and_leave_says_nothing() {
    let tmp = tempfile::tempdir().unwrap();
    let home = rooted(&tmp);
    let project = project(&tmp);
    let (output, text) = apply(&home, &project, &[]);
    assert!(output.status.success(), "{text}");
    assert!(
        text.contains(
            "2 files kendex wrote are not committed; run again with --commit, --push, --pull-request or --leave"
        ),
        "{text}"
    );
    assert_eq!(head_subject(&project), "files");

    let (output, text) = apply(&home, &project, &["--leave"]);
    assert!(output.status.success(), "{text}");
    assert!(!text.contains("not committed"), "{text}");
    assert!(git(&project, &["status", "--porcelain"]).contains("?? CLAUDE.md"));
}

/// The commit route: the set is committed with the command's message, or
/// the one `--message` gives, and the ledger carries the part.
#[test]
fn the_commit_flag_commits_the_set_with_the_commands_message() {
    let tmp = tempfile::tempdir().unwrap();
    let home = rooted(&tmp);
    let project = project(&tmp);
    let (output, text) = apply(&home, &project, &["--commit"]);
    assert!(output.status.success(), "{text}");
    assert!(text.contains("committed 2 files as "), "{text}");
    assert!(
        text.contains(" · committed 2 files"),
        "no ledger part: {text}"
    );
    assert!(
        !home.join("fake-bin/calls").exists(),
        "a commit that takes no pull request asked gh"
    );
    assert_eq!(head_subject(&project), "chore: kendex apply");
    let files = git(&project, &["show", "--name-only", "--format=", "HEAD"]);
    assert!(
        files.contains("CLAUDE.md") && files.contains(".kendex-generated.json"),
        "{files}"
    );
    assert!(!files.contains("kendex.toml"), "{files}");

    // A fresh checkout, the person's own edit beside the renders: the
    // message given is the one used, and the edit is never swept in.
    let tmp = tempfile::tempdir().unwrap();
    let home = rooted(&tmp);
    let project = self::project(&tmp);
    fs::write(project.join("AGENTS.md"), "# app\n\nmore\n").unwrap();
    let (output, text) = apply(&home, &project, &["--commit", "--message", "docs: shim"]);
    assert!(output.status.success(), "{text}");
    assert!(text.contains("committed 2 files as "), "{text}");
    assert_eq!(head_subject(&project), "docs: shim");
    assert!(
        git(&project, &["status", "--porcelain"]).contains(" M AGENTS.md"),
        "the person's own change was swept into the commit"
    );
}

/// Where something is installed, the record is in the set beside the
/// renders and the inventory, and this machine's half of it is not: the
/// commit that lands a render lands what says which package it is, and a
/// clone reads the render as that package. The must-fail control for the
/// lock being a companion of the render set: without it the record stays
/// an untracked file the offer never names.
#[test]
#[allow(clippy::unwrap_used)]
fn the_install_record_is_committed_with_the_renders() {
    let tmp = tempfile::tempdir().unwrap();
    let home = rooted(&tmp);
    let project = project(&tmp);
    fs::create_dir_all(project.join("catalog/skills/deploy")).unwrap();
    fs::write(
        project.join("catalog/skills/deploy/SKILL.md"),
        "---\nname: deploy\ndescription: ship the service\n---\nRun the deploy.\n",
    )
    .unwrap();
    fs::write(
        project.join("kendex.toml"),
        "schema = 6\n\n[install]\nharnesses = [\"claude\"]\n\n[sources.cat]\npath = \"catalog\"\n\n[skills.deploy]\nsource = \"cat\"\n",
    )
    .unwrap();
    git(&project, &["add", "-A"]);
    git(&project, &["commit", "-q", "-m", "declare"]);

    let (output, text) = apply(&home, &project, &["--commit"]);
    assert!(output.status.success(), "{text}");
    assert_eq!(head_subject(&project), "chore: kendex apply");
    let files = git(&project, &["show", "--name-only", "--format=", "HEAD"]);
    for carried in [
        ".kendex-lock.json",
        ".kendex-generated.json",
        ".agents/skills/deploy/SKILL.md",
    ] {
        assert!(
            files.lines().any(|line| line == carried),
            "{carried}: {files}"
        );
    }
    assert!(!files.contains("lock-local.json"), "{files}");
    assert!(project.join(".cache/kendex/lock-local.json").is_file());
    // The ignore file is the person's, edited rather than owned, so it is
    // the one thing left for them; the machine half is under it.
    assert_eq!(git(&project, &["status", "--porcelain"]), "?? .gitignore\n");
}

/// The CLI apply door runs the installed bot renderer before it builds the
/// commit offer, so the same commit carries the engine and package outputs.
#[test]
fn apply_renders_and_commits_the_bot_instruction_surface() {
    let tmp = tempfile::tempdir().unwrap();
    let home = rooted(&tmp);
    let project = project(&tmp);
    let script = project.join(".agents/skills/bot-instructions/scripts/bot-instructions");
    executable(
        &script,
        &format!(
            "#!/bin/sh\nif [ \"$1\" = region-bounds ]; then\n  exec '{PACKAGE_LAUNCHER}' \"$@\"\nfi\nmkdir -p .github\nprintf 'updated review rules\\n' > .github/copilot-instructions.md\nif ! grep -q 'old generated rules' AGENTS.md; then\n  echo 'fixture-render: AGENTS.md has no generated rules' >&2\n  exit 1\nfi\nsed 's/old generated rules/new generated rules/' AGENTS.md > AGENTS.md.rendered && mv AGENTS.md.rendered AGENTS.md || exit 1\necho 'wrote .github/copilot-instructions.md'\nprintf 'wrote region AGENTS.md\\t## Code Review Rules\\n'\n"
        ),
    );
    fs::write(
        project.join("AGENTS.md"),
        "# App\n\nbase user text\n\n## Code Review Rules\n\nold generated rules\n\n## Notes\n\nbase note\n",
    )
    .unwrap();
    fs::write(
        project.join(".agents/skills/bot-instructions/SKILL.md"),
        "---\nname: bot-instructions\ndescription: fixture\nrepo-effects:\n  summary: fixture render\n  writes: ['.github/copilot-instructions.md']\n  installer: scripts/bot-instructions render\n  checker: scripts/bot-instructions check\n---\n",
    )
    .unwrap();
    git(&project, &["add", "-A"]);
    git(&project, &["commit", "-q", "-m", "bot package"]);
    fs::write(
        project.join("AGENTS.md"),
        "# App\n\nworking user text\n\n## Code Review Rules\n\nold generated rules\n\n## Notes\n\nworking note\n",
    )
    .unwrap();
    let scope = kendex_core::model::Scope::Project {
        root: project.clone(),
    };
    let env = kendex_core::env::Env::fake(&home, kendex_core::env::FakeOs::Linux);
    let mut lock = kendex_core::lock::Lock {
        version: kendex_core::lock::LOCK_VERSION,
        ..kendex_core::lock::Lock::default()
    };
    lock.entries.insert(
        kendex_core::lock::entry_key(
            kendex_core::model::ItemKind::Skill,
            "bot-instructions",
            kendex_core::model::HarnessId::Codex,
        ),
        kendex_core::lock::LockEntry {
            name: "bot-instructions".to_owned(),
            kind: kendex_core::model::ItemKind::Skill,
            harness: kendex_core::model::HarnessId::Codex,
            source: "local".to_owned(),
            source_repo: "local".to_owned(),
            machine: Some(kendex_core::lock::MachineRecord {
                method: kendex_core::manifest::Method::Copy,
                installed_at: "2026-09-20T00:00:00Z".to_owned(),
            }),
            source_hash: "fixture".to_owned(),
            source_commit: None,
            rendered_hash: Some("fixture".to_owned()),
            enabled: true,
            upstream_skills: None,
            emitted: Some(kendex_core::lock::EmittedArtifact {
                kind: kendex_core::model::ItemKind::Skill,
                name: "bot-instructions".to_owned(),
                paths: vec![project.join(".agents/skills/bot-instructions")],
            }),
            registration: None,
            reasons: std::collections::BTreeSet::from([kendex_core::lock::Reason::Requested]),
        },
    );
    kendex_core::lock::save(&kendex_core::lock::lock_path(&env, &scope), &lock).unwrap();
    let repo = kendex_core::guard::Repo::at(&project).unwrap();
    kendex_core::repo_effects::armed::arm(
        kendex_core::repo_effects::armed::record_dir(&repo, false),
        "bot-instructions",
    )
    .unwrap();

    let (output, text) = apply(&home, &project, &["--commit"]);
    assert!(output.status.success(), "{text}");
    let files = git(&project, &["show", "--name-only", "--format=", "HEAD"]);
    assert!(
        files
            .lines()
            .any(|path| path == ".github/copilot-instructions.md"),
        "the bot surface was absent from the CLI commit:\n{files}"
    );
    assert_eq!(
        git(&project, &["show", "HEAD:./AGENTS.md"]),
        "# App\n\nbase user text\n\n## Code Review Rules\n\nnew generated rules\n\n## Notes\n\nbase note\n"
    );
    assert_eq!(
        fs::read_to_string(project.join("AGENTS.md")).unwrap(),
        "# App\n\nworking user text\n\n## Code Review Rules\n\nnew generated rules\n\n## Notes\n\nworking note\n"
    );
}

/// The CLI prints the setup step after a successful unarmed apply. The
/// package script leaves a sentinel if it runs, so this also proves that the
/// output did not come from executing untrusted package code.
#[test]
fn an_unarmed_cli_apply_succeeds_names_setup_and_runs_no_package_code() {
    let tmp = tempfile::tempdir().unwrap();
    let home = rooted(&tmp);
    let project = project(&tmp);
    let script = project.join(".agents/skills/bot-instructions/scripts/bot-instructions");
    executable(
        &script,
        "#!/bin/sh\nprintf ran > .bot-instructions-ran\necho 'wrote .github/copilot-instructions.md'\n",
    );
    fs::write(
        project.join(".agents/skills/bot-instructions/SKILL.md"),
        "---\nname: bot-instructions\ndescription: fixture\nrepo-effects:\n  summary: fixture render\n  writes: ['.github/copilot-instructions.md']\n  installer: scripts/bot-instructions render\n  checker: scripts/bot-instructions check\n---\n",
    )
    .unwrap();
    git(&project, &["add", "-A"]);
    git(&project, &["commit", "-q", "-m", "bot package"]);
    let scope = kendex_core::model::Scope::Project {
        root: project.clone(),
    };
    let env = kendex_core::env::Env::fake(&home, kendex_core::env::FakeOs::Linux);
    let package = project.join(".agents/skills/bot-instructions");
    let mut lock = kendex_core::lock::Lock {
        version: kendex_core::lock::LOCK_VERSION,
        ..kendex_core::lock::Lock::default()
    };
    lock.entries.insert(
        kendex_core::lock::entry_key(
            kendex_core::model::ItemKind::Skill,
            "bot-instructions",
            kendex_core::model::HarnessId::Codex,
        ),
        kendex_core::lock::LockEntry {
            name: "bot-instructions".to_owned(),
            kind: kendex_core::model::ItemKind::Skill,
            harness: kendex_core::model::HarnessId::Codex,
            source: "local".to_owned(),
            source_repo: "local".to_owned(),
            machine: Some(kendex_core::lock::MachineRecord {
                method: kendex_core::manifest::Method::Copy,
                installed_at: "2026-09-20T00:00:00Z".to_owned(),
            }),
            source_hash: "fixture".to_owned(),
            source_commit: None,
            rendered_hash: Some("fixture".to_owned()),
            enabled: true,
            upstream_skills: None,
            emitted: Some(kendex_core::lock::EmittedArtifact {
                kind: kendex_core::model::ItemKind::Skill,
                name: "bot-instructions".to_owned(),
                paths: vec![package],
            }),
            registration: None,
            reasons: std::collections::BTreeSet::from([kendex_core::lock::Reason::Requested]),
        },
    );
    kendex_core::lock::save(&kendex_core::lock::lock_path(&env, &scope), &lock).unwrap();

    let (output, text) = apply(&home, &project, &["--leave"]);

    assert!(output.status.success(), "{text}");
    assert!(
        text.contains("use Set up on the bot-instructions package page"),
        "the CLI dropped the setup guidance: {text}"
    );
    assert!(
        !project.join(".bot-instructions-ran").exists(),
        "the unarmed CLI apply executed package code"
    );
}

/// A flag naming a choice a precondition removed refuses with that
/// precondition's reason, commits nothing, and exits 1; the verb's writes
/// still stand.
#[test]
fn a_flag_naming_a_choice_not_on_offer_is_refused_with_the_reason() {
    let tmp = tempfile::tempdir().unwrap();
    let home = rooted(&tmp);
    let project = project(&tmp);
    let (output, text) = apply(&home, &project, &["--push"]);
    assert_eq!(output.status.code(), Some(1), "{text}");
    assert!(
        text.contains("no push: this repository has no remote"),
        "{text}"
    );
    assert_eq!(head_subject(&project), "files");
    assert!(
        project.join("CLAUDE.md").exists(),
        "the write did not stand"
    );

    let (output, text) = apply(&home, &project, &["--pull-request"]);
    assert_eq!(output.status.code(), Some(1), "{text}");
    assert!(
        text.contains("no pull request: this repository has no remote"),
        "{text}"
    );

    origin(&project, "open-origin");
    let (output, text) = apply(&home, &project, &["--pull-request"]);
    assert_eq!(output.status.code(), Some(1), "{text}");
    assert!(
        text.contains("no pull request: pull request #41 is already open for this branch"),
        "{text}"
    );
    assert_eq!(head_subject(&project), "files");
}

/// The push route lands on the chosen remote, and a remote that refuses
/// is quoted whole with the commit named and left where it is.
#[test]
fn the_push_flag_pushes_or_reports_the_remotes_refusal() {
    let tmp = tempfile::tempdir().unwrap();
    let home = rooted(&tmp);
    let project = project(&tmp);
    let bare = origin(&project, "plain-origin");
    let (output, text) = apply(&home, &project, &["--push"]);
    assert!(output.status.success(), "{text}");
    assert!(text.contains("committed 2 files as "), "{text}");
    assert!(text.contains("pushed to origin/main"), "{text}");
    assert!(
        text.contains(" · committed and pushed 2 files"),
        "no ledger part: {text}"
    );
    assert_eq!(
        git(&project, &["rev-parse", "HEAD"]),
        git(&project, &["rev-parse", "origin/main"])
    );

    drop(bare);
    // A fresh checkout whose remote refuses the push: the commit stands
    // and the remote's words are quoted.
    let tmp = tempfile::tempdir().unwrap();
    let home = rooted(&tmp);
    let project = self::project(&tmp);
    let bare = origin(&project, "plain-origin");
    executable(
        &bare.join("hooks/pre-receive"),
        "#!/bin/sh\necho 'GH006: Protected branch update failed for refs/heads/main.' >&2\nexit 1\n",
    );
    let before = git(&project, &["rev-parse", "HEAD"]);
    let (output, text) = apply(&home, &project, &["--push"]);
    assert_eq!(output.status.code(), Some(1), "{text}");
    assert!(text.contains("committed 2 files as "), "{text}");
    assert!(text.contains("the push was refused"), "{text}");
    assert!(text.contains("git said:"), "{text}");
    assert!(
        text.contains("GH006: Protected branch update failed"),
        "{text}"
    );
    assert!(
        text.contains("the commit is on main in this checkout; kendex did not undo it"),
        "{text}"
    );
    assert!(
        text.contains(" · committed, not pushed"),
        "no ledger part: {text}"
    );
    assert_ne!(
        git(&project, &["rev-parse", "HEAD"]),
        before,
        "the commit was undone"
    );
}

/// The pull-request route: a branch of its own, the commit, the push, the
/// pull request, and the checkout left on the branch; a `gh` that refuses
/// is quoted and the branch named for the person to open it themselves.
#[test]
fn the_pull_request_flag_opens_one_or_names_the_branch_gh_refused() {
    let tmp = tempfile::tempdir().unwrap();
    let home = rooted(&tmp);
    let project = project(&tmp);
    origin(&project, "plain-origin");
    let (output, text) = apply(&home, &project, &["--pull-request"]);
    assert!(output.status.success(), "{text}");
    assert!(text.contains("committed 2 files as "), "{text}");
    assert!(text.contains(" on kendex/renders"), "{text}");
    assert!(text.contains("pushed to origin/kendex/renders"), "{text}");
    assert!(
        text.contains("opened https://github.com/acme/site/pull/41"),
        "{text}"
    );
    assert!(
        text.contains("this checkout is now on kendex/renders"),
        "{text}"
    );
    assert!(
        text.contains(" · committed 2 files, pull request open"),
        "no ledger part: {text}"
    );
    assert!(home.join("fake-bin/calls").exists(), "gh was never asked");
    assert_eq!(
        git(&project, &["symbolic-ref", "--short", "HEAD"]).trim(),
        "kendex/renders"
    );
    assert_eq!(
        git(&project, &["rev-parse", "main"]),
        git(&project, &["rev-parse", "origin/main"]),
        "main gained the commit"
    );

    let refusing = tempfile::tempdir().unwrap();
    let home = rooted(&refusing);
    let project = self::project(&refusing);
    origin(&project, "refuse-origin");
    let (output, text) = apply(&home, &project, &["--pull-request"]);
    assert_eq!(output.status.code(), Some(1), "{text}");
    assert!(text.contains("pushed to origin/kendex/renders"), "{text}");
    assert!(text.contains("the pull request was refused"), "{text}");
    assert!(text.contains("gh said:"), "{text}");
    assert!(
        text.contains("GitHub Actions is not permitted to create or approve pull requests"),
        "{text}"
    );
    assert!(
        text.contains("the branch kendex/renders is on origin; open the pull request yourself"),
        "{text}"
    );
    assert!(
        text.contains(" · committed and pushed, no pull request"),
        "no ledger part: {text}"
    );
}

/// A hook's refusal reaches the person whole, nothing is committed, and
/// the index ends as it began.
#[test]
fn a_hooks_refusal_is_quoted_whole_and_nothing_is_committed() {
    let tmp = tempfile::tempdir().unwrap();
    let home = rooted(&tmp);
    let project = project(&tmp);
    executable(
        &project.join(".git/hooks/pre-commit"),
        "#!/bin/sh\necho 'commit-msg: crates/ changed without a changelog entry' >&2\necho '  write one of: changelog.d/*/*.md' >&2\nexit 1\n",
    );
    let (output, text) = apply(&home, &project, &["--commit"]);
    assert_eq!(output.status.code(), Some(1), "{text}");
    assert!(text.contains("the commit was refused"), "{text}");
    assert!(text.contains("git said:"), "{text}");
    assert!(
        text.contains("commit-msg: crates/ changed without a changelog entry"),
        "{text}"
    );
    assert!(text.contains("write one of: changelog.d/*/*.md"), "{text}");
    assert_eq!(head_subject(&project), "files");
    assert!(text.contains(" · not committed"), "no ledger part: {text}");
    let status = git(&project, &["status", "--porcelain"]);
    assert!(status.contains("?? CLAUDE.md"), "still staged: {status}");

    // The same refusal through the other verb that closes on a ledger, in
    // a checkout it still has the shim to write: its own failure line, the
    // scope's ledger still closed, and never counted as a failure of the
    // verb.
    let tmp = tempfile::tempdir().unwrap();
    let home = rooted(&tmp);
    let project = self::project(&tmp);
    executable(
        &project.join(".git/hooks/pre-commit"),
        "#!/bin/sh\necho 'commit-msg: no' >&2\nexit 1\n",
    );
    let output = kendex(&home, &project, &["refresh", "--yes", "--commit"]);
    let text = said(&output);
    assert_eq!(output.status.code(), Some(1), "{text}");
    assert!(text.contains("the commit was refused"), "{text}");
    assert!(text.contains(" · not committed"), "no ledger line: {text}");
    assert!(!text.contains("refresh failed:"), "{text}");
    assert!(!text.contains("already said"), "{text}");
}

/// The two states the offer cannot be made in print one line each, and a
/// flag does not change that.
#[test]
fn a_detached_head_or_an_operation_in_progress_prints_one_line() {
    let tmp = tempfile::tempdir().unwrap();
    let home = rooted(&tmp);
    let project = project(&tmp);
    fs::write(project.join(".git/MERGE_HEAD"), "").unwrap();
    let (output, text) = apply(&home, &project, &["--commit"]);
    assert!(output.status.success(), "{text}");
    assert!(
        text.contains("2 files kendex wrote are not committed; a merge is in progress"),
        "{text}"
    );
    fs::remove_file(project.join(".git/MERGE_HEAD")).unwrap();

    let head = git(&project, &["rev-parse", "HEAD"]);
    git(&project, &["checkout", "-q", "--detach", head.trim()]);
    let (output, text) = apply(&home, &project, &["--commit"]);
    assert!(output.status.success(), "{text}");
    assert!(
        text.contains("2 files kendex wrote are not committed; this checkout is on no branch"),
        "{text}"
    );
    assert_eq!(head_subject(&project), "files");
}

/// A read the offer is built from that will not run leaves the offer
/// unbuildable: one line, git's words, and the verb's own exit.
#[test]
fn a_repository_git_cannot_read_says_the_files_could_not_be_checked() {
    let tmp = tempfile::tempdir().unwrap();
    let home = rooted(&tmp);
    let project = project(&tmp);
    fs::write(project.join(".git/HEAD"), "not a ref\n").unwrap();
    let (output, text) = apply(&home, &project, &["--commit"]);
    assert!(output.status.success(), "{text}");
    assert!(
        text.contains("the files kendex wrote could not be checked"),
        "{text}"
    );
    assert!(text.contains("git said:"), "{text}");
    assert!(text.contains("fatal:"), "{text}");
}

/// `commit-offer = "off"` turns off the asking, not the choices: no line
/// without a flag, and a flag still answers.
#[test]
fn the_setting_turns_off_the_asking_and_not_the_flags() {
    let tmp = tempfile::tempdir().unwrap();
    let home = rooted(&tmp);
    let project = project(&tmp);
    let settings = kendex_core::env::Env::host_rooted(&home).settings_file();
    fs::create_dir_all(settings.parent().unwrap()).unwrap();
    fs::write(&settings, "schema = 1\ncommit-offer = \"off\"\n").unwrap();
    let (output, text) = apply(&home, &project, &[]);
    assert!(output.status.success(), "{text}");
    assert!(!text.contains("not committed"), "{text}");
    let (output, text) = apply(&home, &project, &["--commit"]);
    assert!(output.status.success(), "{text}");
    assert!(text.contains("committed 2 files as "), "{text}");
}

/// Two of the group together is refused before the verb writes anything.
#[test]
fn two_answers_at_once_are_refused_before_the_write() {
    let tmp = tempfile::tempdir().unwrap();
    let home = rooted(&tmp);
    let project = project(&tmp);
    let (output, text) = apply(&home, &project, &["--commit", "--leave"]);
    assert!(!output.status.success(), "{text}");
    assert!(
        !project.join("CLAUDE.md").exists(),
        "the verb wrote before refusing"
    );
}

/// A verb that applies more than one report into the project: the first
/// report has nothing kendex owns changed and records no answer, so the
/// report that renders the hook still reaches the offer.
#[test]
fn a_verbs_later_report_still_reaches_the_offer() {
    let tmp = tempfile::tempdir().unwrap();
    let home = rooted(&tmp);
    let project = project(&tmp);
    let output = kendex(&home, &project, &["drift-hook", "--yes", "--commit"]);
    let text = said(&output);
    assert!(output.status.success(), "{text}");
    assert!(
        text.contains("committed "),
        "the hook's render was not offered: {text}"
    );
    assert_ne!(
        head_subject(&project),
        "files",
        "nothing was committed: {text}"
    );
}

/// The hosted close helper asks through the hidden machine command, so the
/// answer must be the same whole-file set the commit offer owns. A deletion
/// remains owned through the inventory committed before the current plan.
#[test]
fn generated_paths_reports_changed_and_removed_whole_file_renders() {
    let tmp = tempfile::tempdir().unwrap();
    let home = rooted(&tmp);
    let project = project(&tmp);
    let (output, text) = apply(&home, &project, &["--leave"]);
    assert!(output.status.success(), "{text}");
    let rendered = fs::read(project.join("CLAUDE.md")).unwrap();
    git(&project, &["add", "CLAUDE.md", ".kendex-generated.json"]);
    git(&project, &["commit", "-q", "-m", "renders"]);

    fs::write(project.join("CLAUDE.md"), "stale committed render\n").unwrap();
    git(&project, &["add", "CLAUDE.md"]);
    git(&project, &["commit", "-q", "-m", "stale render"]);
    fs::write(project.join("CLAUDE.md"), rendered).unwrap();
    let mut manifest = fs::read_to_string(project.join("kendex.toml")).unwrap();
    manifest.push_str("# person\n");
    fs::write(project.join("kendex.toml"), manifest).unwrap();
    let changed = kendex(&home, &project, &["generated-paths"]);
    assert!(changed.status.success(), "{}", said(&changed));
    assert_eq!(
        serde_json::from_slice::<Vec<String>>(&changed.stdout).unwrap(),
        ["CLAUDE.md"]
    );

    fs::remove_file(project.join("CLAUDE.md")).unwrap();
    let removed = kendex(&home, &project, &["generated-paths"]);
    assert!(removed.status.success(), "{}", said(&removed));
    assert_eq!(
        serde_json::from_slice::<Vec<String>>(&removed.stdout).unwrap(),
        ["CLAUDE.md"]
    );
}
