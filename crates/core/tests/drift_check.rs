//! The drift report agents wake up to, end to end: held-ness derives from
//! the effective installation graph, evaluation failures surface instead of
//! reading as current, the snapshot carries the deep pass's verdicts, and
//! the session-start hook script honors its contract.
#![cfg(unix)]

use std::fs;
use std::path::{Path, PathBuf};

use kendex_core::apply;
use kendex_core::drift;
use kendex_core::engine::audit;
use kendex_core::env::{Env, FakeOs};
use kendex_core::manifest;
use kendex_core::model::Scope;
use kendex_core::package::updates;
use kendex_core::process::Hardened;
use kendex_core::remote;

const REPO: &str = "owner/catalog";

struct World {
    _tmp: tempfile::TempDir,
    env: Env,
    upstream: PathBuf,
    scope: Scope,
}

#[allow(clippy::unwrap_used)]
fn git(dir: &Path, args: &[&str]) {
    let output = Hardened::git(args, Some(dir)).run().unwrap();
    assert!(output.status.success(), "git {args:?}");
}

#[allow(clippy::unwrap_used)]
fn commit(dir: &Path, message: &str) -> String {
    git(dir, &["add", "-A"]);
    git(
        dir,
        &[
            "-c",
            "user.email=t@t",
            "-c",
            "user.name=t",
            "commit",
            "--quiet",
            "-m",
            message,
        ],
    );
    let output = Hardened::git(&["rev-parse", "HEAD"], Some(dir))
        .run()
        .unwrap();
    String::from_utf8_lossy(&output.stdout).trim().to_owned()
}

#[allow(clippy::unwrap_used)]
fn write_skill(dir: &Path, name: &str, body: &str) {
    write_skill_with(dir, name, body, "");
}

#[allow(clippy::unwrap_used)]
fn write_skill_with(dir: &Path, name: &str, body: &str, extra_frontmatter: &str) {
    let skill = dir.join("skills").join(name);
    fs::create_dir_all(&skill).unwrap();
    fs::write(
        skill.join("SKILL.md"),
        format!("---\nname: {name}\ndescription: about {name}\n{extra_frontmatter}---\n{body}\n"),
    )
    .unwrap();
}

#[allow(clippy::unwrap_used)]
fn world() -> World {
    let tmp = tempfile::tempdir().unwrap();
    // Canonical up front: macOS reaches its temp dirs through a symlink,
    // and the engine hands back canonical paths.
    let home = tmp.path().canonicalize().unwrap();
    let upstream = home.join("git").join(REPO);
    fs::create_dir_all(&upstream).unwrap();
    git(&upstream, &["init", "--quiet", "-b", "main"]);
    fs::create_dir_all(home.join(".claude")).unwrap();
    fs::create_dir_all(home.join("app/.claude")).unwrap();
    let base = format!("file://{}", home.join("git").display());
    World {
        env: Env::fake(&home, FakeOs::Linux).with_var("KENDEX_GIT_BASE", &base),
        scope: Scope::Project {
            root: home.join("app"),
        },
        upstream,
        _tmp: tmp,
    }
}

#[allow(clippy::unwrap_used)]
fn declare(w: &World, source_extra: &str, body: &str) {
    let path = manifest::manifest_path(&w.env, &w.scope);
    fs::create_dir_all(path.parent().unwrap()).unwrap();
    fs::write(
        &path,
        format!(
            "schema = 6\n\n[sources.cat]\nrepo = \"{REPO}\"\n{source_extra}\n[install]\nharnesses = [\"claude\"]\nmethod = \"symlink\"\n\n{body}"
        ),
    )
    .unwrap();
}

#[allow(clippy::unwrap_used)]
fn sync_and_apply(w: &World) {
    let loaded = manifest::load_for_mutation(&manifest::manifest_path(&w.env, &w.scope))
        .unwrap()
        .unwrap();
    remote::sync_sources(&w.env, &loaded).unwrap();
    let report = audit(&w.env, &w.scope).unwrap();
    apply::execute(&w.env, &report.plan).unwrap();
}

#[allow(clippy::unwrap_used)]
fn row<'a>(rows: &'a [updates::UpdateRow], name: &str) -> &'a updates::UpdateRow {
    rows.iter()
        .find(|row| row.name == name)
        .unwrap_or_else(|| panic!("no row for {name}: {rows:?}"))
}

/// A commit pin is a hold on everything it reaches, one row per route: a
/// source-level pin holds every package the source carries; a pinned
/// bundle holds its members; a pinned parent holds its dependencies. Each
/// row: what the upstream holds, the source's extra lines, the declaration
/// (both given the first commit), and the package the report must hold.
/// The control follows the first row: a tracking selector is not a pin, so
/// the same declaration on a branch name follows and must not read as held.
#[test]
#[allow(clippy::unwrap_used)]
fn a_commit_pin_holds_every_package_it_reaches() {
    type Upstream = fn(&Path);
    type Declare = fn(&str) -> (String, String);
    let rows: [(&str, Upstream, Declare, &str); 3] = [
        (
            "a source-level pin",
            |upstream| write_skill(upstream, "gh", "One."),
            |first| {
                (
                    format!("rev = \"{first}\"\n"),
                    "[skills.gh]\nsource = \"cat\"\n".to_owned(),
                )
            },
            "gh",
        ),
        (
            "a pinned bundle",
            |upstream| {
                write_skill(upstream, "member", "One.");
                fs::write(
                    upstream.join("kendex.toml"),
                    "[bundles.kit]\ndescription = \"a set\"\nskills = [\"member\"]\n",
                )
                .unwrap();
            },
            |first| {
                (
                    String::new(),
                    format!("[bundles.kit]\nsource = \"cat\"\nrev = \"{first}\"\n"),
                )
            },
            "member",
        ),
        (
            "a pinned parent",
            |upstream| {
                write_skill(upstream, "dep", "Dep.");
                write_skill_with(
                    upstream,
                    "parent",
                    "Parent.",
                    "dependencies:\n  required: [dep]\n",
                );
            },
            |first| {
                (
                    String::new(),
                    format!("[skills.parent]\nsource = \"cat\"\nrev = \"{first}\"\n"),
                )
            },
            "dep",
        ),
    ];
    for (what, upstream, declaration, held) in rows {
        let w = world();
        upstream(&w.upstream);
        let first = commit(&w.upstream, "one");
        let (source_extra, declared) = declaration(&first);
        declare(&w, &source_extra, &declared);
        sync_and_apply(&w);

        let report = updates::updates(&w.env, &w.scope).unwrap();
        assert!(row(&report.rows, held).pinned, "{what}: {report:?}");
    }

    let w = world();
    write_skill(&w.upstream, "gh", "One.");
    commit(&w.upstream, "one");
    declare(&w, "rev = \"main\"\n", "[skills.gh]\nsource = \"cat\"\n");
    sync_and_apply(&w);
    let report = updates::updates(&w.env, &w.scope).unwrap();
    assert!(
        !row(&report.rows, "gh").pinned,
        "a tracking selector is not a pin: {report:?}"
    );
}

/// The Updates page says how old its answer is, so the fetch that produced
/// it has to reach the report: the stamp a check writes comes back out of
/// `updates`, and a scope nothing has fetched says so rather than passing
/// off an unchecked standing as a fresh one.
#[test]
#[allow(clippy::unwrap_used)]
fn the_report_carries_when_its_mirrors_were_last_fetched() {
    let w = world();
    write_skill(&w.upstream, "gh", "One.");
    commit(&w.upstream, "one");
    declare(&w, "", "[skills.gh]\nsource = \"cat\"\n");

    assert_eq!(
        updates::updates(&w.env, &w.scope).unwrap().last_fetched,
        None,
        "nothing has fetched yet: the scope has never been checked"
    );

    sync_and_apply(&w);
    // The check the Updates page runs, on the same manifest the command
    // hands it.
    let before = u32::try_from(kendex_core::clock::unix_now()).unwrap();
    let loaded = manifest::load_for_mutation(&manifest::manifest_path(&w.env, &w.scope))
        .unwrap()
        .unwrap();
    assert!(remote::fetch_all(&w.env, &loaded).is_empty());

    let at = updates::updates(&w.env, &w.scope)
        .unwrap()
        .last_fetched
        .expect("the fetch a check just ran is what the page dates its answer from");
    assert!(
        at >= before,
        "the report dates from this check, not an older one: {at} < {before}"
    );
}

/// The report narrows the stamp to `u32` to cross the IPC boundary. A value
/// that does not fit — past 2106, or a clock that ran far forward — has to
/// read as never checked: wrapping it would put a plausible-looking wrong
/// instant under rows nobody has verified.
#[test]
#[allow(clippy::unwrap_used)]
fn a_stamp_too_large_to_report_reads_as_never_checked() {
    let w = world();
    write_skill(&w.upstream, "gh", "One.");
    commit(&w.upstream, "one");
    declare(&w, "", "[skills.gh]\nsource = \"cat\"\n");
    sync_and_apply(&w);
    assert!(updates::updates(&w.env, &w.scope).unwrap().last_fetched > Some(0));

    let key = remote::cache_key(&w.env, REPO);
    drift::stamps::record_success(&w.env, &key, None, u64::from(u32::MAX) + 1).unwrap();
    assert_eq!(
        updates::updates(&w.env, &w.scope).unwrap().last_fetched,
        None,
        "a stamp the report cannot carry is refused, never wrapped"
    );
}

#[test]
#[allow(clippy::unwrap_used)]
fn a_package_gone_from_its_source_is_a_fact_not_a_silent_skip() {
    let w = world();
    write_skill(&w.upstream, "gh", "One.");
    commit(&w.upstream, "one");
    declare(&w, "", "[skills.gh]\nsource = \"cat\"\n");
    sync_and_apply(&w);

    fs::remove_dir_all(w.upstream.join("skills/gh")).unwrap();
    commit(&w.upstream, "gone");
    let loaded = manifest::load_for_mutation(&manifest::manifest_path(&w.env, &w.scope))
        .unwrap()
        .unwrap();
    remote::sync_sources(&w.env, &loaded).unwrap();

    let report = updates::updates(&w.env, &w.scope).unwrap();
    assert!(row(&report.rows, "gh").removed_upstream, "{report:?}");
}

#[test]
#[allow(clippy::unwrap_used)]
fn an_unreadable_history_is_a_warning_never_current() {
    let w = world();
    write_skill(&w.upstream, "gh", "One.");
    commit(&w.upstream, "one");
    declare(&w, "", "[skills.gh]\nsource = \"cat\"\n");
    sync_and_apply(&w);

    // A recorded commit the mirror does not hold — a force-pushed source,
    // or a hand-edited lock — makes the installed version unreadable.
    let lock_path = kendex_core::lock::lock_path(&w.env, &w.scope);
    let mut lock = kendex_core::lock::load(&lock_path).unwrap();
    for entry in lock.entries.values_mut() {
        entry.source_commit = Some("f".repeat(40));
    }
    kendex_core::lock::save(&lock_path, &lock).unwrap();

    let report = updates::updates(&w.env, &w.scope).unwrap();
    let gh = row(&report.rows, "gh");
    assert_eq!(
        (gh.current.as_ref(), gh.update_available),
        (None, false),
        "an unevaluable installed version keeps its row and claims no verdict: {report:?}"
    );
    assert!(
        gh.latest.is_some(),
        "the mirror's own history still renders"
    );
    assert!(
        report.warnings.iter().any(|warning| warning.name == "gh"),
        "the failure surfaces as a warning: {report:?}"
    );

    // And the snapshot carries it into the session check as could-not-check.
    drift::snapshot::record(&w.env, &w.scope).unwrap();
    let checked = drift::report::check(&w.env, std::slice::from_ref(&w.scope));
    assert_eq!(
        checked.status,
        drift::report::CheckStatus::Unknown,
        "{checked:?}"
    );
}

#[test]
#[allow(clippy::unwrap_used)]
fn the_snapshot_carries_stale_and_holding_silences_it() {
    let w = world();
    write_skill(&w.upstream, "gh", "One.");
    let first = commit(&w.upstream, "one");
    declare(&w, "", "[skills.gh]\nsource = \"cat\"\n");
    sync_and_apply(&w);

    write_skill(&w.upstream, "gh", "Two.");
    commit(&w.upstream, "two");
    let loaded = manifest::load_for_mutation(&manifest::manifest_path(&w.env, &w.scope))
        .unwrap()
        .unwrap();
    remote::sync_sources(&w.env, &loaded).unwrap();

    drift::snapshot::record(&w.env, &w.scope).unwrap();
    let checked = drift::report::check(&w.env, std::slice::from_ref(&w.scope));
    assert_eq!(checked.status, drift::report::CheckStatus::Drift);
    let text = drift::report::render_plain(&checked);
    assert!(text.contains("'gh' has a newer version"), "{text}");
    assert!(text.contains("fix: kendex refresh"), "{text}");

    // Hold it: the same drift goes quiet, because a hold is a decision.
    declare(
        &w,
        "",
        &format!("[skills.gh]\nsource = \"cat\"\nrev = \"{first}\"\n"),
    );
    drift::snapshot::record(&w.env, &w.scope).unwrap();
    let checked = drift::report::check(&w.env, std::slice::from_ref(&w.scope));
    assert_eq!(
        checked.status,
        drift::report::CheckStatus::Clean,
        "{checked:?}"
    );
    assert_eq!(drift::report::render_plain(&checked), "");
}

#[test]
#[allow(clippy::unwrap_used)]
fn installations_disagreeing_on_their_commit_read_as_mixed() {
    let w = world();
    write_skill(&w.upstream, "gh", "One.");
    commit(&w.upstream, "one");
    declare(&w, "", "[skills.gh]\nsource = \"cat\"\n");
    sync_and_apply(&w);
    write_skill(&w.upstream, "gh", "Two.");
    let second = commit(&w.upstream, "two");
    let loaded = manifest::load_for_mutation(&manifest::manifest_path(&w.env, &w.scope))
        .unwrap()
        .unwrap();
    remote::sync_sources(&w.env, &loaded).unwrap();

    // Two installations of one package recorded at different commits —
    // mid-apply state, or a partial refresh.
    let lock_path = kendex_core::lock::lock_path(&w.env, &w.scope);
    let mut lock = kendex_core::lock::load(&lock_path).unwrap();
    let mut cloned = None;
    for (key, entry) in lock.entries.iter() {
        if entry.name == "gh" {
            let mut other = entry.clone();
            other.harness = kendex_core::model::HarnessId::Codex;
            other.source_commit = Some(second.clone());
            cloned = Some((key.replace("claude", "codex"), other));
        }
    }
    let (key, entry) = cloned.unwrap();
    lock.entries.insert(key, entry);
    kendex_core::lock::save(&lock_path, &lock).unwrap();

    let report = updates::updates(&w.env, &w.scope).unwrap();
    assert!(row(&report.rows, "gh").mixed, "{report:?}");
}

/// A copy of a remote package that no record accounts for is measured
/// against the render at the commit its source resolved, and the line
/// names that commit: a render some commits behind reads as stale by the
/// count, never as a configuration note. The copy that matches is recorded
/// at that commit, so the next deep pass reads it as current — and the
/// record write leaves the snapshot the last deep pass derived standing,
/// since a record of installations as they stand changes no verdict in
/// it: the session that claimed reads its verdicts, not a "not yet
/// evaluated" it caused itself.
#[test]
#[allow(clippy::unwrap_used)]
fn an_unrecorded_copy_is_measured_against_the_commit_its_source_resolved() {
    let w = world();
    write_skill(&w.upstream, "gh", "One.");
    let first = commit(&w.upstream, "one");
    declare(&w, "", "[skills.gh]\nsource = \"cat\"\n");
    sync_and_apply(&w);
    drift::snapshot::record(&w.env, &w.scope).unwrap();
    let lock_path = kendex_core::lock::lock_path(&w.env, &w.scope);
    let rendered = match &w.scope {
        Scope::Project { root } => root.join(".agents/skills/gh/SKILL.md"),
        Scope::Global => unreachable!("the world is a project"),
    };
    let current = fs::read(&rendered).unwrap();
    fs::remove_file(&lock_path).unwrap();
    fs::write(
        &rendered,
        "---\nname: gh\ndescription: about gh\n---\nZero.\n",
    )
    .unwrap();

    let text = drift::report::render_plain(&drift::report::check(
        &w.env,
        std::slice::from_ref(&w.scope),
    ));
    assert!(
        text.contains(&format!(
            "unmanaged copy of skill 'gh' for Claude Code: 1 file differs from {REPO}@{}",
            &first[..7]
        )),
        "{text}"
    );
    assert!(
        text.contains("fix: kendex apply --replace-unmanaged"),
        "{text}"
    );
    assert!(!lock_path.exists(), "a copy that differs is not recorded");

    fs::write(&rendered, &current).unwrap();
    let text = drift::report::render_plain(&drift::report::check(
        &w.env,
        std::slice::from_ref(&w.scope),
    ));
    assert_eq!(
        text, "",
        "the copy the render matches is recorded without a word, and the snapshot the last deep pass derived stands"
    );
    assert!(matches!(
        drift::snapshot::load(&w.env, &w.scope),
        drift::snapshot::SnapshotFile::Current(_)
    ));
    let recorded = kendex_core::lock::load(&lock_path).unwrap();
    let entry = recorded
        .entries
        .values()
        .find(|entry| entry.name == "gh")
        .unwrap();
    assert_eq!(entry.source_commit.as_deref(), Some(first.as_str()));
    assert_eq!(recorded.sources["cat"].commit, first);
}

/// A record that already holds an entry keeps it as recorded when the
/// pass re-resolves its source to a newer commit with the content
/// unchanged: the check adds what it proved and rewrites nothing a pass
/// that did not write the files can vouch for. The neighbour the record
/// lacked is recorded at the commit the pass resolved.
#[test]
#[allow(clippy::unwrap_used)]
fn a_record_that_already_holds_an_entry_keeps_it_when_the_source_re_resolves() {
    let w = world();
    write_skill(&w.upstream, "gh", "One.");
    let first = commit(&w.upstream, "one");
    declare(&w, "", "[skills.gh]\nsource = \"cat\"\n");
    sync_and_apply(&w);
    write_skill(&w.upstream, "other", "Other.");
    let second = commit(&w.upstream, "two");
    declare(
        &w,
        "",
        "[skills.gh]\nsource = \"cat\"\n\n[skills.other]\nsource = \"cat\"\n",
    );
    // The render of `other` at the second commit lands on disk the way a
    // clone carries it, and the record goes back to what the first apply
    // wrote: gh at the first commit, nothing about other.
    let lock_path = kendex_core::lock::lock_path(&w.env, &w.scope);
    let before = fs::read(&lock_path).unwrap();
    sync_and_apply(&w);
    fs::write(&lock_path, &before).unwrap();
    let held = kendex_core::lock::load(&lock_path).unwrap();
    assert_eq!(held.sources["cat"].commit, first);

    let text = drift::report::render_plain(&drift::report::check(
        &w.env,
        std::slice::from_ref(&w.scope),
    ));
    assert!(
        !text.contains("'other'") && !text.contains("'gh'"),
        "{text}"
    );
    let recorded = kendex_core::lock::load(&lock_path).unwrap();
    let entry = |name: &str| {
        recorded
            .entries
            .values()
            .find(|entry| entry.name == name)
            .unwrap()
    };
    assert_eq!(
        entry("gh").source_commit.as_deref(),
        Some(first.as_str()),
        "the entry the record held is kept as recorded"
    );
    assert_eq!(
        entry("other").source_commit.as_deref(),
        Some(second.as_str()),
        "the entry it lacked is recorded at the commit the pass resolved"
    );
}

/// A declaration pinned at a revision is measured against the render at
/// the commit that pin resolved, and the line names that commit — not the
/// source's own tip, which the render was never built from.
#[test]
#[allow(clippy::unwrap_used)]
fn a_pinned_declaration_is_measured_at_the_commit_its_pin_resolved() {
    let w = world();
    write_skill(&w.upstream, "gh", "One.");
    let first = commit(&w.upstream, "one");
    declare(
        &w,
        "",
        &format!("[skills.gh]\nsource = \"cat\"\nrev = \"{first}\"\n"),
    );
    sync_and_apply(&w);
    write_skill(&w.upstream, "gh", "Two.");
    let second = commit(&w.upstream, "two");
    let loaded = manifest::load_for_mutation(&manifest::manifest_path(&w.env, &w.scope))
        .unwrap()
        .unwrap();
    remote::sync_sources(&w.env, &loaded).unwrap();
    let lock_path = kendex_core::lock::lock_path(&w.env, &w.scope);
    fs::remove_file(&lock_path).unwrap();
    let rendered = match &w.scope {
        Scope::Project { root } => root.join(".agents/skills/gh/SKILL.md"),
        Scope::Global => unreachable!("the world is a project"),
    };
    fs::write(
        &rendered,
        "---\nname: gh\ndescription: about gh\n---\nZero.\n",
    )
    .unwrap();

    let text = drift::report::render_plain(&drift::report::check(
        &w.env,
        std::slice::from_ref(&w.scope),
    ));
    assert!(
        text.contains(&format!(
            "unmanaged copy of skill 'gh' for Claude Code: 1 file differs from {REPO}@{}",
            &first[..7]
        )),
        "{text}"
    );
    assert!(
        !text.contains(&second[..7]),
        "the tip the pin holds off is not what the render was measured against: {text}"
    );
}

/// The background job derives the snapshot of a scope with a remote
/// source whose snapshot is absent, so the next session reads verdicts
/// rather than "not yet evaluated". The other side of that gate, a scope
/// of path sources, is `refresh_stale::a_scope_of_path_sources_gets_no_snapshot_from_the_job`.
#[test]
#[allow(clippy::unwrap_used)]
fn the_job_derives_the_snapshot_of_a_scope_with_a_remote_source() {
    let w = world();
    write_skill(&w.upstream, "gh", "One.");
    commit(&w.upstream, "one");
    declare(&w, "", "[skills.gh]\nsource = \"cat\"\n");
    sync_and_apply(&w);
    assert!(matches!(
        drift::snapshot::load(&w.env, &w.scope),
        drift::snapshot::SnapshotFile::Absent
    ));

    let notes = drift::refresh::refresh_stale(&w.env, std::slice::from_ref(&w.scope));
    assert!(notes.is_empty(), "{notes:?}");
    assert!(
        matches!(
            drift::snapshot::load(&w.env, &w.scope),
            drift::snapshot::SnapshotFile::Current(_)
        ),
        "a remote source's scope is evaluated by the job"
    );
}
