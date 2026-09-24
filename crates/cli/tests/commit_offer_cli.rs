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

/// A `gh` whose answers are chosen by the repository it was bound to:
/// `--repo`, or `GH_REPO` for `gh api`, which has no `--repo`. The
/// directory holds nothing but `gh`, so git resolves as before.
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
if [ "$1" = api ]; then
  host=github.com
  endpoint=""
  prev=""
  for a in "$@"; do
    if [ "$prev" = "--hostname" ]; then host="$a"; fi
    prev="$a"
    endpoint="$a"
  done
  # gh asks the host --hostname names about the path GH_REPO names, so a
  # repository on another host is one this host does not have.
  repo_host=$(printf '%s' "$GH_REPO" | sed -e 's#^[a-z]*://##' -e 's#^[^@/]*@##' -e 's#[:/].*##')
  if [ "$repo_host" = "$host" ]; then
    case "$GH_REPO $endpoint" in
      *bypass*/rulesets/7) echo '{"current_user_can_bypass":"always"}'; exit 0;;
      *ruled*/rulesets/7) echo '{"current_user_can_bypass":"never"}'; exit 0;;
      *ruled*/rules/branches/main) echo '[{"type":"deletion","ruleset_id":7},{"type":"pull_request","ruleset_id":7}]'; exit 0;;
    esac
  fi
  echo 'gh: Not Found (HTTP 404)' >&2; exit 1
fi
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

/// A project whose root `AGENTS.md` carries a managed region the installed
/// bot-instructions fixture renders, with the package armed and locked so
/// an apply runs it: the body the last commit holds, then the body the
/// person left in the worktree.
///
/// The fixture answers `region-bounds` by calling the shipped launcher, so
/// no fixture carries a second copy of the bounds rule.
#[allow(clippy::unwrap_used)]
fn region_project(tmp: &tempfile::TempDir, committed: &str, working: &str) -> PathBuf {
    let home = rooted(tmp);
    let project = project(tmp);
    let script = project.join(".agents/skills/bot-instructions/scripts/bot-instructions");
    executable(
        &script,
        &format!(
            "#!/bin/sh\nif [ \"$1\" = region-bounds ]; then\n  exec '{PACKAGE_LAUNCHER}' \"$@\"\nfi\nmkdir -p .github\nprintf 'updated review rules\\n' > .github/copilot-instructions.md\nif ! grep -q 'old generated rules' AGENTS.md; then\n  echo 'fixture-render: AGENTS.md has no generated rules' >&2\n  exit 1\nfi\nsed 's/old generated rules/new generated rules/' AGENTS.md > AGENTS.md.rendered && mv AGENTS.md.rendered AGENTS.md || exit 1\necho 'wrote .github/copilot-instructions.md'\nprintf 'wrote region AGENTS.md\\t## Code Review Rules\\n'\n"
        ),
    );
    fs::write(project.join("AGENTS.md"), committed).unwrap();
    fs::write(
        project.join(".agents/skills/bot-instructions/SKILL.md"),
        "---\nname: bot-instructions\ndescription: fixture\nrepo-effects:\n  summary: fixture render\n  writes: ['.github/copilot-instructions.md']\n  installer: scripts/bot-instructions render\n  checker: scripts/bot-instructions check\n---\n",
    )
    .unwrap();
    git(&project, &["add", "-A"]);
    git(&project, &["commit", "-q", "-m", "bot package"]);
    fs::write(project.join("AGENTS.md"), working).unwrap();
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
    project
}

/// The CLI apply door runs the installed bot renderer before it builds the
/// commit offer, so the same commit carries the engine and package outputs.
#[test]
fn apply_renders_and_commits_the_bot_instruction_surface() {
    let tmp = tempfile::tempdir().unwrap();
    let home = rooted(&tmp);
    let project = region_project(
        &tmp,
        "# App\n\nbase user text\n\n## Code Review Rules\n\nold generated rules\n\n## Notes\n\nbase note\n",
        "# App\n\nworking user text\n\n## Code Review Rules\n\nold generated rules\n\n## Notes\n\nworking note\n",
    );

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

/// A bare repository the project calls `origin` under a hosted URL:
/// `git remote get-url` answers `url`, which every `gh` call is bound to,
/// and the push reaches the bare repository through `pushInsteadOf`.
#[allow(clippy::unwrap_used)]
fn hosted_origin(project: &Path, url: &str) -> PathBuf {
    let name = url.rsplit('/').next().unwrap();
    let bare = project.parent().unwrap().join(name);
    let path = bare.to_string_lossy();
    git(project, &["init", "-q", "--bare", "-b", "main", &path]);
    git(project, &["remote", "add", "origin", url]);
    git(
        project,
        &["config", &format!("url.{path}.pushInsteadOf"), url],
    );
    git(project, &["push", "-q", "-u", "origin", "main"]);
    bare
}

/// One run of the rules test: the remote and the refusal it answers with,
/// the flag, and what the run must and must not say.
struct RulesRow {
    what: &'static str,
    remote: &'static str,
    /// A pre-receive hook on the remote, refusing the way GitHub does.
    refuses: &'static str,
    flag: &'static str,
    exit: i32,
    committed: bool,
    says: &'static [&'static str],
    not: &'static [&'static str],
}

const PR_RULE: &str = "echo 'error: GH013: Repository rule violations found for refs/heads/main.' >&2\necho '- Changes must be made through a pull request.' >&2\nexit 1\n";
const PUSH_PROTECTION: &str = "echo 'error: GH013: Repository rule violations found for refs/heads/main.' >&2\necho '- GITHUB PUSH PROTECTION' >&2\necho '  - Push cannot contain secrets' >&2\nexit 1\n";
const HINT: &str = "run again with --pull-request to commit on a new branch and open one";
const RULES_LINE: &str = "main on origin accepts changes only through a pull request";

fn rules_rows() -> [RulesRow; 8] {
    [
        RulesRow {
            what: "rules that take a pull request",
            remote: "https://github.com/acme/ruled-origin.git",
            refuses: "",
            flag: "--push",
            exit: 1,
            committed: false,
            says: &[
                "no push: this branch's rules on GitHub accept changes only through a pull request",
                HINT,
            ],
            not: &[],
        },
        RulesRow {
            what: "the same rules with a pull request already open",
            remote: "https://github.com/acme/open-ruled-origin.git",
            refuses: "",
            flag: "--push",
            exit: 1,
            committed: false,
            says: &[
                "no push: this branch's rules on GitHub accept changes only through a pull request",
            ],
            not: &[HINT],
        },
        RulesRow {
            what: "the route those rules allow",
            remote: "https://github.com/acme/ruled-origin.git",
            refuses: "",
            flag: "--pull-request",
            exit: 0,
            committed: true,
            says: &["opened https://github.com/acme/site/pull/41"],
            not: &[],
        },
        RulesRow {
            what: "rules on an Enterprise host",
            remote: "https://ghe.example.test/acme/ruled-origin.git",
            refuses: "",
            flag: "--push",
            exit: 1,
            committed: false,
            says: &[
                "no push: this branch's rules on GitHub accept changes only through a pull request",
            ],
            not: &[],
        },
        RulesRow {
            what: "a person the ruleset lets past",
            remote: "https://github.com/acme/bypass-ruled-origin.git",
            refuses: "",
            flag: "--push",
            exit: 0,
            committed: true,
            says: &["pushed to origin/main"],
            not: &[],
        },
        RulesRow {
            what: "rules that cannot be read",
            remote: "https://github.com/acme/plain-origin.git",
            refuses: "",
            flag: "--push",
            exit: 0,
            committed: true,
            says: &["pushed to origin/main"],
            not: &[],
        },
        RulesRow {
            what: "GitHub refusing the push for want of a pull request",
            remote: "https://u:secret@github.com/acme/plain-origin.git",
            refuses: PR_RULE,
            flag: "--push",
            exit: 1,
            committed: true,
            says: &[
                "remote: error: GH013: Repository rule violations found for refs/heads/main.",
                "the commit is on main in this checkout; kendex did not undo it",
                RULES_LINE,
                "to open one from this commit yourself:",
                "    git 'push' 'origin' 'HEAD:refs/heads/kendex/renders'",
                "'--repo' 'https://github.com/acme/plain-origin.git' '--head' 'kendex/renders' '--base' 'main' '--title' 'chore: kendex apply'",
            ],
            not: &["secret"],
        },
        RulesRow {
            what: "GitHub refusing the push for another rule",
            remote: "https://github.com/acme/plain-origin.git",
            refuses: PUSH_PROTECTION,
            flag: "--push",
            exit: 1,
            committed: true,
            says: &["GITHUB PUSH PROTECTION"],
            not: &[RULES_LINE, "git 'push'"],
        },
    ]
}

/// The branch's rules decide the push before anything is committed. Rules
/// that take changes only through a pull request refuse `--push`, naming
/// the flag for the route they allow where it is on offer, and that route
/// opens one; a person the ruleset lets past pushes; rules that cannot be
/// read leave the push as it was. The read is bound to the remote's host.
/// A push GitHub then refuses for want of a pull request prints the
/// commands that open one from the commit, without the remote's
/// credentials; any other refusal prints neither.
#[test]
fn the_branch_rules_are_read_before_a_push_and_a_refusal_under_them_names_the_way_on() {
    for row in rules_rows() {
        let tmp = tempfile::tempdir().unwrap();
        let home = rooted(&tmp);
        let project = project(&tmp);
        let bare = hosted_origin(&project, row.remote);
        if !row.refuses.is_empty() {
            executable(
                &bare.join("hooks/pre-receive"),
                &format!("#!/bin/sh\n{}", row.refuses),
            );
        }
        let (output, text) = apply(&home, &project, &[row.flag]);
        assert_eq!(output.status.code(), Some(row.exit), "{}: {text}", row.what);
        for line in row.says {
            assert!(text.contains(line), "{}: {line}: {text}", row.what);
        }
        for line in row.not {
            assert!(!text.contains(line), "{}: {line}: {text}", row.what);
        }
        assert_eq!(
            head_subject(&project) != "files",
            row.committed,
            "{}: {text}",
            row.what
        );
        let host = row.remote.rsplit('@').next().unwrap();
        let host = host
            .trim_start_matches("https://")
            .split('/')
            .next()
            .unwrap();
        let asked = fs::read_to_string(home.join("fake-bin/calls")).unwrap_or_default();
        assert!(
            asked.contains(&format!(
                "api --hostname {host} repos/{{owner}}/{{repo}}/rules/branches/main"
            )),
            "{}: the rules were not read from {host}: {asked}",
            row.what
        );
    }
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
    for case in ["changed", "removed"] {
        let tmp = tempfile::tempdir().unwrap();
        let home = rooted(&tmp);
        let project = project(&tmp);
        let (output, text) = apply(&home, &project, &["--leave"]);
        assert!(output.status.success(), "{case}: {text}");
        let rendered = fs::read(project.join("CLAUDE.md")).unwrap();
        git(&project, &["add", "CLAUDE.md", ".kendex-generated.json"]);
        git(&project, &["commit", "-q", "-m", "renders"]);
        match case {
            "changed" => {
                fs::write(project.join("CLAUDE.md"), "stale committed render\n").unwrap();
                git(&project, &["add", "CLAUDE.md"]);
                git(&project, &["commit", "-q", "-m", "stale render"]);
                fs::write(project.join("CLAUDE.md"), rendered).unwrap();
            }
            "removed" => fs::remove_file(project.join("CLAUDE.md")).unwrap(),
            _ => unreachable!(),
        }
        let result = kendex(&home, &project, &["generated-paths"]);
        assert!(result.status.success(), "{case}: {}", said(&result));
        assert_eq!(
            serde_json::from_slice::<Vec<String>>(&result.stdout).unwrap(),
            ["CLAUDE.md"],
            "{case}"
        );
    }
}

/// `generated-paths` names only what kendex owns whole. Its consumer
/// restores every name it is given whole, and a file kendex owns one
/// region of carries the person's own bytes outside that region.
///
/// The region is a real one: the installed package renders it and the
/// apply commits it region-wise. The verb's set comes from the engine's
/// plan, which carries no region, so the row holds whether the region
/// alone changed or the person also edited around it.
#[test]
#[allow(clippy::unwrap_used)]
fn generated_paths_omits_a_file_kendex_owns_only_a_region_of() {
    for case in ["mixed", "region-only"] {
        let tmp = tempfile::tempdir().unwrap();
        let home = rooted(&tmp);
        let project = region_project(
            &tmp,
            "# App\n\nbase user text\n\n## Code Review Rules\n\nold generated rules\n\n## Notes\n\nbase note\n",
            "# App\n\nbase user text\n\n## Code Review Rules\n\nold generated rules\n\n## Notes\n\nbase note\n",
        );
        let (output, text) = apply(&home, &project, &["--commit"]);
        assert!(output.status.success(), "{case}: {text}");
        // The whole-file render this row expects to see reported: the
        // commit is given stale bytes while the worktree keeps the
        // rendered ones, so git calls the path changed and the shim itself
        // stays in sync.
        let rendered = fs::read(project.join("CLAUDE.md")).unwrap();
        fs::write(project.join("CLAUDE.md"), "stale committed render\n").unwrap();
        git(&project, &["add", "CLAUDE.md"]);
        git(&project, &["commit", "-q", "-m", "stale render"]);
        fs::write(project.join("CLAUDE.md"), rendered).unwrap();
        // The region differs from the commit in both rows; the mixed row
        // also carries a user edit outside it, which is the case a
        // whole-file restore would throw away.
        let edited = match case {
            "mixed" => {
                "# App\n\nworking user text\n\n## Code Review Rules\n\nhand-edited rules\n\n## Notes\n\nbase note\n"
            }
            _ => {
                "# App\n\nbase user text\n\n## Code Review Rules\n\nhand-edited rules\n\n## Notes\n\nbase note\n"
            }
        };
        fs::write(project.join("AGENTS.md"), edited).unwrap();
        let result = kendex(&home, &project, &["generated-paths"]);
        assert!(result.status.success(), "{case}: {}", said(&result));
        assert_eq!(
            serde_json::from_slice::<Vec<String>>(&result.stdout).unwrap(),
            ["CLAUDE.md"],
            "{case}"
        );
    }
}
