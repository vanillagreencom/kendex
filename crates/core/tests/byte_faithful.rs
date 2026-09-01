//! Invariants 10–12: writes are byte-faithful and idempotent, a refused
//! operation mutates nothing, and an artifact that cannot be compared is
//! reported, never passed.
#![cfg(unix)]

#[path = "../../test_util.rs"]
mod test_util;
use test_util::{rooted, source_path};

use std::fs;
use std::os::unix::fs::{MetadataExt, PermissionsExt};

use kendex_core::apply;
use kendex_core::configedit::ConfigEdit;
use kendex_core::engine::{DriftState, audit};
use kendex_core::env::{Env, FakeOs};
use kendex_core::model::Scope;
use serde_json::json;

/// Applying the same structured edit twice must be byte-identical the
/// second time, trailing newline included — that equality is the drift
/// check for config-entry kinds, and a writer that drops the newline pins
/// corruption forever (the v1 lesson).
#[test]
#[allow(clippy::unwrap_used)]
fn every_config_edit_is_byte_stable_on_reapply() {
    let edits = [
        ConfigEdit::UpsertHook {
            event: "PreToolUse".into(),
            matcher: Some("Bash".into()),
            command: "./guard.sh".into(),
            timeout: Some(10),
        },
        ConfigEdit::UpsertMcpServer {
            name: "gh".into(),
            value: json!({"command": "gh-mcp"}),
        },
        ConfigEdit::SetPluginEnabled {
            key: "fmt@main".into(),
            enabled: Some(true),
        },
        ConfigEdit::OpencodeAddInstruction {
            reference: "instructions/x.md".into(),
            bash_permission: true,
        },
        ConfigEdit::OpencodePruneInstructions {
            prefix: "instructions/kendex-hook-".into(),
            keep: vec!["instructions/kendex-hook-x.md".into()],
        },
        ConfigEdit::CodexEnableHooksFeature,
        ConfigEdit::UpsertMarkerBlock {
            name: "pi".into(),
            block: "block text".into(),
        },
    ];
    for edit in edits {
        let once = edit.apply("").unwrap();
        let twice = edit.apply(&once).unwrap();
        assert_eq!(once, twice, "{edit:?} must be idempotent");
        assert!(
            once.ends_with('\n'),
            "{edit:?} must keep a trailing newline"
        );
    }
}

struct Fixture {
    _tmp: tempfile::TempDir,
    env: Env,
    scope: Scope,
    project: std::path::PathBuf,
}

#[allow(clippy::unwrap_used)]
fn fixture() -> Fixture {
    let tmp = tempfile::tempdir().unwrap();
    let home = tmp.path().to_path_buf();
    let env = Env::fake(&home, FakeOs::Linux);
    let project = home.join("dev/app");
    fs::create_dir_all(project.join(".claude")).unwrap();
    let source = home.join("catalog");
    fs::create_dir_all(source.join("agents")).unwrap();
    fs::write(
        source.join("agents/rust.md"),
        "---\nname: rust\ndescription: d\nrole: engineer\n---\nBody.\n",
    )
    .unwrap();
    fs::write(
        project.join("kendex.toml"),
        format!(
            "schema = 6\n\n[sources.cat]\n{}\n\n[install]\nharnesses = [\"claude\"]\nmethod = \"symlink\"\n\n[agents.rust]\nsource = \"cat\"\n",
            source_path(&source)
        ),
    )
    .unwrap();
    Fixture {
        env,
        scope: Scope::Project {
            root: project.clone(),
        },
        project,
        _tmp: tmp,
    }
}

/// A rejected apply leaves manifest, lock, and install tree byte-identical
/// (invariant 11) — validation precedes mutation, and rollback heals the
/// rest.
#[test]
#[allow(clippy::unwrap_used)]
fn a_refused_apply_leaves_every_surface_byte_identical() {
    let f = fixture();
    let report = audit(&f.env, &f.scope).unwrap();
    let manifest_before = fs::read(f.project.join("kendex.toml")).unwrap();

    // The plan binds to plan-time state; a file appearing at the target
    // after planning must abort the whole apply.
    fs::create_dir_all(f.project.join(".claude/agents")).unwrap();
    fs::write(f.project.join(".claude/agents/rust.md"), "squatter").unwrap();
    apply::execute(&f.env, &report.plan).unwrap_err();

    assert_eq!(
        fs::read(f.project.join("kendex.toml")).unwrap(),
        manifest_before
    );
    assert!(!f.project.join(".kendex-lock.json").exists());
    assert_eq!(
        fs::read_to_string(f.project.join(".claude/agents/rust.md")).unwrap(),
        "squatter"
    );
}

/// An installed artifact the engine cannot re-hash is a conflict row —
/// reported uncompared, never counted as passing (invariant 12).
#[test]
#[allow(clippy::unwrap_used)]
fn an_unreadable_artifact_reports_uncompared_not_ok() {
    let f = fixture();
    let report = audit(&f.env, &f.scope).unwrap();
    apply::execute(&f.env, &report.plan).unwrap();
    let installed = f.project.join(".claude/agents/rust.md");
    fs::set_permissions(&installed, fs::Permissions::from_mode(0o000)).unwrap();

    let report = audit(&f.env, &f.scope).unwrap();
    let row = report
        .drift
        .iter()
        .find(|row| row.name == "rust" && row.state == DriftState::Conflict)
        .expect("unreadable artifact is a conflict row");
    assert!(row.detail.contains("cannot be compared"));
    fs::set_permissions(&installed, fs::Permissions::from_mode(0o644)).unwrap();
}

/// A tree carries bytes, not modes — but a script that opens with a
/// shebang was written to be run, and a skill helper landing 644 fails
/// its own hook the first time something calls it (found migrating a
/// real repository).
#[test]
#[cfg(unix)]
#[allow(clippy::unwrap_used)]
fn a_written_tree_keeps_shebang_files_executable() {
    use std::os::unix::fs::PermissionsExt as _;
    let tmp = tempfile::tempdir().unwrap();
    let env = kendex_core::env::Env::fake(tmp.path(), kendex_core::env::FakeOs::Linux);
    let root = tmp.path().join("skill");
    let op = kendex_core::apply::PlannedOp {
        description: "write".into(),
        op: kendex_core::apply::Op::WriteTree {
            root: root.clone(),
            files: vec![
                (
                    std::path::PathBuf::from("scripts/run"),
                    b"#!/bin/sh\necho ok\n".to_vec(),
                ),
                (std::path::PathBuf::from("SKILL.md"), b"---\n---\n".to_vec()),
            ],
            pre: kendex_core::apply::Pre::Absent,
        },
    };
    // Through the constructor the product builds every plan with: it is
    // what fixes each path at the place it lands, which the transaction
    // then holds it to.
    let plan =
        kendex_core::apply::Plan::landed(kendex_core::model::Scope::Global, vec![op]).unwrap();
    kendex_core::apply::execute(&env, &plan).unwrap();
    let script = std::fs::metadata(root.join("scripts/run")).unwrap();
    assert!(
        script.permissions().mode() & 0o100 != 0,
        "the shebang file must land executable"
    );
    let doc = std::fs::metadata(root.join("SKILL.md")).unwrap();
    assert!(
        doc.permissions().mode() & 0o100 == 0,
        "a plain document must not"
    );
}

/// The manifest as somebody keeps it: a header comment, comments against
/// the tables, a trailing comment on a value, a key order no serializer
/// would choose, and `note`, a key the manifest model does not hold at
/// all. Every key with a default is left out — `[install]` names only the
/// harnesses, which pins the fan-out this fixture installs under and is
/// not a default; the hooks name neither `agents` nor, for the second,
/// `enabled`. So a write that lands any of them shows up here. Every case
/// below asserts the whole file.
fn kept_manifest(source: &std::path::Path) -> String {
    format!(
        "# what this project installs\nschema = 6\n\n# the catalog we read\n[sources.cat]\nenabled = true\n{}\n\n[install]\nharnesses = [\"claude\"]\n\n# the one we actually use\n[skills.gh]\nsource = \"cat\"   # from the catalog\nnote = \"why I keep this\"\nenabled = true\n\n# guards every bash call\n[[custom-hooks]]\nevent = \"PreToolUse\"\ncommand = \"./guard.sh\"\nenabled = true   # still on\n\n[[custom-hooks]]\nevent = \"Stop\"\ncommand = \"./done.sh\"\n",
        source_path(source)
    )
}

struct Kept {
    _tmp: tempfile::TempDir,
    env: Env,
    scope: Scope,
    project: std::path::PathBuf,
    manifest: std::path::PathBuf,
    original: String,
}

#[allow(clippy::unwrap_used)]
fn kept() -> Kept {
    let tmp = tempfile::tempdir().unwrap();
    let home = rooted(&tmp);
    let env = Env::fake(&home, FakeOs::Linux);
    let project = home.join("dev/app");
    fs::create_dir_all(project.join(".claude")).unwrap();
    let source = home.join("catalog");
    for name in ["gh", "fmt"] {
        fs::create_dir_all(source.join("skills").join(name)).unwrap();
        fs::write(
            source.join("skills").join(name).join("SKILL.md"),
            format!("---\nname: {name}\ndescription: about {name}\n---\nBody.\n"),
        )
        .unwrap();
    }
    let manifest = project.join("kendex.toml");
    let original = kept_manifest(&source);
    fs::write(&manifest, &original).unwrap();
    let scope = Scope::Project {
        root: project.clone(),
    };
    // Identity, not just content: `save` claims a write that changes
    // nothing writes nothing, and content alone cannot tell that from a
    // write that replaced the file with the same bytes. atomic_write
    // renames a fresh file into place, so the inode moves and the mtime
    // moves with it.
    let before = fs::metadata(&manifest).unwrap();
    let report = audit(&env, &scope).unwrap();
    apply::execute(&env, &report.plan).unwrap();
    let after = fs::metadata(&manifest).unwrap();
    assert_eq!(
        fs::read_to_string(&manifest).unwrap(),
        original,
        "installing what the file already declares writes nothing"
    );
    assert_eq!(
        (before.ino(), before.modified().unwrap()),
        (after.ino(), after.modified().unwrap()),
        "the file itself is untouched, not rewritten with the same bytes"
    );
    Kept {
        env,
        scope,
        project,
        manifest,
        original,
        _tmp: tmp,
    }
}

/// `add` declares one more skill and leaves every other byte where it was
/// (invariant 10): the comments, the blank lines, the hand spacing, the
/// key order inside `[sources.cat]`, and the trailing comment on the
/// declaration it did not touch.
#[test]
#[allow(clippy::unwrap_used)]
fn adding_a_skill_edits_kendex_toml_in_place() {
    let k = kept();
    let report = kendex_core::engine::ops::add(
        &k.env,
        &k.scope,
        &kendex_core::engine::ops::AddRequest {
            source: Some("cat".into()),
            skills: vec!["fmt".into()],
            ..Default::default()
        },
    )
    .unwrap();
    apply::execute(&k.env, &report.plan).unwrap();

    assert_eq!(
        fs::read_to_string(&k.manifest).unwrap(),
        declaring(&k.original, "[skills.fmt]\nsource = \"cat\"\n")
    );
}

/// `fork` rebinds the declaration it names and records the provenance.
/// The value it rewrites keeps the comment that sat beside it.
#[test]
#[allow(clippy::unwrap_used)]
fn forking_a_skill_edits_kendex_toml_in_place() {
    let k = kept();
    fs::write(
        k.project.join(".agents/skills/gh/SKILL.md"),
        "---\nname: gh\ndescription: about gh\n---\nMine now.\n",
    )
    .unwrap();
    let plan = kendex_core::engine::fork::fork(
        &k.env,
        &k.scope,
        kendex_core::model::ItemKind::Skill,
        "gh",
        kendex_core::model::HarnessId::Claude,
    )
    .unwrap();
    apply::execute(&k.env, &plan).unwrap();

    let written = fs::read_to_string(&k.manifest).unwrap();
    assert_eq!(
        written,
        rebound(&k.original) + &forks_table(&written),
        "{written}"
    );
}

/// `adopt` takes an unmanaged skill into the manifest; the file it appends
/// to is otherwise untouched.
#[test]
#[allow(clippy::unwrap_used)]
fn adopting_a_skill_edits_kendex_toml_in_place() {
    let k = kept();
    let mine = k.project.join(".claude/skills/mine");
    fs::create_dir_all(&mine).unwrap();
    fs::write(
        mine.join("SKILL.md"),
        "---\nname: mine\ndescription: my own\n---\nMine.\n",
    )
    .unwrap();
    let plan = kendex_core::engine::adopt::adopt(
        &k.env,
        &k.scope,
        kendex_core::model::ItemKind::Skill,
        "mine",
        &[kendex_core::model::HarnessId::Claude],
    )
    .unwrap();
    apply::execute(&k.env, &plan).unwrap();

    assert_eq!(
        fs::read_to_string(&k.manifest).unwrap(),
        declaring(&k.original, "[skills.mine]\nsource = \"in-place\"\n")
    );
}

/// `detach` drops the source declaration and rebinds what read from it.
/// The comment written against the table that goes leaves with it, and
/// nothing above or below it moves.
#[test]
#[allow(clippy::unwrap_used)]
fn detaching_a_source_edits_kendex_toml_in_place() {
    let k = kept();
    let plan = kendex_core::engine::detach::source(&k.env, &k.scope, "cat").unwrap();
    apply::execute(&k.env, &plan).unwrap();

    let written = fs::read_to_string(&k.manifest).unwrap();
    let source_block = &k.original[k
        .original
        .find("# the catalog we read")
        .expect("the fixture comments its source table")
        ..k.original
            .find("[install]")
            .expect("the fixture declares install defaults")];
    assert_eq!(
        written,
        rebound(&k.original.replace(source_block, "")) + &forks_table(&written),
        "{written}"
    );
}

/// The fixture with one more declaration in it, where a gained table
/// lands: under the last of its own kind, not at the end of the file where
/// it would read as more of whatever table is last.
fn declaring(manifest: &str, block: &str) -> String {
    manifest.replace(HOOK_COMMENT, &format!("{block}\n{HOOK_COMMENT}"))
}

const HOOK_COMMENT: &str = "# guards every bash call";

/// The declaration after a verb rebinds it to the person's own copy: the
/// one value changed, the comment beside it untouched.
fn rebound(manifest: &str) -> String {
    manifest.replace(
        "source = \"cat\"   # from the catalog",
        "source = \"local\"   # from the catalog",
    )
}

/// The `[forks.skill.gh]` block a fork records. Checked rather than
/// copied: a case cannot transcribe a timestamp it does not know, but it
/// can say what every other byte of the block is and that the file ends
/// there. Returned so the caller can put it back into its own expectation.
#[allow(clippy::unwrap_used, clippy::expect_used)]
fn forks_table(written: &str) -> String {
    let at = written
        .find("\n[forks.skill.gh]\n")
        .expect("the fork is recorded");
    let block = &written[at..];
    let lines: Vec<&str> = block.split('\n').collect();
    let stamp = lines
        .get(3)
        .and_then(|line| line.strip_prefix("forked-at = \""))
        .and_then(|value| value.strip_suffix('"'))
        .expect("the block records when the fork was made");
    assert!(
        stamp.parse::<toml::value::Datetime>().is_ok(),
        "forked-at is a timestamp: {stamp}"
    );
    assert_eq!(
        (lines.first(), lines.get(1), lines.get(2)),
        (
            Some(&""),
            Some(&"[forks.skill.gh]"),
            Some(&"source = \"cat\"")
        ),
        "{block}"
    );
    assert_eq!(
        lines.get(4..),
        Some([""].as_slice()),
        "the block is the end of the file: {block}"
    );
    block.to_owned()
}

/// A planned write whose result is the file that is already there does not
/// touch the file. Asking again for a skill this scope already declares
/// plans a manifest write like any other mutation; what it would land is
/// byte for byte what is on disk, and `save` stops before the write rather
/// than replacing the file with its own contents.
#[test]
#[allow(clippy::unwrap_used)]
fn a_write_that_changes_nothing_leaves_the_file_alone() {
    let k = kept();
    let before = fs::metadata(&k.manifest).unwrap();
    let report = kendex_core::engine::ops::add(
        &k.env,
        &k.scope,
        &kendex_core::engine::ops::AddRequest {
            source: Some("cat".into()),
            skills: vec!["gh".into()],
            ..Default::default()
        },
    )
    .unwrap();
    assert!(
        report
            .plan
            .ops
            .iter()
            .any(|op| matches!(op.op, apply::Op::WriteManifest { .. })),
        "the case only means something while the plan really does carry a manifest write"
    );
    apply::execute(&k.env, &report.plan).unwrap();

    let after = fs::metadata(&k.manifest).unwrap();
    assert_eq!(fs::read_to_string(&k.manifest).unwrap(), k.original);
    // Identity, not content: atomic_write renames a fresh file into place,
    // so a write that landed the same bytes still moves the inode and the
    // mtime, and only these can tell the two apart.
    assert_eq!(
        (before.ino(), before.modified().unwrap()),
        (after.ino(), after.modified().unwrap()),
        "the file itself is untouched, not rewritten with the same bytes"
    );
}
