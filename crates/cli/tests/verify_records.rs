//! `kendex verify --json`: one record per row with the positions the engine
//! resolved, every kind and every awkward spelling included, and the two
//! bookkeeping files attested from the rows rather than trusted.
//!
//! The must-fail control for the record set is the verify before this
//! surface: it printed no positions and no document, so every read below
//! fails to parse. The control for the attestations is the same verify,
//! which walked whatever the record listed and read the inventory nowhere:
//! each edit in the table closed `0 failed` there, with the de-listing
//! measured at `1 checked, 1 OK` against `2 checked, 2 OK` before it.
#![cfg(unix)]

#[path = "../../test_util.rs"]
mod test_util;
use test_util::{rooted, source_path};

use std::fs;
use std::path::{Path, PathBuf};
use std::process::{Command, Output};

use kendex_core::attest::{Document, Foreign, Row, State};
use kendex_core::engine::Owns;
use kendex_core::model::HarnessId;
use kendex_core::process::Hardened;

#[allow(clippy::expect_used)]
fn kendex(home: &Path, cwd: &Path, args: &[&str]) -> Output {
    Command::new(env!("CARGO_BIN_EXE_kendex"))
        .args(args)
        .current_dir(cwd)
        .env_clear()
        .envs(test_util::fixture_env(home))
        .env("KENDEX_BACKGROUND_REFRESH", "off")
        .env("PATH", std::env::var("PATH").unwrap_or_default())
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

#[allow(clippy::unwrap_used)]
fn write(path: &Path, text: &str) {
    fs::create_dir_all(path.parent().unwrap()).unwrap();
    fs::write(path, text).unwrap();
}

fn repository(dir: &Path) {
    git(dir, &["init", "-q", "-b", "main"]);
    git(dir, &["config", "user.email", "t@t"]);
    git(dir, &["config", "user.name", "t"]);
    git(dir, &["config", "commit.gpgsign", "false"]);
    git(dir, &["config", "core.hooksPath", ".git/hooks"]);
}

fn commit(dir: &Path, message: &str) {
    git(dir, &["add", "-A"]);
    git(dir, &["commit", "-q", "-m", message]);
}

/// The commit the installed consumer is tagged at.
const INSTALLED: &str = "installed";

struct World {
    _tmp: tempfile::TempDir,
    home: PathBuf,
    project: PathBuf,
    catalog: PathBuf,
}

/// A consumer with one item of every kind installed, on the awkward names:
/// a scoped Pi extension, a command whose declared name a skill has taken
/// on a harness that stores commands as skills, a plugin-sourced
/// `<plugin>/<item>` on an `Any`-rule harness and on a kebab one, and one
/// skill on two harnesses. The catalog is a git repository declared by
/// URL, so the record carries a source commit; the plugin registry is a
/// path source beside it. Installed, committed and tagged.
#[allow(clippy::unwrap_used)]
fn world() -> World {
    let tmp = tempfile::tempdir().unwrap();
    let home = rooted(&tmp);
    let catalog = home.join("cat");
    let market = home.join("market");
    let project = home.join("dev/app");

    write(&catalog.join("kendex.toml"), "[catalog]\n");
    write(
        &catalog.join("skills/second/SKILL.md"),
        "---\nname: second\ndescription: a second skill\n---\n# Second\n\nBody.\n",
    );
    write(
        &catalog.join("agents/review.md"),
        "---\nname: review\ndescription: reviews\n---\n\nReview it.\n",
    );
    write(
        &catalog.join("hooks/guard.sh"),
        "#!/usr/bin/env bash\n# ---\n# name: guard\n# event: PreToolUse\n# matcher: Bash\n# description: guard\n# ---\nexit 0\n",
    );
    write(&catalog.join("commands/second.md"), "Ship the branch.\n");
    write(
        &catalog.join("mcp/gh.toml"),
        "command = \"gh-mcp\"\nargs = [\"--stdio\"]\n",
    );
    let package = "{\n  \"name\": \"@scope/widgets\",\n  \"version\": \"1.0.0\",\n  \"pi\": { \"extensions\": [\"index.js\"] }\n}\n";
    let index = "export const version = 1;\n";
    write(
        &catalog.join("pi-extensions/@scope/widgets/package.json"),
        package,
    );
    write(
        &catalog.join("pi-extensions/@scope/widgets/index.js"),
        index,
    );
    repository(&catalog);
    commit(&catalog, "catalog");

    write(
        &market.join(".claude-plugin/marketplace.json"),
        r#"{"name": "workflows", "owner": {"name": "w"}, "metadata": {"description": "workflows", "version": "1.0.0"},
 "plugins": [{"name": "data-science", "source": "./plugins/data-science", "version": "0.4.0", "description": "analysis"}]}
"#,
    );
    write(
        &market.join("plugins/data-science/.claude-plugin/plugin.json"),
        "{\"name\": \"data-science\", \"version\": \"0.4.0\"}\n",
    );
    write(
        &market.join("plugins/data-science/skills/eda/SKILL.md"),
        "---\nname: eda\ndescription: explore\n---\n\nLook.\n",
    );

    // The carrier package sits where update-pi records it: the payload is
    // the catalog's bytes and nothing runs npm for a package with no
    // dependencies.
    write(
        &project.join(".pi/packages/@scope/widgets/package.json"),
        package,
    );
    write(&project.join(".pi/packages/@scope/widgets/index.js"), index);
    write(
        &project.join(".pi/settings.json"),
        "{\"packages\": [\"./packages/@scope/widgets\"]}\n",
    );
    fs::create_dir_all(project.join(".claude")).unwrap();
    write(
        &project.join("kendex.toml"),
        &format!(
            "schema = 6\n\n[sources.cat]\nrepo = \"file://{}\"\n\n[sources.market]\n{}\n\n[install]\nharnesses = [\"claude\", \"codex\", \"opencode\", \"pi\"]\nmethod = \"copy\"\n\n[skills.second]\nsource = \"cat\"\nharnesses = [\"claude\", \"codex\"]\n\n[skills.\"data-science/eda\"]\nsource = \"market\"\nharnesses = [\"claude\", \"opencode\"]\n\n[agents.review]\nsource = \"cat\"\nharnesses = [\"claude\"]\n\n[hooks.guard]\nsource = \"cat\"\nharnesses = [\"claude\"]\n\n[commands.second]\nsource = \"cat\"\nharnesses = [\"codex\"]\n\n[mcp-servers.gh]\nsource = \"cat\"\nharnesses = [\"claude\"]\n\n[pi-extensions.\"@scope/widgets\"]\nsource = \"cat\"\n\n[plugins.\"fmt@market\"]\nenabled = true\nharness = \"claude\"\n",
            catalog.display(),
            source_path(&market),
        ),
    );
    write(&project.join("AGENTS.md"), "# app\n");
    repository(&project);
    commit(&project, "before kendex");

    for args in [
        &["source", "refresh"][..],
        &["update-pi", "--scope", "project"],
        &["apply", "-y", "--leave"],
    ] {
        let output = kendex(&home, &project, args);
        assert!(
            output.status.success(),
            "kendex {args:?}: {}",
            said(&output)
        );
    }
    commit(&project, "installed");
    git(&project, &["tag", INSTALLED]);
    World {
        _tmp: tmp,
        home,
        project,
        catalog,
    }
}

/// One verify run in the project, with the document it printed.
#[allow(clippy::unwrap_used)]
fn verify(world: &World, base: Option<&str>) -> (Output, Document) {
    let mut args = vec!["verify", "--scope", "project", "--json"];
    if let Some(base) = base {
        args.extend(["--base", base]);
    }
    let output = kendex(&world.home, &world.project, &args);
    let document: Document = serde_json::from_slice(&output.stdout)
        .unwrap_or_else(|error| panic!("the document does not parse: {error}\n{}", said(&output)));
    (output, document)
}

fn row<'a>(
    document: &'a Document,
    kind: &str,
    name: &str,
    harness: Option<HarnessId>,
) -> Option<&'a Row> {
    document
        .rows
        .iter()
        .find(|row| row.kind == kind && row.name == name && row.harness == harness)
}

/// One row the fixture prints: kind, name, harness, and its positions as
/// (path, owns, foreign).
type Expected = (
    &'static str,
    &'static str,
    Option<HarnessId>,
    Vec<(&'static str, Owns, Option<Foreign>)>,
);

/// Every row the fixture consumer prints, with the positions the engine
/// resolved for it. The four naming shapes are all here: the scoped Pi
/// extension nested two segments under packages/, the command installed
/// under a suffixed name, the plugin-sourced item folded on `__` for
/// Claude and on `-` for OpenCode, and one leaf on two harnesses.
fn expected_rows() -> Vec<Expected> {
    let keys = Some(Foreign::Unchanged);
    let claude = Some(HarnessId::Claude);
    vec![
        (
            "agent",
            "review",
            claude,
            vec![(".claude/agents/review.md", Owns::File, None)],
        ),
        (
            "command",
            "second",
            Some(HarnessId::Codex),
            vec![(".agents/skills/second__command", Owns::Tree, None)],
        ),
        (
            "hook",
            "guard",
            claude,
            vec![
                (".claude/hooks/guard.sh", Owns::File, None),
                (".claude/settings.json", Owns::Keys, keys),
            ],
        ),
        (
            "mcp-server",
            "gh",
            claude,
            vec![(".mcp.json", Owns::Keys, keys)],
        ),
        (
            "pi-extension",
            "@scope/widgets",
            Some(HarnessId::Pi),
            vec![(".pi/packages/@scope/widgets", Owns::Tree, None)],
        ),
        (
            "plugin",
            "fmt@market",
            claude,
            vec![(".claude/settings.json", Owns::Keys, keys)],
        ),
        (
            "skill",
            "data-science/eda",
            claude,
            vec![(".claude/skills/data-science__eda", Owns::Tree, None)],
        ),
        (
            "skill",
            "data-science/eda",
            Some(HarnessId::Opencode),
            vec![(".opencode/skills/data-science-eda", Owns::Tree, None)],
        ),
        (
            "skill",
            "second",
            claude,
            vec![(".claude/skills/second", Owns::Tree, None)],
        ),
        (
            "skill",
            "second",
            Some(HarnessId::Codex),
            vec![(".agents/skills/second", Owns::Tree, None)],
        ),
        (
            "shim",
            "CLAUDE.md",
            claude,
            vec![("CLAUDE.md", Owns::File, None)],
        ),
        (
            "record",
            ".kendex-lock.json",
            None,
            vec![(".kendex-lock.json", Owns::File, None)],
        ),
        (
            "inventory",
            ".kendex-generated.json",
            None,
            vec![(".kendex-generated.json", Owns::File, None)],
        ),
    ]
}

/// The rows a consumer of every kind prints, each with the positions the
/// engine resolved: the four naming shapes are all answered from the row,
/// so a reader owning paths needs no naming rule of its own. Each position
/// is also the shape on disk it claims to be.
#[test]
#[allow(clippy::unwrap_used)]
fn every_row_prints_the_positions_it_rendered() {
    let world = world();
    let (output, document) = verify(&world, Some(INSTALLED));
    assert!(output.status.success(), "{}", said(&output));
    assert!(document.clean, "{document:?}");
    assert_eq!((document.checked, document.failed), (10, 0), "{document:?}");
    let expected = expected_rows();
    assert_eq!(document.rows.len(), expected.len(), "{document:?}");
    for (kind, name, harness, positions) in expected {
        let found = row(&document, kind, name, harness)
            .unwrap_or_else(|| panic!("no row for {kind} {name} {harness:?}: {document:?}"));
        assert_eq!(found.state, State::Ok, "{found:?}");
        let printed: Vec<(&str, Owns, Option<Foreign>)> = found
            .positions
            .iter()
            .map(|position| (position.path.as_str(), position.owns, position.foreign))
            .collect();
        assert_eq!(printed, positions, "{kind} {name} {harness:?}");
        for (path, owns, _) in positions {
            let at = world.project.join(path);
            let shape = match owns {
                Owns::Tree => at.is_dir(),
                Owns::File | Owns::Keys => at.is_file(),
            };
            assert!(shape, "{path} is not the {owns:?} the row says it is");
        }
    }

    // Without a base revision a keys position carries no judgement, and
    // the field is absent rather than answered.
    let (_, without_base) = verify(&world, None);
    let hook = row(&without_base, "hook", "guard", Some(HarnessId::Claude)).unwrap();
    assert_eq!(
        hook.positions
            .iter()
            .map(|position| position.foreign)
            .collect::<Vec<_>>(),
        vec![None, None],
        "{hook:?}"
    );
}

/// One edit to the JSON document at `path`.
#[allow(clippy::unwrap_used)]
fn edit_json(path: &Path, edit: impl Fn(&mut serde_json::Value)) {
    let mut value: serde_json::Value =
        serde_json::from_str(&fs::read_to_string(path).unwrap()).unwrap();
    edit(&mut value);
    fs::write(
        path,
        format!("{}\n", serde_json::to_string_pretty(&value).unwrap()),
    )
    .unwrap();
}

#[allow(clippy::unwrap_used)]
fn move_entry(lock: &mut serde_json::Value, from: &str, to: &str, field: &str, value: &str) {
    let entries = lock["entries"].as_object_mut().unwrap();
    let mut entry = entries.remove(from).unwrap();
    entry[field] = serde_json::Value::String(value.to_owned());
    entries.insert(to.to_owned(), entry);
}

#[allow(clippy::unwrap_used)]
fn drop_from_inventory(inventory: &mut serde_json::Value, path: &str) {
    inventory
        .as_array_mut()
        .unwrap()
        .retain(|listed| listed.as_str() != Some(path));
}

/// One edit to the checked-out consumer.
type Edit = Box<dyn Fn(&World)>;
/// One row an edit fails as: kind, name, harness, state, and text its
/// detail holds.
type Failing = (
    &'static str,
    &'static str,
    Option<HarnessId>,
    State,
    &'static str,
);

const CLAUDE_SECOND: &str = ".claude/skills/second/SKILL.md";
const RECORD: &str = ".kendex-lock.json";
const INVENTORY: &str = ".kendex-generated.json";

fn on_record(edit: impl Fn(&mut serde_json::Value) + 'static) -> Edit {
    Box::new(move |world| edit_json(&world.project.join(RECORD), &edit))
}

fn on_inventory(edit: impl Fn(&mut serde_json::Value) + 'static) -> Edit {
    Box::new(move |world| edit_json(&world.project.join(INVENTORY), &edit))
}

#[allow(clippy::unwrap_used)]
fn without_entry(value: &mut serde_json::Value) {
    value["entries"]
        .as_object_mut()
        .unwrap()
        .remove("skill:second:claude");
}

fn delisted(value: &mut serde_json::Value) {
    drop_from_inventory(value, CLAUDE_SECOND);
}

/// The gap the declaration `skill second` on Claude leaves when its entry
/// is gone.
const GAP: Failing = (
    "skill",
    "second",
    Some(HarnessId::Claude),
    State::Unrecorded,
    "",
);

fn record_fails(detail: &'static str) -> Failing {
    ("record", RECORD, None, State::Failed, detail)
}

fn inventory_fails(detail: &'static str) -> Failing {
    ("inventory", INVENTORY, None, State::Failed, detail)
}

/// Each way a branch can edit what it is judged by, and the rows that
/// fail it.
fn bookkeeping_edits() -> Vec<(&'static str, Edit, Vec<Failing>)> {
    let mut edits = narrowing_edits();
    edits.extend(moving_edits());
    edits
}

/// The edits that narrow or repoint what the proof reads.
#[allow(clippy::unwrap_used)]
fn narrowing_edits() -> Vec<(&'static str, Edit, Vec<Failing>)> {
    let record = record_fails;
    let inventory = inventory_fails;
    let gap = GAP;
    vec![
        (
            "de-lists a path the engine still renders",
            on_inventory(delisted),
            vec![inventory(
                "de-lists .claude/skills/second/SKILL.md, which this pass renders",
            )],
        ),
        (
            "lists a path the engine does not render",
            on_inventory(|value| {
                value
                    .as_array_mut()
                    .unwrap()
                    .push(".claude/skills/ghost/SKILL.md".into());
            }),
            vec![inventory(
                "lists .claude/skills/ghost/SKILL.md, which this pass does not render",
            )],
        ),
        (
            "deletes a record entry its manifest declares",
            on_record(without_entry),
            vec![gap],
        ),
        (
            "repoints a source commit",
            on_record(|value| {
                value["sources"]["cat"]["commit"] =
                    "deadbeefdeadbeefdeadbeefdeadbeefdeadbeef".into();
            }),
            vec![record(
                "source cat: commit deadbeefdeadbeefdeadbeefdeadbeefdeadbeef is not on the declared revision's history",
            )],
        ),
        (
            "widens a recorded position",
            on_record(|value| {
                value["entries"]["skill:second:claude"]["emitted"]["paths"] =
                    serde_json::json!([".claude"]);
            }),
            vec![record(
                "skill:second:claude: emitted is not what this pass records",
            )],
        ),
    ]
}

/// The edits that move an entry, write both files at once, or edit under
/// a rendered position.
#[allow(clippy::unwrap_used)]
fn moving_edits() -> Vec<(&'static str, Edit, Vec<Failing>)> {
    let record = record_fails;
    let inventory = inventory_fails;
    let gap = GAP;
    vec![
        (
            "hand-writes both files in one commit",
            Box::new(|world| {
                edit_json(&world.project.join(RECORD), without_entry);
                edit_json(&world.project.join(INVENTORY), delisted);
            }),
            vec![
                gap,
                inventory("de-lists .claude/skills/second/SKILL.md, which this pass renders"),
            ],
        ),
        (
            "adds a hand-written top-level key to the record",
            on_record(|value| value["planted"] = 1.into()),
            vec![record("not laid out as kendex writes it")],
        ),
        (
            "moves an entry to another kind",
            on_record(|value| {
                move_entry(
                    value,
                    "skill:second:claude",
                    "command:second:claude",
                    "kind",
                    "command",
                );
            }),
            vec![
                (
                    "command",
                    "second",
                    Some(HarnessId::Claude),
                    State::Failed,
                    "nothing needs it",
                ),
                gap,
            ],
        ),
        (
            "moves an entry to another harness",
            on_record(|value| {
                move_entry(
                    value,
                    "skill:second:claude",
                    "skill:second:pi",
                    "harness",
                    "pi",
                );
            }),
            vec![
                (
                    "skill",
                    "second",
                    Some(HarnessId::Pi),
                    State::Failed,
                    "nothing needs it",
                ),
                gap,
            ],
        ),
        (
            "edits a rendered agent by hand",
            Box::new(|world| {
                let agent = world.project.join(".claude/agents/review.md");
                let text = fs::read_to_string(&agent).unwrap();
                fs::write(&agent, format!("{text}\nA LINE NO RENDER PRODUCED.\n")).unwrap();
            }),
            vec![(
                "agent",
                "review",
                Some(HarnessId::Claude),
                State::Failed,
                "edited on disk since install",
            )],
        ),
    ]
}

/// Each way a branch can edit what it is judged by is a failed row and a
/// non-zero close. The record and the inventory are attested, never
/// trusted: deleting an entry no longer shrinks the proof in silence, a
/// repointed source commit no longer passes, a widened position no longer
/// stands, and an entry moved to another kind or harness is a failed row
/// beside a gap for the declaration it abandoned. A hand edit under a
/// rendered position is the row that still fails as it always did.
#[test]
#[allow(clippy::unwrap_used)]
fn every_bookkeeping_edit_is_a_failed_row_and_a_non_zero_close() {
    let world = world();
    for (label, edit, failing) in bookkeeping_edits() {
        git(&world.project, &["checkout", "-q", "-B", "case", INSTALLED]);
        edit(&world);
        commit(&world.project, label);
        let (output, document) = verify(&world, Some(INSTALLED));
        assert!(!output.status.success(), "{label}: {}", said(&output));
        assert!(!document.clean, "{label}: {document:?}");
        for (kind, name, harness, state, detail) in failing {
            let found = row(&document, kind, name, harness).unwrap_or_else(|| {
                panic!("{label}: no row for {kind} {name} {harness:?}: {document:?}")
            });
            assert_eq!(found.state, state, "{label}: {found:?}");
            assert!(
                found.detail.as_deref().unwrap_or_default().contains(detail),
                "{label}: {found:?} does not say {detail:?}"
            );
        }
    }
}

/// A key the person adds beside kendex's in a registry file is a change
/// the row cannot vouch for: the position is still kendex's keys, the
/// keys are still in sync, and the rest of the file moved.
#[test]
#[allow(clippy::unwrap_used)]
fn a_key_added_beside_kendexs_is_a_foreign_change() {
    let world = world();
    git(&world.project, &["checkout", "-q", "-B", "case", INSTALLED]);
    edit_json(&world.project.join(".claude/settings.json"), |value| {
        value["hooks"]["Stop"] =
            serde_json::json!([{"hooks": [{"type": "command", "command": "echo mine"}]}]);
    });
    commit(&world.project, "a hook of the person's own");
    let (output, document) = verify(&world, Some(INSTALLED));
    assert!(output.status.success(), "{}", said(&output));
    let hook = row(&document, "hook", "guard", Some(HarnessId::Claude)).unwrap();
    let settings = hook
        .positions
        .iter()
        .find(|position| position.path == ".claude/settings.json")
        .unwrap();
    assert_eq!(settings.foreign, Some(Foreign::Changed), "{hook:?}");
    let server = row(&document, "mcp-server", "gh", Some(HarnessId::Claude)).unwrap();
    assert_eq!(
        server.positions[0].foreign,
        Some(Foreign::Unchanged),
        "{server:?}"
    );
}

/// A record behind a catalog that moved without touching any render is an
/// honest record: its commit is on the declared revision's history, and
/// nothing about it fails the run.
#[test]
#[allow(clippy::unwrap_used)]
fn a_record_behind_a_catalog_that_rendered_nothing_new_passes() {
    let world = world();
    write(&world.catalog.join("NOTES.md"), "notes\n");
    commit(&world.catalog, "a file no render reads");
    let refreshed = kendex(&world.home, &world.project, &["source", "refresh"]);
    assert!(refreshed.status.success(), "{}", said(&refreshed));
    let recorded: serde_json::Value =
        serde_json::from_str(&fs::read_to_string(world.project.join(".kendex-lock.json")).unwrap())
            .unwrap();
    assert_ne!(
        recorded["sources"]["cat"]["commit"].as_str().unwrap(),
        git(&world.catalog, &["rev-parse", "HEAD"]).trim(),
        "the fixture needs a record behind the catalog"
    );
    let (output, document) = verify(&world, Some(INSTALLED));
    assert!(output.status.success(), "{}", said(&output));
    assert_eq!(
        row(&document, "record", ".kendex-lock.json", None)
            .unwrap()
            .state,
        State::Ok
    );
}
