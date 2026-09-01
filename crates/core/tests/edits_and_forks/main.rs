//! Edit protection and forking: a hand-edited installation is a conflict,
//! never a casualty — refresh holds it, automatic removals hold it, and
//! the two ways out are explicit: keep it as a fork, or discard the edits.
#![cfg(unix)]

mod access;
mod agent_capture;
mod agent_settings;
mod agent_tables;
mod available;
mod beside;
mod disabled;
mod edited_harness;
mod vacant;

mod forks;

use std::fs;
use std::path::{Path, PathBuf};

use kendex_core::apply;
use kendex_core::engine::desired::native_dir;
use kendex_core::engine::{
    DriftCause, DriftState, PlanOptions, audit, fork, plan_apply, plan_scope,
};
use kendex_core::env::{Env, FakeOs};
use kendex_core::lock::{load as load_lock, lock_path};
use kendex_core::manifest;
use kendex_core::model::{HarnessId, ItemKind, Scope};
use kendex_core::process::Hardened;
use kendex_core::remote;

const REPO: &str = "owner/catalog";

struct World {
    _tmp: tempfile::TempDir,
    env: Env,
    home: PathBuf,
    upstream: PathBuf,
    scope: Scope,
}

#[allow(clippy::unwrap_used)]
fn git(dir: &Path, args: &[&str]) {
    let output = Hardened::git(args, Some(dir)).run().unwrap();
    assert!(output.status.success(), "git {args:?}");
}

/// HEAD's commit id, through the same hardened runner every fixture git
/// call uses — run from a commit hook, GIT_DIR and friends would point at
/// the repository being committed to; scrubbed, HEAD is the fixture's.
#[allow(clippy::unwrap_used)]
fn head_commit(dir: &Path) -> String {
    let output = Hardened::git(&["rev-parse", "HEAD"], Some(dir))
        .run()
        .unwrap();
    assert!(output.status.success(), "git rev-parse HEAD");
    String::from_utf8(output.stdout).unwrap().trim().to_owned()
}

#[allow(clippy::unwrap_used)]
fn commit(dir: &Path, message: &str) {
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
}

#[allow(clippy::unwrap_used)]
fn write_skill(dir: &Path, name: &str, body: &str) {
    let skill = dir.join("skills").join(name);
    fs::create_dir_all(&skill).unwrap();
    fs::write(
        skill.join("SKILL.md"),
        format!("---\nname: {name}\ndescription: about {name}\n---\n{body}\n"),
    )
    .unwrap();
}

#[allow(clippy::unwrap_used)]
fn write_agent(dir: &Path, name: &str, body: &str) {
    let agents = dir.join("agents");
    fs::create_dir_all(&agents).unwrap();
    fs::write(
        agents.join(format!("{name}.md")),
        format!("---\nname: {name}\ndescription: agent {name}\n---\n{body}\n"),
    )
    .unwrap();
}

#[allow(clippy::unwrap_used)]
fn manifest_text(w: &World) -> String {
    fs::read_to_string(manifest::manifest_path(&w.env, &w.scope)).unwrap()
}

/// The manifest as the loader reads it back, for assertions about the
/// records themselves. A record is what the next render is written from,
/// and its text spells one field per line: a reading that searches the
/// text cannot tell a record holding one field from the same record
/// holding three.
#[allow(clippy::unwrap_used)]
fn manifest_of(w: &World) -> manifest::Manifest {
    manifest::load_for_mutation(&manifest::manifest_path(&w.env, &w.scope))
        .unwrap()
        .unwrap()
}

#[allow(clippy::unwrap_used)]
fn world() -> World {
    let tmp = tempfile::tempdir().unwrap();
    let home = tmp.path().to_path_buf();
    world_at(tmp, home)
}

/// [`world`], with every path reaching the home through a symlink — the
/// spelling macOS hands every test anyway (`/var` → `/private/var` fronts
/// its temp directories), reproduced here so the one-spelling rule stays
/// covered on every platform.
#[allow(clippy::unwrap_used)]
fn world_via_link() -> World {
    let tmp = tempfile::tempdir().unwrap();
    let real = tmp.path().join("real");
    fs::create_dir_all(&real).unwrap();
    let home = tmp.path().join("via");
    std::os::unix::fs::symlink(&real, &home).unwrap();
    world_at(tmp, home)
}

/// The fixture body both worlds share; `home` is the spelling every path
/// in the World speaks.
#[allow(clippy::unwrap_used)]
fn world_at(tmp: tempfile::TempDir, home: PathBuf) -> World {
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
        home,
        upstream,
        _tmp: tmp,
    }
}

#[allow(clippy::unwrap_used)]
fn declare(w: &World, body: &str) {
    let path = manifest::manifest_path(&w.env, &w.scope);
    fs::create_dir_all(path.parent().unwrap()).unwrap();
    fs::write(
        &path,
        format!(
            "schema = 6\n\n[sources.cat]\nrepo = \"{REPO}\"\n\n[install]\nharnesses = [\"claude\"]\nmethod = \"symlink\"\n\n{body}"
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

fn skill_file(w: &World) -> PathBuf {
    w.home.join("app/.agents/skills/gh/SKILL.md")
}

/// A world with `gh` edited on disk and a newer upstream the mirror knows,
/// returned with the commit the edits were made on and the newer one.
#[allow(clippy::unwrap_used)]
fn edited_world() -> (World, String, String) {
    let w = world();
    write_skill(&w.upstream, "gh", "Upstream.");
    commit(&w.upstream, "one");
    let one = head_commit(&w.upstream);
    declare(
        &w,
        &format!("[skills.gh]\nsource = \"cat\"\nrev = \"{one}\"\n"),
    );
    sync_and_apply(&w);
    fs::write(
        skill_file(&w),
        "---\nname: gh\ndescription: mine\n---\nMy fork.\n",
    )
    .unwrap();
    write_skill(&w.upstream, "gh", "Upstream v2.");
    commit(&w.upstream, "two");
    let two = head_commit(&w.upstream);
    sync_and_apply(&w);
    (w, one, two)
}

#[test]
#[allow(clippy::unwrap_used)]
fn a_local_edit_survives_refresh_and_reads_as_local_edit() {
    let w = world();
    write_skill(&w.upstream, "gh", "Upstream.");
    commit(&w.upstream, "one");
    declare(&w, "[skills.gh]\nsource = \"cat\"\n");
    sync_and_apply(&w);

    fs::write(skill_file(&w), "my edited version").unwrap();
    let report = audit(&w.env, &w.scope).unwrap();
    let row = report.drift.iter().find(|row| row.name == "gh").unwrap();
    assert_eq!(row.state, DriftState::Conflict);
    assert_eq!(row.cause, Some(DriftCause::LocalEdit));
    apply::execute(&w.env, &report.plan).unwrap();
    assert_eq!(
        fs::read_to_string(skill_file(&w)).unwrap(),
        "my edited version",
        "an edit is never an automatic casualty"
    );
}

#[test]
#[allow(clippy::unwrap_used)]
fn edited_and_moved_upstream_reads_as_both_and_discard_is_explicit() {
    let w = world();
    write_skill(&w.upstream, "gh", "One.");
    commit(&w.upstream, "one");
    declare(&w, "[skills.gh]\nsource = \"cat\"\n");
    sync_and_apply(&w);

    fs::write(skill_file(&w), "my edited version").unwrap();
    write_skill(&w.upstream, "gh", "Two.");
    commit(&w.upstream, "two");
    let loaded = manifest::load_for_mutation(&manifest::manifest_path(&w.env, &w.scope))
        .unwrap()
        .unwrap();
    remote::sync_sources(&w.env, &loaded).unwrap();

    let report = audit(&w.env, &w.scope).unwrap();
    let row = report.drift.iter().find(|row| row.name == "gh").unwrap();
    assert_eq!(row.cause, Some(DriftCause::Both), "{row:?}");
    apply::execute(&w.env, &report.plan).unwrap();
    assert_eq!(
        fs::read_to_string(skill_file(&w)).unwrap(),
        "my edited version"
    );

    // Discarding is the explicit act.
    let manifest = manifest::load_for_mutation(&manifest::manifest_path(&w.env, &w.scope))
        .unwrap()
        .unwrap();
    let lock = load_lock(&lock_path(&w.env, &w.scope)).unwrap();
    let report = plan_scope(
        &w.env,
        &w.scope,
        &manifest,
        &lock,
        &PlanOptions {
            overwrite_edited: true,
            ..Default::default()
        },
    )
    .unwrap();
    apply::execute(&w.env, &report.plan).unwrap();
    assert!(fs::read_to_string(skill_file(&w)).unwrap().contains("Two."));
    assert!(audit(&w.env, &w.scope).unwrap().drift.is_empty());
}

#[test]
#[allow(clippy::unwrap_used)]
fn discarding_one_packages_edits_leaves_another_packages_edits_held() {
    let w = world();
    write_skill(&w.upstream, "gh", "Upstream gh.");
    write_skill(&w.upstream, "lint", "Upstream lint.");
    commit(&w.upstream, "one");
    declare(
        &w,
        "[skills.gh]\nsource = \"cat\"\n\n[skills.lint]\nsource = \"cat\"\n",
    );
    sync_and_apply(&w);

    let gh = w.home.join("app/.agents/skills/gh/SKILL.md");
    let lint = w.home.join("app/.agents/skills/lint/SKILL.md");
    fs::write(&gh, "my gh edit").unwrap();
    fs::write(&lint, "my lint edit").unwrap();

    // Discard gh only. lint's edit must survive untouched.
    let manifest = manifest::load_for_mutation(&manifest::manifest_path(&w.env, &w.scope))
        .unwrap()
        .unwrap();
    let lock = load_lock(&lock_path(&w.env, &w.scope)).unwrap();
    let report = plan_scope(
        &w.env,
        &w.scope,
        &manifest,
        &lock,
        &PlanOptions {
            overwrite_edited_names: Some(vec![(ItemKind::Skill, "gh".to_owned())]),
            ..Default::default()
        },
    )
    .unwrap();
    apply::execute(&w.env, &report.plan).unwrap();

    assert!(fs::read_to_string(&gh).unwrap().contains("Upstream gh."));
    assert_eq!(
        fs::read_to_string(&lint).unwrap(),
        "my lint edit",
        "discarding one package's edits took another's"
    );
}

#[test]
#[allow(clippy::unwrap_used)]
fn a_hand_made_copy_of_the_desired_bytes_is_clean() {
    let w = world();
    write_skill(&w.upstream, "gh", "One.");
    commit(&w.upstream, "one");
    declare(&w, "[skills.gh]\nsource = \"cat\"\n");
    sync_and_apply(&w);

    // Rewrite the file with its own exact bytes: no edit, nothing to hold.
    let bytes = fs::read(skill_file(&w)).unwrap();
    fs::write(skill_file(&w), &bytes).unwrap();
    assert!(audit(&w.env, &w.scope).unwrap().drift.is_empty());
}

#[test]
#[allow(clippy::unwrap_used)]
fn discarding_a_skills_edits_leaves_a_same_named_agents_edits_held() {
    let w = world();
    write_skill(&w.upstream, "rev", "Skill rev.");
    let dir = w.upstream.join("agents");
    fs::create_dir_all(&dir).unwrap();
    fs::write(
        dir.join("rev.md"),
        "---\nname: rev\ndescription: agent rev\n---\nAgent body.\n",
    )
    .unwrap();
    commit(&w.upstream, "one");
    declare(
        &w,
        "[skills.rev]\nsource = \"cat\"\n\n[agents.rev]\nsource = \"cat\"\n",
    );
    sync_and_apply(&w);

    let skill = w.home.join("app/.agents/skills/rev/SKILL.md");
    let agent = w.home.join("app/.claude/agents/rev.md");
    fs::write(&skill, "my skill edit").unwrap();
    fs::write(&agent, "my agent edit").unwrap();

    let manifest = manifest::load_for_mutation(&manifest::manifest_path(&w.env, &w.scope))
        .unwrap()
        .unwrap();
    let lock = load_lock(&lock_path(&w.env, &w.scope)).unwrap();
    let report = plan_scope(
        &w.env,
        &w.scope,
        &manifest,
        &lock,
        &PlanOptions {
            overwrite_edited_names: Some(vec![(ItemKind::Skill, "rev".to_owned())]),
            ..Default::default()
        },
    )
    .unwrap();
    apply::execute(&w.env, &report.plan).unwrap();

    assert!(fs::read_to_string(&skill).unwrap().contains("Skill rev."));
    assert_eq!(
        fs::read_to_string(&agent).unwrap(),
        "my agent edit",
        "discarding the skill took the same-named agent's edit"
    );
}

#[test]
#[allow(clippy::unwrap_used)]
fn updates_survives_a_source_that_cannot_resolve() {
    let w = world();
    write_skill(&w.upstream, "gh", "Upstream.");
    commit(&w.upstream, "one");
    declare(&w, "[skills.gh]\nsource = \"cat\"\n");
    sync_and_apply(&w);
    fs::write(w.home.join("app/.agents/skills/gh/SKILL.md"), "my edit").unwrap();

    // Repoint the source at a repo that cannot resolve: the updates
    // projection (which now runs a plan to find edits) must not panic, and
    // must return rather than fail open on a plan it cannot produce.
    let path = manifest::manifest_path(&w.env, &w.scope);
    fs::write(
        &path,
        "schema = 6\n\n[sources.cat]\nrepo = \"owner/gone\"\n\n[install]\nharnesses = [\"claude\"]\nmethod = \"symlink\"\n\n[skills.gh]\nsource = \"cat\"\n",
    )
    .unwrap();
    let rows = kendex_core::package::updates::updates(&w.env, &w.scope);
    assert!(
        rows.is_ok(),
        "updates must survive an unresolvable source: {rows:?}"
    );
}

#[test]
#[allow(clippy::unwrap_used)]
fn a_deleted_install_is_missing_not_an_edit() {
    let w = world();
    write_skill(&w.upstream, "gh", "One.");
    commit(&w.upstream, "one");
    declare(&w, "[skills.gh]\nsource = \"cat\"\n");
    sync_and_apply(&w);

    fs::remove_dir_all(w.home.join("app/.agents/skills/gh")).unwrap();
    let report = audit(&w.env, &w.scope).unwrap();
    let row = report.drift.iter().find(|row| row.name == "gh").unwrap();
    assert_eq!(row.state, DriftState::Missing, "{row:?}");
    apply::execute(&w.env, &report.plan).unwrap();
    assert!(skill_file(&w).is_file(), "a missing install is restored");
}

#[test]
#[allow(clippy::unwrap_used)]
fn an_automatic_sweep_never_takes_edited_bytes() {
    let w = world();
    let gh = w.upstream.join("skills/gh/SKILL.md");
    fs::create_dir_all(gh.parent().unwrap()).unwrap();
    fs::write(
        &gh,
        "---\nname: gh\ndescription: about gh\ndependencies:\n  required: [helper]\n---\nParent.\n",
    )
    .unwrap();
    write_skill(&w.upstream, "helper", "Helper.");
    commit(&w.upstream, "one");
    declare(&w, "[skills.gh]\nsource = \"cat\"\n");
    sync_and_apply(&w);
    assert!(
        w.home.join("app/.agents/skills/helper/SKILL.md").is_file(),
        "dependency installed"
    );

    // The user edits the dependency, then upstream drops it: the sweep
    // (a refresh regenerates and sweeps unneeded) must hold the bytes.
    fs::write(
        w.home.join("app/.agents/skills/helper/SKILL.md"),
        "my notes live here now",
    )
    .unwrap();
    fs::write(
        &gh,
        "---\nname: gh\ndescription: about gh\n---\nParent without helper.\n",
    )
    .unwrap();
    commit(&w.upstream, "two");
    let loaded = manifest::load_for_mutation(&manifest::manifest_path(&w.env, &w.scope))
        .unwrap()
        .unwrap();
    remote::sync_sources(&w.env, &loaded).unwrap();
    let report = plan_apply(
        &w.env,
        &w.scope,
        &PlanOptions {
            sweep_unneeded: true,
            ..PlanOptions::default()
        },
    )
    .unwrap();
    apply::execute(&w.env, &report.plan).unwrap();
    assert_eq!(
        fs::read_to_string(w.home.join("app/.agents/skills/helper/SKILL.md")).unwrap(),
        "my notes live here now",
        "a sweep never takes edited bytes"
    );
}

// Fixtures both agent modules read. They live here rather than in one of
// them because a test module reaching into a sibling's helpers makes the
// split between them dishonest.

const BANNER: &str = "> Generated by kendex — do not edit; regenerated on every refresh. Intent lives in kendex.toml.";

/// A world whose catalog carries the agent `rev`, declared on `harnesses`
/// and applied. `catalog` is the catalog's own control file, where a
/// publisher states per-harness frontmatter defaults; `project` is
/// whatever the scope's own manifest adds beneath the declaration.
#[allow(clippy::unwrap_used)]
fn agent_world(harnesses: &str, agent: &str, catalog: &str, project: &str) -> World {
    let w = world();
    let agents = w.upstream.join("agents");
    fs::create_dir_all(&agents).unwrap();
    fs::write(agents.join("rev.md"), agent).unwrap();
    fs::write(w.upstream.join("kendex.toml"), catalog).unwrap();
    commit(&w.upstream, "one");
    let path = manifest::manifest_path(&w.env, &w.scope);
    fs::create_dir_all(path.parent().unwrap()).unwrap();
    fs::write(
        &path,
        format!(
            "schema = 6\n\n[sources.cat]\nrepo = \"{REPO}\"\n\n[install]\nharnesses = [{harnesses}]\nmethod = \"symlink\"\n\n[agents.rev]\nsource = \"cat\"\n\n{project}"
        ),
    )
    .unwrap();
    sync_and_apply(&w);
    w
}

/// The rendered agent's own path, taken from the environment rather than
/// composed, so a home reached through a link spells it the one way.
#[allow(clippy::unwrap_used)]
fn rendered(w: &World, harness: HarnessId, name: &str) -> PathBuf {
    native_dir(&w.env, &w.scope, harness, ItemKind::Agent)
        .unwrap()
        .join(format!("{name}.md"))
}

fn captured(w: &World, name: &str) -> PathBuf {
    w.home.join(format!("app/.kendex-local/agents/{name}.md"))
}

/// Replace the agent's prose where it stands, the way a person editing an
/// installed agent does, leaving every generated line alone.
#[allow(clippy::unwrap_used)]
fn edit_body(path: &std::path::Path) {
    edit_line(path, "Upstream body.", "My body.");
}

/// One line of the rendering replaced where it stands. The line a test
/// edits is what decides which lines the capture can still attribute, so
/// a test that only ever edits the last one proves nothing about the rest.
#[allow(clippy::unwrap_used)]
fn edit_line(path: &std::path::Path, from: &str, to: &str) {
    let text = fs::read_to_string(path).unwrap();
    assert!(text.contains(from), "{from} is not in {text}");
    fs::write(path, text.replace(from, to)).unwrap();
}

#[allow(clippy::unwrap_used)]
fn resettle(w: &World) {
    let report = audit(&w.env, &w.scope).unwrap();
    apply::execute(&w.env, &report.plan).unwrap();
}

fn deny_line(text: &str, key: &str) -> String {
    text.lines()
        .find(|line| line.starts_with(key))
        .unwrap_or_default()
        .to_owned()
}

fn banners(text: &str) -> usize {
    times(text, BANNER)
}

/// How many lines are exactly `line`. Every generated section is asserted
/// by count rather than presence: a section the capture kept and the next
/// render wrote again is present either way, so `contains` cannot tell a
/// carried configuration from a duplicated one.
fn times(text: &str, line: &str) -> usize {
    text.lines()
        .filter(|written| written.trim() == line)
        .count()
}
