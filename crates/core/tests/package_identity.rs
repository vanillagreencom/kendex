//! One package installed across the fleet is one package.
//!
//! Every tool stores a package in the shape it can load, and several of
//! those shapes carry neither the declared kind nor the declared name: a
//! Cursor hook is an advisory rule on the rules surface, an OpenCode hook
//! is a prefixed instruction file, a native registration is named for the
//! event and command it registered, and a Codex command is a skill tree.
//! What the Library shows a row per, what a count counts, and what an
//! action writes to are all the declared package, so every one of those
//! observations has to resolve back to it — and anything the records
//! cannot account for has to stay exactly as distinct as it was.
#![cfg(unix)]

#[path = "../../test_util.rs"]
mod test_util;
use test_util::{rooted, source_path};

use std::fs;
use std::path::{Path, PathBuf};

use kendex_core::apply;
use kendex_core::engine::audit;
use kendex_core::env::{Env, FakeOs};
use kendex_core::library::{Origin, PackageRef, ProvenanceRow, provenance};
use kendex_core::model::{HarnessId, ItemKind, Scope};

/// Every tool kendex writes hooks to, so the fixture covers every shipped
/// hook rendering rather than the ones that are easy to reach.
const HARNESSES: &str = "\"claude\", \"codex\", \"opencode\", \"cursor\", \"pi\", \"gemini\", \"copilot\", \"antigravity\"";

const HOOK: &str = "#!/usr/bin/env bash\n\
# ---\n\
# name: block-worktree-refresh\n\
# event: PreToolUse\n\
# matcher: Bash\n\
# description: refuse a refresh inside a worktree\n\
# harnesses: [claude-code, codex, opencode, cursor, pi, gemini, copilot, antigravity]\n\
# ---\n\
exit 0\n";

/// One declaration of every kind the catalog carries.
const EVERY_KIND: [&str; 5] = [
    "[hooks.block-worktree-refresh]\nsource = \"cat\"\n",
    "[skills.gh]\nsource = \"cat\"\n",
    "[commands.ship]\nsource = \"cat\"\n",
    "[agents.review]\nsource = \"cat\"\n",
    "[mcp-servers.fs]\nsource = \"cat\"\n",
];

struct Fixture {
    _tmp: tempfile::TempDir,
    env: Env,
    home: PathBuf,
    project: PathBuf,
    scope: Scope,
}

#[allow(clippy::unwrap_used)]
fn fixture(declarations: &str) -> Fixture {
    fixture_for(declarations, "copy", HARNESSES)
}

#[allow(clippy::unwrap_used)]
fn fixture_for(declarations: &str, method: &str, harnesses: &str) -> Fixture {
    let tmp = tempfile::tempdir().unwrap();
    let home = rooted(&tmp);
    let env = Env::fake(&home, FakeOs::Linux);
    let project = home.join("dev/vsys");
    fs::create_dir_all(project.join(".claude")).unwrap();

    let catalog = home.join("catalog");
    fs::create_dir_all(catalog.join("hooks")).unwrap();
    fs::create_dir_all(catalog.join("skills/gh")).unwrap();
    fs::create_dir_all(catalog.join("commands")).unwrap();
    fs::create_dir_all(catalog.join("agents")).unwrap();
    fs::create_dir_all(catalog.join("mcp")).unwrap();
    fs::write(catalog.join("hooks/block-worktree-refresh.sh"), HOOK).unwrap();
    fs::write(
        catalog.join("skills/gh/SKILL.md"),
        "---\nname: gh\ndescription: github\n---\nBody.\n",
    )
    .unwrap();
    fs::write(
        catalog.join("commands/ship.md"),
        "---\ndescription: ship it\n---\nBody.\n",
    )
    .unwrap();
    fs::write(
        catalog.join("agents/review.md"),
        "---\nname: review\ndescription: review a diff\n---\nBody.\n",
    )
    .unwrap();
    fs::write(catalog.join("mcp/fs.toml"), "command = \"fs-server\"\n").unwrap();
    fs::write(catalog.join("kendex.toml"), "is_source_catalog = true\n").unwrap();
    fs::write(
        project.join("kendex.toml"),
        format!(
            "schema = 6\n\n[sources.cat]\n{}\n\n[install]\nharnesses = [{harnesses}]\nmethod = \"{method}\"\n\n{declarations}",
            source_path(&catalog)
        ),
    )
    .unwrap();

    Fixture {
        env,
        home,
        scope: Scope::Project {
            root: project.clone(),
        },
        project,
        _tmp: tmp,
    }
}

#[allow(clippy::unwrap_used)]
fn apply_now(f: &Fixture) {
    let report = audit(&f.env, &f.scope).unwrap();
    apply::execute(&f.env, &report.plan).unwrap();
}

#[allow(clippy::unwrap_used)]
fn rows(f: &Fixture) -> Vec<ProvenanceRow> {
    provenance(&f.env, std::slice::from_ref(&f.scope)).unwrap()
}

fn package(kind: ItemKind, name: &str) -> Option<PackageRef> {
    Some(PackageRef {
        kind,
        name: name.to_owned(),
    })
}

/// Every observation the scan produced, less the rows a lock entry seeded
/// for an installation nothing observed under its declared identity.
fn observed(rows: &[ProvenanceRow], f: &Fixture) -> Vec<ProvenanceRow> {
    let scanned =
        kendex_core::scan::scan_scopes(&f.env, &Default::default(), std::slice::from_ref(&f.scope));
    rows.iter()
        .filter(|row| {
            scanned.items.iter().any(|item| {
                item.kind == row.kind && item.name == row.name && item.harness == row.harness
            })
        })
        .cloned()
        .collect()
}

/// The one row for a package on one tool, whatever that tool stores it as.
#[allow(clippy::unwrap_used)]
fn row_for(rows: &[ProvenanceRow], harness: HarnessId, package: &PackageRef) -> ProvenanceRow {
    let found: Vec<_> = rows
        .iter()
        .filter(|row| row.harness == harness && row.package.as_ref() == Some(package))
        .collect();
    assert_eq!(
        found.len(),
        1,
        "{}/{} rows for {package:?}: {found:#?}",
        harness.name(),
        package.name,
    );
    found[0].clone()
}

/// A fixture path in the spelling the scan hands out.
fn paths_canonical(path: &Path) -> PathBuf {
    kendex_core::paths::canonical(path).unwrap_or_else(|_| path.to_path_buf())
}

fn marketplace(catalog: &Path) -> Origin {
    Origin::Marketplace {
        source: "cat".to_owned(),
        repo: catalog.display().to_string(),
    }
}

/// The reported case: one hook installed for every tool. Each tool stores
/// it its own way, and every one of those is the same package from the
/// same marketplace.
#[test]
#[allow(clippy::unwrap_used)]
fn one_hook_across_every_tool_is_one_package_from_its_marketplace() {
    let f = fixture("[hooks.block-worktree-refresh]\nsource = \"cat\"\n");
    apply_now(&f);
    let rows = observed(&rows(&f), &f);
    let hook = PackageRef {
        kind: ItemKind::Hook,
        name: "block-worktree-refresh".to_owned(),
    };
    let catalog = f.home.join("catalog");
    for harness in HarnessId::ALL {
        let row = row_for(&rows, harness, &hook);
        assert_eq!(
            row.origin,
            marketplace(&catalog),
            "{} origin",
            harness.name()
        );
    }
    // Cursor stores it as a rule the rules surface reads as an agent, and
    // the tools with a registry store it under the event and command they
    // registered — neither spelling is the package's name.
    let cursor = row_for(&rows, HarnessId::Cursor, &hook);
    assert_eq!(cursor.kind, ItemKind::Agent);
    assert_eq!(cursor.name, "safety-block-worktree-refresh");
    let claude = row_for(&rows, HarnessId::Claude, &hook);
    assert_eq!(claude.kind, ItemKind::Hook);
    assert_eq!(claude.name, "PreToolUse:Bash:block-worktree-refresh");
    let opencode = row_for(&rows, HarnessId::Opencode, &hook);
    assert_eq!(opencode.name, "kendex-hook-block-worktree-refresh");
}

/// A file at a position no record claims is somebody else's, whatever it
/// is called. A tool reads more than one root, so the same name in the
/// other one is a different file — and a name is not evidence about a file.
#[test]
#[allow(clippy::unwrap_used)]
fn a_file_at_an_unclaimed_position_stays_nobody_s() {
    // Copy delivery for Claude: the record claims Claude's own directory
    // and nothing in the shared tree, which Claude also reads.
    let f = fixture_for("[skills.gh]\nsource = \"cat\"\n", "copy", "\"claude\"");
    apply_now(&f);
    // Somebody's own gh in the tree Claude reads as well. Claude is the
    // tool whose record names this package, so a name rule would hand this
    // stranger's file that package.
    let mine = f.project.join(".agents/skills/gh");
    fs::create_dir_all(&mine).unwrap();
    fs::write(
        mine.join("SKILL.md"),
        "---\nname: gh\ndescription: my own\n---\nBody.\n",
    )
    .unwrap();

    let rows = observed(&rows(&f), &f);
    let at = |path: &Path| kendex_core::paths::slashed(&paths_canonical(path));
    let package_at = |position: String| -> Vec<Option<PackageRef>> {
        rows.iter()
            .filter(|row| row.at.as_deref() == Some(position.as_str()))
            .map(|row| row.package.clone())
            .collect()
    };
    // The position the record claims is the package.
    assert_eq!(
        package_at(at(&f.project.join(".claude/skills/gh"))),
        vec![package(ItemKind::Skill, "gh")],
        "the installed gh lost its package"
    );
    // The position no record claims is nobody's, for every tool that reads
    // it — and a name rule would have handed all of them this package,
    // since Claude's own record declares that very name.
    let theirs = package_at(at(&mine));
    assert!(!theirs.is_empty(), "the stranger's gh was never observed");
    assert!(
        theirs.iter().all(Option::is_none),
        "a gh nobody recorded was credited to the package: {theirs:#?}"
    );
}

/// A shared tree is written by one tool's record and read by every tool.
/// The record that claimed the position answers for where it came from —
/// asking for a record held for the OBSERVING tool would call the writer's
/// own file unmanaged everywhere but at the writer.
#[test]
#[allow(clippy::unwrap_used)]
fn the_claiming_record_answers_for_a_tree_every_tool_reads() {
    let f = fixture_for("[skills.gh]\nsource = \"cat\"\n", "symlink", "\"cursor\"");
    apply_now(&f);
    let rows = observed(&rows(&f), &f);
    let catalog = f.home.join("catalog");
    let readers: Vec<_> = rows
        .iter()
        .filter(|row| row.package == package(ItemKind::Skill, "gh"))
        .collect();
    assert!(
        readers.len() > 1,
        "only the writing tool observed the shared tree: {readers:#?}"
    );
    for row in readers {
        assert_eq!(
            row.origin,
            marketplace(&catalog),
            "{} lost the claiming record's origin",
            row.harness.name()
        );
    }
}

/// A registration is named for its command's stem, and two unrelated
/// scripts can share one. The record keeps the whole command, so that is
/// what has to match before a package is credited with an entry.
#[test]
#[allow(clippy::unwrap_used)]
fn a_registration_running_another_script_is_not_this_package() {
    let f = fixture_for(
        "[hooks.block-worktree-refresh]\nsource = \"cat\"\n",
        "copy",
        "\"claude\"",
    );
    apply_now(&f);
    // Somebody's own entry, same event and matcher, running a script of
    // their own that happens to share the stem kendex's command reduces to.
    let settings = f.project.join(".claude/settings.json");
    let mut document: serde_json::Value =
        serde_json::from_str(&fs::read_to_string(&settings).unwrap()).unwrap();
    document["hooks"]["PreToolUse"]
        .as_array_mut()
        .unwrap()
        .push(serde_json::json!({
            "matcher": "Bash",
            "hooks": [{
                "type": "command",
                "command": "bash \"/opt/mine/block-worktree-refresh.sh\""
            }],
        }));
    fs::write(&settings, serde_json::to_string_pretty(&document).unwrap()).unwrap();

    let rows = observed(&rows(&f), &f);
    let theirs: Vec<_> = rows
        .iter()
        .filter(|row| row.kind == ItemKind::Hook && row.package.is_none())
        .collect();
    assert_eq!(
        theirs.len(),
        1,
        "somebody else's registration was credited to the package: {rows:#?}"
    );
    assert_eq!(theirs[0].origin, Origin::Unmanaged);
    // And kendex's own entry still resolves.
    row_for(
        &rows,
        HarnessId::Claude,
        &package(ItemKind::Hook, "block-worktree-refresh").unwrap(),
    );
}

/// A rule nobody installed keeps its own identity. The name it carries is
/// the one generated rules take, so a resolver reading names rather than
/// records would hand it the package's identity and its marketplace.
#[test]
#[allow(clippy::unwrap_used)]
fn an_unrecorded_rule_that_looks_generated_stays_its_own() {
    let f = fixture("[hooks.block-worktree-refresh]\nsource = \"cat\"\n");
    apply_now(&f);
    let rules = f.project.join(".cursor/rules");
    fs::write(
        rules.join("safety-block-argv-kill.mdc"),
        "---\ndescription: mine\n---\nBody.\n",
    )
    .unwrap();
    let rows = observed(&rows(&f), &f);
    let stray = rows
        .iter()
        .find(|row| row.name == "safety-block-argv-kill")
        .unwrap();
    assert_eq!(stray.package, None);
    assert_eq!(stray.origin, Origin::Unmanaged);
}

/// Every kind kendex installs resolves to the package it was declared as,
/// through whichever shape its tool stores it in — the audit the reported
/// hook defect asks for across the rest of the catalog.
#[test]
#[allow(clippy::unwrap_used)]
fn every_kind_resolves_to_the_package_it_was_declared_as() {
    let f = fixture(&EVERY_KIND.concat());
    apply_now(&f);
    let rows = observed(&rows(&f), &f);
    let catalog = f.home.join("catalog");
    // One row per (tool, package) under the declared identity, whatever
    // the tool wrote: an agent file, a skill tree, an entry in a shared
    // config file, a registered hook, an advisory rule.
    let expected = [
        (HarnessId::Claude, ItemKind::Agent, "review"),
        (HarnessId::Claude, ItemKind::Skill, "gh"),
        (HarnessId::Claude, ItemKind::Command, "ship"),
        (HarnessId::Claude, ItemKind::McpServer, "fs"),
        (HarnessId::Claude, ItemKind::Hook, "block-worktree-refresh"),
        // Codex retired prompts, so a command lands as a skill tree under
        // the skill loader's name; the row is still the command.
        (HarnessId::Codex, ItemKind::Command, "ship"),
        (HarnessId::Cursor, ItemKind::Hook, "block-worktree-refresh"),
        (HarnessId::Gemini, ItemKind::Hook, "block-worktree-refresh"),
    ];
    for (harness, kind, name) in expected {
        let row = row_for(&rows, harness, &package(kind, name).unwrap());
        assert_eq!(
            row.origin,
            marketplace(&catalog),
            "{}/{} {name}",
            harness.name(),
            kind.name(),
        );
    }
    // A command Codex keeps as a skill, and a server that has no file of
    // its own: neither observed spelling is the package's.
    let command = row_for(
        &rows,
        HarnessId::Codex,
        &package(ItemKind::Command, "ship").unwrap(),
    );
    assert_eq!(command.kind, ItemKind::Skill);
    let server = row_for(
        &rows,
        HarnessId::Claude,
        &package(ItemKind::McpServer, "fs").unwrap(),
    );
    assert_eq!(server.name, "fs");
}

/// A generated artifact is kendex's own output, so it is never offered for
/// adoption or whole-file removal — while a rule nobody installed still is.
#[test]
#[allow(clippy::unwrap_used)]
fn a_generated_artifact_is_not_offered_as_unmanaged() {
    let f = fixture("[hooks.block-worktree-refresh]\nsource = \"cat\"\n");
    apply_now(&f);
    fs::write(
        f.project.join(".cursor/rules/safety-block-argv-kill.mdc"),
        "---\ndescription: mine\n---\nBody.\n",
    )
    .unwrap();
    let offered: Vec<String> = kendex_core::engine::unmanaged_here(&f.env, &f.scope)
        .into_iter()
        .map(|row| row.name)
        .collect();
    assert!(
        !offered.contains(&"safety-block-worktree-refresh".to_owned()),
        "kendex offered its own generated rule: {offered:?}"
    );
    assert!(
        offered.contains(&"safety-block-argv-kill".to_owned()),
        "a rule nobody installed went unreported: {offered:?}"
    );
}

/// A package switched off keeps its identity. The rename that switches it
/// off is what a tool sees, and the record still names the position the
/// install wrote, so a resolver reading one spelling would call kendex's
/// own switched-off artifact somebody else's file.
#[test]
#[allow(clippy::unwrap_used)]
fn a_switched_off_artifact_is_still_the_package_that_wrote_it() {
    let f = fixture("[hooks.block-worktree-refresh]\nsource = \"cat\"\nenabled = false\n");
    apply_now(&f);
    let rows = observed(&rows(&f), &f);
    let hook = PackageRef {
        kind: ItemKind::Hook,
        name: "block-worktree-refresh".to_owned(),
    };
    let cursor = row_for(&rows, HarnessId::Cursor, &hook);
    assert_eq!(cursor.kind, ItemKind::Agent);
    assert!(
        cursor.name.starts_with("safety-block-worktree-refresh"),
        "cursor row name: {}",
        cursor.name
    );
    assert_eq!(cursor.origin, marketplace(&f.home.join("catalog")));
}

/// The reported move: the project folder is renamed after the install. The
/// record states its positions against the root that wrote it, so a
/// resolver that never re-read them would lose every identity at once.
#[test]
#[allow(clippy::unwrap_used)]
fn identity_survives_a_move_of_the_project_folder() {
    let f = fixture("[hooks.block-worktree-refresh]\nsource = \"cat\"\n");
    apply_now(&f);
    let moved = f.home.join("dev/vsys-renamed");
    fs::rename(&f.project, &moved).unwrap();
    let f = Fixture {
        scope: Scope::Project {
            root: moved.clone(),
        },
        project: moved,
        ..f
    };
    let rows = observed(&rows(&f), &f);
    let hook = PackageRef {
        kind: ItemKind::Hook,
        name: "block-worktree-refresh".to_owned(),
    };
    let catalog = f.home.join("catalog");
    for harness in HarnessId::ALL {
        let row = row_for(&rows, harness, &hook);
        assert_eq!(
            row.origin,
            marketplace(&catalog),
            "{} origin after the move",
            harness.name()
        );
    }
}
