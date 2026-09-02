//! The four v1 bug classes v2 claims to have designed away, pinned:
//! per-install source identity on refresh (#1313), trailing-newline
//! preservation with a once-only repair (#1308), corrupt state failing
//! closed (#1307), and no user-visible mutation before validation and
//! confirmation (#1292).
#![cfg(unix)]

#[path = "../../test_util.rs"]
mod test_util;
use test_util::source_path;

use std::fs;
use std::path::{Path, PathBuf};

use kendex_core::apply;
use kendex_core::engine::{audit, ops};
use kendex_core::env::{Env, FakeOs};
use kendex_core::model::Scope;

struct World {
    _tmp: tempfile::TempDir,
    env: Env,
    home: PathBuf,
    project: PathBuf,
}

#[allow(clippy::unwrap_used)]
fn world() -> World {
    let tmp = tempfile::tempdir().unwrap();
    let home = tmp.path().canonicalize().unwrap();
    let project = home.join("app");
    fs::create_dir_all(project.join(".claude")).unwrap();
    fs::create_dir_all(home.join(".claude")).unwrap();
    World {
        env: Env::fake(&home, FakeOs::Linux),
        home,
        project,
        _tmp: tmp,
    }
}

#[allow(clippy::unwrap_used)]
fn write_catalog(dir: &Path, body: &str) {
    let skill = dir.join("skills/gh");
    fs::create_dir_all(&skill).unwrap();
    fs::write(
        skill.join("SKILL.md"),
        format!("---\nname: gh\ndescription: about gh\n---\n{body}\n"),
    )
    .unwrap();
}

#[allow(clippy::unwrap_used)]
fn apply_scope(w: &World, scope: &Scope) {
    let report = audit(&w.env, scope).unwrap();
    apply::execute(&w.env, &report.plan).unwrap();
}

/// The #1313 class: two scopes install the same package name from two
/// different sources; a refresh regenerates each install from its own
/// recorded source, never its neighbour's.
#[test]
#[allow(clippy::unwrap_used)]
fn refresh_reads_each_installs_own_recorded_source_across_scopes() {
    let w = world();
    write_catalog(&w.home.join("catA"), "From catalog A.");
    write_catalog(&w.home.join("catB"), "From catalog B.");
    fs::create_dir_all(w.env.global_manifest_file().parent().unwrap()).unwrap();
    fs::write(
        w.env.global_manifest_file(),
        format!(
            "schema = 6\n\n[sources.cat]\n{}\n\n[install]\nharnesses = [\"claude\"]\nmethod = \"symlink\"\n\n[skills.gh]\nsource = \"cat\"\n",
            source_path(&w.home.join("catA"))
        ),
    )
    .unwrap();
    fs::write(
        w.project.join("kendex.toml"),
        format!(
            "schema = 6\n\n[sources.cat]\n{}\n\n[install]\nharnesses = [\"claude\"]\nmethod = \"symlink\"\n\n[skills.gh]\nsource = \"cat\"\n",
            source_path(&w.home.join("catB"))
        ),
    )
    .unwrap();

    let global = Scope::Global;
    let project = Scope::Project {
        root: w.project.clone(),
    };
    apply_scope(&w, &global);
    apply_scope(&w, &project);

    // Upstreams both move; each refresh must follow its own source.
    write_catalog(&w.home.join("catA"), "A, revised.");
    write_catalog(&w.home.join("catB"), "B, revised.");
    apply_scope(&w, &global);
    apply_scope(&w, &project);

    let global_body = fs::read_to_string(w.env.rendered_skills_dir().join("gh/SKILL.md")).unwrap();
    let project_body = fs::read_to_string(w.project.join(".agents/skills/gh/SKILL.md")).unwrap();
    assert!(global_body.contains("A, revised."), "{global_body}");
    assert!(project_body.contains("B, revised."), "{project_body}");
}

/// The #1308 class on kendex.toml: a write neither adds a terminator nor
/// grows one. A file with none gets the one its last line needs, and every
/// pass after that leaves the bytes alone. A repair that ran on every pass
/// is how the file grew a blank line per apply. What a file already ends
/// in is its own — the blank line a person leaves there is covered by
/// `manifest::tests::the_files_own_terminator_survives`.
///
/// The fixture carries a comment because it must survive: a write folds
/// the changed keys into the document that is there rather than
/// serializing over it, which is what invariant 10 asks of every file
/// kendex edits in place. `byte_faithful.rs` holds that claim on the
/// verbs a person reaches for; `git grep -n 'Op::WriteManifest {' crates`
/// lists every site that plans one. Here it is the terminator under test.
#[test]
#[allow(clippy::unwrap_used)]
fn a_manifest_write_ends_in_one_terminator_and_settles() {
    let w = world();
    write_catalog(&w.home.join("cat"), "Body.");
    let manifest_path = w.project.join("kendex.toml");
    let scope = Scope::Project {
        root: w.project.clone(),
    };
    // No trailing newline on the file the write starts from: the repair
    // has something to do exactly once.
    fs::write(
        &manifest_path,
        format!(
            "# mine\nschema = 6\n\n[sources.cat]\n{}\n\n[install]\nharnesses = [\"claude\"]\nmethod = \"symlink\"",
            source_path(&w.home.join("cat"))
        ),
    )
    .unwrap();

    let report = ops::add(
        &w.env,
        &scope,
        &ops::AddRequest {
            source: Some("cat".into()),
            skills: vec!["gh".into()],
            ..Default::default()
        },
    )
    .unwrap();
    apply::execute(&w.env, &report.plan).unwrap();

    let written = fs::read_to_string(&manifest_path).unwrap();
    assert!(written.contains("[skills.gh]"), "{written}");
    assert!(written.starts_with("# mine\n"), "{written}");
    assert!(
        written.ends_with('\n') && !written.ends_with("\n\n"),
        "exactly one terminator: {written:?}"
    );

    // Stable from here: two more passes over the same scope change nothing.
    apply_scope(&w, &scope);
    assert_eq!(fs::read_to_string(&manifest_path).unwrap(), written);
    apply_scope(&w, &scope);
    assert_eq!(fs::read_to_string(&manifest_path).unwrap(), written);
}

/// The #1307 class: corrupt state fails the operation closed — a damaged
/// lock, manifest, or app settings file is an error, never a default.
#[test]
#[allow(clippy::unwrap_used)]
fn corrupt_state_fails_closed_instead_of_defaulting() {
    let w = world();
    let scope = Scope::Project {
        root: w.project.clone(),
    };
    fs::write(
        w.project.join("kendex.toml"),
        "schema = 6\n\n[install]\nharnesses = [\"claude\"]\nmethod = \"symlink\"\n",
    )
    .unwrap();

    // Damaged lock: the audit refuses rather than planning against nothing.
    fs::write(w.project.join(".kendex-lock.json"), "{torn").unwrap();
    assert!(audit(&w.env, &scope).is_err(), "a corrupt lock must refuse");
    fs::remove_file(w.project.join(".kendex-lock.json")).unwrap();

    // Damaged app settings: the observed scoring pass and the plan's
    // unmanaged scan both read the harness roots from them, and must
    // refuse rather than scan default locations the user has pointed
    // elsewhere.
    let settings = w.env.settings_file();
    fs::create_dir_all(settings.parent().unwrap()).unwrap();
    fs::write(&settings, "not = [valid").unwrap();
    assert!(
        kendex_core::engine::observed_rows(&w.env, &scope).is_err(),
        "corrupt settings must fail the audit closed"
    );
    assert!(
        audit(&w.env, &scope).is_err(),
        "corrupt settings must fail the plan closed"
    );
    fs::remove_file(&settings).unwrap();

    // Damaged manifest: same refusal.
    fs::write(w.project.join("kendex.toml"), "schema = [broken").unwrap();
    assert!(audit(&w.env, &scope).is_err());
}

/// The #1292 class: `add` mutates nothing user-visible before validation
/// and confirmation. A rejected request and an unconfirmed plan both leave
/// manifest, lock, and install tree byte-identical.
#[test]
#[allow(clippy::unwrap_used)]
fn add_writes_nothing_before_validation_and_confirmation() {
    let w = world();
    write_catalog(&w.home.join("cat"), "Body.");
    let manifest_text = format!(
        "schema = 6\n\n[sources.cat]\n{}\n\n[install]\nharnesses = [\"claude\"]\nmethod = \"symlink\"\n",
        source_path(&w.home.join("cat"))
    );
    fs::write(w.project.join("kendex.toml"), &manifest_text).unwrap();
    let scope = Scope::Project {
        root: w.project.clone(),
    };

    // A request that fails validation (an optional dependency nothing
    // offers) leaves everything exactly as it was.
    let bad = ops::AddRequest {
        source: Some("cat".into()),
        skills: vec!["gh".into()],
        optional: vec!["no-such-extra".into()],
        ..Default::default()
    };
    assert!(ops::add(&w.env, &scope, &bad).is_err());
    assert_eq!(
        fs::read_to_string(w.project.join("kendex.toml")).unwrap(),
        manifest_text,
        "a rejected add leaves the manifest untouched"
    );
    assert!(!w.project.join(".kendex-lock.json").exists());
    assert!(!w.project.join(".agents").exists());

    // A valid request plans; until the plan is confirmed and executed,
    // nothing user-visible has moved.
    let good = ops::AddRequest {
        source: Some("cat".into()),
        skills: vec!["gh".into()],
        ..Default::default()
    };
    let report = ops::add(&w.env, &scope, &good).unwrap();
    assert_eq!(
        fs::read_to_string(w.project.join("kendex.toml")).unwrap(),
        manifest_text,
        "planning writes nothing"
    );
    assert!(!w.project.join(".kendex-lock.json").exists());
    assert!(!w.project.join(".agents").exists());

    // Confirmation is the execute; only then does state move.
    apply::execute(&w.env, &report.plan).unwrap();
    assert!(
        fs::read_to_string(w.project.join("kendex.toml"))
            .unwrap()
            .contains("[skills.gh]")
    );
    assert!(w.project.join(".agents/skills/gh/SKILL.md").exists());
}
