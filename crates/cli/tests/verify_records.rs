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
use kendex_core::env::Env;
use kendex_core::lock::LOCK_VERSION;
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
/// path source beside it. The catalog also publishes one set, installed on
/// the harness its member already sits on, so the record carries a set
/// without a row of its own. The catalog's repository is declared three
/// times, under one mirror: `cat` for the items, `picat` for the Pi
/// extension alone, and `spare` for nothing, the state a source is in
/// after its last package is removed. Installed, committed and tagged.
#[allow(clippy::unwrap_used)]
fn world() -> World {
    let tmp = tempfile::tempdir().unwrap();
    let home = rooted(&tmp);
    let catalog = home.join("cat");
    let market = home.join("market");
    let project = home.join("dev/app");

    write(
        &catalog.join("kendex.toml"),
        "[catalog]\n\n[bundles.starter]\ndescription = \"the starter set\"\nskills = [\"second\"]\n",
    );
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
            "schema = 6\n\n[sources.cat]\nrepo = \"file://{catalog}\"\n\n[sources.picat]\nrepo = \"file://{catalog}\"\n\n[sources.spare]\nrepo = \"file://{catalog}\"\n\n[sources.market]\n{}\n\n[install]\nharnesses = [\"claude\", \"codex\", \"opencode\", \"pi\", \"gemini\"]\nmethod = \"copy\"\n\n[skills.second]\nsource = \"cat\"\nharnesses = [\"claude\", \"codex\"]\n\n[skills.\"data-science/eda\"]\nsource = \"market\"\nharnesses = [\"claude\", \"opencode\"]\n\n[agents.review]\nsource = \"cat\"\nharnesses = [\"claude\"]\n\n[hooks.guard]\nsource = \"cat\"\nharnesses = [\"claude\"]\n\n[commands.second]\nsource = \"cat\"\nharnesses = [\"codex\"]\n\n[mcp-servers.gh]\nsource = \"cat\"\nharnesses = [\"claude\"]\n\n[pi-extensions.\"@scope/widgets\"]\nsource = \"picat\"\n\n[plugins.\"fmt@market\"]\nenabled = true\nharness = \"claude\"\n\n[bundles.starter]\nsource = \"cat\"\nharnesses = [\"codex\"]\n",
            source_path(&market),
            catalog = catalog.display(),
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

/// One verify run of the project scope, with the document it printed.
fn verify(world: &World, base: Option<&str>) -> (Output, Document) {
    verify_scope(world, "project", base)
}

/// One verify run of `scope` from the project, with the document it
/// printed.
fn verify_scope(world: &World, scope: &str, base: Option<&str>) -> (Output, Document) {
    verify_from(&world.home, &world.project, scope, base)
}

/// One verify run of `scope` from `cwd`, with the document it printed.
#[allow(clippy::unwrap_used)]
fn verify_from(home: &Path, cwd: &Path, scope: &str, base: Option<&str>) -> (Output, Document) {
    let mut args = vec!["verify", "--scope", scope, "--json"];
    if let Some(base) = base {
        args.extend(["--base", base]);
    }
    let output = kendex(home, cwd, &args);
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
/// Claude and on `-` for OpenCode, and one leaf on two harnesses. Both
/// shim shapes are here too: the Claude shim that is a whole file, and
/// the Gemini one that is a key in a settings document, judged against
/// the base revision like every other keys position.
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
            "shim",
            ".gemini/settings.json",
            Some(HarnessId::Gemini),
            vec![(".gemini/settings.json", Owns::Keys, keys)],
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
/// detail holds — or `None` for a row that carries no detail at all, which
/// is what a gap row is.
type Failing = (
    &'static str,
    &'static str,
    Option<HarnessId>,
    State,
    Option<String>,
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
    None,
);

fn record_fails(detail: &str) -> Failing {
    (
        "record",
        RECORD,
        None,
        State::Failed,
        Some(detail.to_owned()),
    )
}

fn inventory_fails(detail: &str) -> Failing {
    (
        "inventory",
        INVENTORY,
        None,
        State::Failed,
        Some(detail.to_owned()),
    )
}

/// One record entry's field is not what the pass records, as the record
/// row names it: the entry's key, then the field as the record spells it.
fn field_fails(key: &str, field: &str) -> Failing {
    record_fails(&format!("{key}: {field} is not what this pass records"))
}

/// One record entry's kind, name or harness is not what its key spells,
/// as the record row names it.
fn key_fails(key: &str) -> Failing {
    record_fails(&format!("{key}: not the entry it names"))
}

/// Every keys position the project scope prints, with its judgement.
fn keys_judged(document: &Document) -> Vec<(&str, Option<Foreign>)> {
    document
        .rows
        .iter()
        .flat_map(|row| row.positions.iter())
        .filter(|position| position.owns == Owns::Keys)
        .map(|position| (position.path.as_str(), position.foreign))
        .collect()
}

/// The project scope's keys positions, every one answered `unknown`.
fn every_key_unknown() -> Vec<(&'static str, Option<Foreign>)> {
    vec![
        (".claude/settings.json", Some(Foreign::Unknown)),
        (".mcp.json", Some(Foreign::Unknown)),
        (".claude/settings.json", Some(Foreign::Unknown)),
        (".gemini/settings.json", Some(Foreign::Unknown)),
    ]
}

/// Each way a branch can edit what it is judged by, and the rows that
/// fail it. The revision-expression rows plant a name the mirror resolves
/// to the declared tip itself, so only a refusal to ask git about a value
/// that is not a pin can fail them.
fn bookkeeping_edits(world: &World) -> Vec<(&'static str, Edit, Vec<Failing>)> {
    let mut edits = narrowing_edits();
    edits.extend(moving_edits());
    edits.extend(field_edits());
    edits.extend(provenance_edits(&world.catalog));
    edits.extend(inventory_edits());
    edits
}

/// One row per field the record row compares an entry on: each planted
/// value is a valid one that round-trips through the record's layout, so
/// only the comparison with what the pass records can catch it, and each
/// row pins the field's own name. The kind, name and harness are held to
/// the key instead, whatever the plan carries under it. The source
/// repository is the exception the engine makes: a recorded source is
/// never silently rebound, so the plan keeps the entry as recorded and
/// the installation's own row is the one that fails.
const SECOND: &str = "skill:second:claude";

#[allow(clippy::unwrap_used)]
fn field_edits() -> Vec<(&'static str, Edit, Vec<Failing>)> {
    let second = SECOND;
    let on_second = |field: &'static str, value: serde_json::Value| {
        on_record(move |lock| lock["entries"][SECOND][field] = value.clone())
    };
    vec![
        (
            "renames an entry under its own key",
            on_second("name", "other".into()),
            vec![key_fails(second)],
        ),
        (
            "records an entry as another kind under its own key",
            on_second("kind", "agent".into()),
            vec![key_fails(second)],
        ),
        (
            "records an entry on another harness under its own key",
            on_second("harness", "codex".into()),
            vec![key_fails(second)],
        ),
        (
            "records an entry from another declared source",
            on_second("source", "market".into()),
            vec![field_fails(second, "source")],
        ),
        (
            "records an entry from another repository",
            on_second("sourceRepo", "other/repo".into()),
            vec![(
                "skill",
                "second",
                Some(HarnessId::Claude),
                State::Failed,
                Some("installed from other/repo but now set to come from".to_owned()),
            )],
        ),
        (
            "plants a source hash",
            on_second("sourceHash", "planted".into()),
            vec![field_fails(second, "sourceHash")],
        ),
        (
            "plants a rendered hash",
            on_second("renderedHash", "planted".into()),
            vec![field_fails(second, "renderedHash")],
        ),
        (
            "records an enabled entry as disabled",
            on_second("enabled", false.into()),
            vec![field_fails(second, "enabled")],
        ),
        (
            "records upstream skills on a skill",
            on_second("upstreamSkills", serde_json::json!(["planted"])),
            vec![field_fails(second, "upstreamSkills")],
        ),
        (
            "drops an entry's reasons",
            on_record(|lock| {
                lock["entries"][SECOND]
                    .as_object_mut()
                    .unwrap()
                    .remove("reasons");
            }),
            vec![field_fails(second, "reasons")],
        ),
        (
            "drops an entry's source commit",
            on_record(|lock| {
                lock["entries"][SECOND]
                    .as_object_mut()
                    .unwrap()
                    .remove("sourceCommit");
            }),
            vec![field_fails(second, "sourceCommit")],
        ),
        (
            "moves a hook's registration to another event",
            on_record(|lock| {
                lock["entries"]["hook:guard:claude"]["registration"]["event"] = "Stop".into();
            }),
            vec![field_fails("hook:guard:claude", "registration")],
        ),
    ]
}

/// The source and set readings of the record row: a recorded source or
/// set the manifest does not declare, one recorded for another repository
/// or from another source, and a set's commit off the declared revision's
/// history. The source's off-history commit is the `repoints a source
/// commit` row above. The `spare` rows plant the same edits on the source
/// nothing uses: the pass resolves it for no item, so only a resolution
/// made for the record's sake can hold the entry to the declaration.
fn provenance_edits(catalog: &Path) -> Vec<(&'static str, Edit, Vec<Failing>)> {
    let record = record_fails;
    let catalog = format!("file://{}", catalog.display());
    vec![
        (
            "records an unused source for another repository",
            on_record(|lock| lock["sources"]["spare"]["repo"] = "other/repo".into()),
            vec![record(&format!(
                "source spare: recorded for other/repo at the source's own revision, declared as {catalog} at the source's own revision"
            ))],
        ),
        (
            "records an unused source at another revision",
            on_record(|lock| lock["sources"]["spare"]["rev"] = "v1".into()),
            vec![record(&format!(
                "source spare: recorded for {catalog} at v1, declared as {catalog} at the source's own revision"
            ))],
        ),
        (
            "repoints an unused source's commit",
            on_record(|lock| {
                lock["sources"]["spare"]["commit"] =
                    "deadbeefdeadbeefdeadbeefdeadbeefdeadbeef".into();
            }),
            vec![record(
                "source spare: commit deadbeefdeadbeefdeadbeefdeadbeefdeadbeef is not on the declared revision's history",
            )],
        ),
        (
            "records a source the manifest does not declare",
            on_record(|lock| {
                lock["sources"]["ghost"] = serde_json::json!({
                    "repo": "ghost/repo",
                    "commit": "deadbeefdeadbeefdeadbeefdeadbeefdeadbeef"
                });
            }),
            vec![record(
                "source ghost: recorded, and the manifest declares no enabled repository source by that name",
            )],
        ),
        (
            "records a path source",
            on_record(|lock| {
                lock["sources"]["market"] = serde_json::json!({
                    "repo": "market/repo",
                    "commit": "deadbeefdeadbeefdeadbeefdeadbeefdeadbeef"
                });
            }),
            vec![record(
                "source market: recorded, and the manifest declares no enabled repository source by that name",
            )],
        ),
        (
            "records a source for another repository",
            on_record(|lock| lock["sources"]["cat"]["repo"] = "other/repo".into()),
            vec![record("source cat: recorded for other/repo at")],
        ),
        (
            "records a set the manifest does not declare",
            on_record(|lock| {
                lock["bundles"]["ghost"] = serde_json::json!({
                    "source": "cat",
                    "sourceRepo": "ghost/repo",
                    "commit": "deadbeefdeadbeefdeadbeefdeadbeefdeadbeef"
                });
            }),
            vec![record(
                "set ghost: recorded, and the manifest declares no such set from an enabled repository source",
            )],
        ),
        (
            "records a set from another source",
            on_record(|lock| lock["bundles"]["starter"]["source"] = "market".into()),
            vec![record("set starter: recorded from market (")],
        ),
        (
            "repoints a set's commit",
            on_record(|lock| {
                lock["bundles"]["starter"]["commit"] =
                    "deadbeefdeadbeefdeadbeefdeadbeefdeadbeef".into();
            }),
            vec![record(
                "set starter: commit deadbeefdeadbeefdeadbeefdeadbeefdeadbeef is not on the declared revision's history",
            )],
        ),
        (
            "records a set's commit as a revision expression",
            on_record(|lock| {
                lock["bundles"]["starter"]["commit"] = "HEAD".into();
            }),
            vec![record("set starter: commit HEAD is not a commit pin")],
        ),
    ]
}

/// The inventory row's other three readings: a file that is not a list of
/// paths, one the pass would write that is not there, and one holding the
/// right paths in a layout kendex does not lay down.
#[allow(clippy::unwrap_used)]
fn inventory_edits() -> Vec<(&'static str, Edit, Vec<Failing>)> {
    let inventory = inventory_fails;
    vec![
        (
            "writes a number over the inventory",
            Box::new(|world| fs::write(world.project.join(INVENTORY), "1\n").unwrap()),
            vec![inventory("not a JSON list of paths")],
        ),
        (
            "deletes the inventory",
            Box::new(|world| fs::remove_file(world.project.join(INVENTORY)).unwrap()),
            vec![inventory("not written yet")],
        ),
        (
            "lays the inventory out on one line",
            Box::new(|world| {
                let path = world.project.join(INVENTORY);
                let listed: serde_json::Value =
                    serde_json::from_str(&fs::read_to_string(&path).unwrap()).unwrap();
                fs::write(
                    &path,
                    format!("{}\n", serde_json::to_string(&listed).unwrap()),
                )
                .unwrap();
            }),
            vec![inventory("not laid out as kendex writes it")],
        ),
    ]
}

/// The edits that narrow or repoint what the proof reads.
#[allow(clippy::unwrap_used)]
fn narrowing_edits() -> Vec<(&'static str, Edit, Vec<Failing>)> {
    let record = record_fails;
    let inventory = inventory_fails;
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
            vec![GAP],
        ),
        (
            "deletes a recorded source its manifest declares",
            on_record(|value| {
                value["sources"].as_object_mut().unwrap().remove("cat");
            }),
            vec![record(
                "source cat: declared, and the record does not carry it",
            )],
        ),
        (
            "deletes a recorded set its manifest declares",
            on_record(|value| {
                value["bundles"].as_object_mut().unwrap().remove("starter");
            }),
            vec![record(
                "set starter: declared, and the record does not carry it",
            )],
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
            "repoints an entry's source commit",
            on_record(|value| {
                value["entries"]["skill:second:claude"]["sourceCommit"] =
                    "deadbeefdeadbeefdeadbeefdeadbeefdeadbeef".into();
            }),
            vec![record(
                "skill:second:claude: sourceCommit deadbeefdeadbeefdeadbeefdeadbeefdeadbeef is not on the declared revision's history",
            )],
        ),
        (
            "records a source commit as a revision expression",
            on_record(|value| {
                value["sources"]["cat"]["commit"] = "HEAD".into();
            }),
            vec![record("source cat: commit HEAD is not a commit pin")],
        ),
        (
            "records an entry's source commit as a revision expression",
            on_record(|value| {
                value["entries"]["skill:second:claude"]["sourceCommit"] = "HEAD".into();
            }),
            vec![record(
                "skill:second:claude: sourceCommit HEAD is not a commit pin",
            )],
        ),
        (
            "records a Pi extension on another harness under its own key",
            on_record(|value| {
                value["entries"]["pi-extension:@scope/widgets:pi"]["harness"] = "claude".into();
            }),
            vec![key_fails("pi-extension:@scope/widgets:pi")],
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
    vec![
        (
            "hand-writes both files in one commit",
            Box::new(|world| {
                edit_json(&world.project.join(RECORD), without_entry);
                edit_json(&world.project.join(INVENTORY), delisted);
            }),
            vec![
                GAP,
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
                    Some("nothing needs it".to_owned()),
                ),
                GAP,
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
                    Some("nothing needs it".to_owned()),
                ),
                GAP,
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
                Some("edited on disk since install".to_owned()),
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
    for (label, edit, failing) in bookkeeping_edits(&world) {
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
            match detail {
                None => assert!(
                    found.detail.is_none(),
                    "{label}: {found:?} carries a detail"
                ),
                Some(detail) => assert!(
                    found
                        .detail
                        .as_deref()
                        .unwrap_or_default()
                        .contains(&detail),
                    "{label}: {found:?} does not say {detail:?}"
                ),
            }
        }
    }
}

/// A Pi extension name the manifest accepts and the package placer
/// refuses — npm wants a scope before `@` — is one declaration with no
/// installation: a gap row with no position, beside every other row the
/// scope still prints. The scope is not refused for it: `verify`, `apply`
/// and every reader of the plan keep working on the rest of the manifest.
#[test]
#[allow(clippy::unwrap_used)]
fn a_pi_extension_name_the_placer_refuses_is_a_gap_beside_the_other_rows() {
    let world = world();
    git(&world.project, &["checkout", "-q", "-B", "case", INSTALLED]);
    let manifest = world.project.join("kendex.toml");
    let text = fs::read_to_string(&manifest).unwrap();
    fs::write(
        &manifest,
        format!("{text}\n[pi-extensions.\"@plain\"]\nsource = \"cat\"\n"),
    )
    .unwrap();
    commit(&world.project, "a pi extension named as npm would refuse");
    let (output, document) = verify(&world, Some(INSTALLED));
    assert!(!output.status.success(), "{}", said(&output));
    assert!(
        !said(&output).contains("not checked"),
        "the scope was refused: {}",
        said(&output)
    );
    assert_eq!((document.checked, document.failed), (10, 0), "{document:?}");
    let gap = row(&document, "pi-extension", "@plain", None).unwrap();
    assert_eq!(
        (gap.state, gap.positions.len()),
        (State::Unrecorded, 0),
        "{gap:?}"
    );
    let widgets = row(
        &document,
        "pi-extension",
        "@scope/widgets",
        Some(HarnessId::Pi),
    )
    .unwrap();
    assert_eq!(widgets.state, State::Ok, "{widgets:?}");
    let planned = kendex(
        &world.home,
        &world.project,
        &["apply", "--scope", "project", "--plan"],
    );
    assert!(planned.status.success(), "{}", said(&planned));
}

/// The one mirror the fixture home holds: the catalog's. The plugin
/// registry is a path source and has none. The cache root is the one the
/// binary resolves under `fixture_env`, which differs per platform.
#[allow(clippy::unwrap_used)]
fn mirror(world: &World) -> PathBuf {
    let mirrors = Env::host_rooted(&world.home)
        .source_cache_dir()
        .join("mirrors");
    let mut found: Vec<PathBuf> = fs::read_dir(&mirrors)
        .unwrap()
        .map(|entry| entry.unwrap().path())
        .filter(|path| path.extension().is_some_and(|extension| extension == "git"))
        .collect();
    assert_eq!(
        found.len(),
        1,
        "one mirror under {}: {found:?}",
        mirrors.display()
    );
    found.remove(0)
}

/// A mirror that cannot serve the declared revision leaves the recorded
/// commit standing in for it, and everything rendered from that commit
/// was measured against a commit the record chose: the record row fails
/// by the source's name, and the run closes non-zero, while every render
/// row still passes. Here every ref is gone from the mirror and the
/// recorded commit is still published from it.
#[test]
#[allow(clippy::unwrap_used)]
fn a_source_served_from_the_records_own_commit_fails_the_record_row() {
    let world = world();
    let mirror = mirror(&world);
    let refs = git(&mirror, &["for-each-ref", "--format=%(refname)"]);
    assert!(!refs.trim().is_empty(), "the mirror holds refs to delete");
    for name in refs.lines().filter(|line| !line.is_empty()) {
        git(&mirror, &["update-ref", "-d", name]);
    }
    let (output, document) = verify(&world, Some(INSTALLED));
    assert!(!output.status.success(), "{}", said(&output));
    assert!(!document.clean, "{document:?}");
    let record = row(&document, "record", RECORD, None).unwrap();
    assert_eq!(record.state, State::Failed, "{record:?}");
    assert!(
        record.detail.as_deref().unwrap_or_default().contains(
            "source cat: the mirror cannot serve the declared revision, and the recorded commit stood in"
        ),
        "{record:?}"
    );
    assert_eq!((document.checked, document.failed), (10, 0), "{document:?}");
}

/// A source only a Pi extension names is resolved by the carrier, off the
/// path every other declaration's source takes to the record: where the
/// mirror cannot serve its revision, it is named in the record row all the
/// same. The mirror is stripped as above; `picat` is the source the row
/// has to name, beside `cat`.
#[test]
#[allow(clippy::unwrap_used)]
fn a_pi_only_source_served_from_the_records_own_commit_is_named_in_the_record_row() {
    let world = world();
    let mirror = mirror(&world);
    let refs = git(&mirror, &["for-each-ref", "--format=%(refname)"]);
    for name in refs.lines().filter(|line| !line.is_empty()) {
        git(&mirror, &["update-ref", "-d", name]);
    }
    let (output, document) = verify(&world, Some(INSTALLED));
    assert!(!output.status.success(), "{}", said(&output));
    let record = row(&document, "record", RECORD, None).unwrap();
    assert_eq!(record.state, State::Failed, "{record:?}");
    assert!(
        record
            .detail
            .as_deref()
            .unwrap_or_default()
            .contains("source picat: the mirror cannot serve the declared revision"),
        "{record:?}"
    );
}

/// One row of the table below: its label, the manifest text it replaces
/// and the replacement, the edit it makes to the record, the subject the
/// row may name, and what the record row must say, if anything.
type Unread<'a> = (
    &'a str,
    &'a str,
    &'a str,
    Option<Edit>,
    &'a str,
    Option<String>,
);

/// A recorded source or set the pass cannot read apart from the record is
/// never compared with itself. A switched-off source is recorded for
/// nothing, so its entry is one the pass would not write; one declared at
/// a repository nothing is fetched for, and a set pinned at a revision the
/// mirror cannot serve, have their entries carried forward unread, and the
/// row names them. The inverse row of each drops the entry from the
/// record, which leaves nothing to hold and nothing named.
#[test]
#[allow(clippy::unwrap_used)]
fn a_recorded_source_or_set_the_pass_cannot_read_fails_the_record_row_by_name() {
    let world = world();
    let spare = format!(
        "[sources.spare]\nrepo = \"file://{}\"\n",
        world.catalog.display()
    );
    let unfetched = "[sources.spare]\nrepo = \"file:///nowhere/fetched\"\n".to_owned();
    let disabled = format!("{spare}enabled = false\n");
    let starter = "[bundles.starter]\nsource = \"cat\"\n".to_owned();
    let pinned = format!("{starter}rev = \"0123456789abcdef0123456789abcdef01234567\"\n");
    let unrecorded = |table: &'static str, name: &'static str| -> Edit {
        on_record(move |lock| {
            lock[table].as_object_mut().unwrap().remove(name);
        })
    };
    let repointed = on_record(|lock| {
        lock["bundles"]["starter"]["commit"] = "deadbeefdeadbeefdeadbeefdeadbeefdeadbeef".into();
    });
    let unserved =
        "the mirror cannot serve the declared revision, so nothing holds the record to it";
    let undeclared =
        "source spare: recorded, and the manifest declares no enabled repository source";
    let cases: Vec<Unread> = vec![
        (
            "disabled, recorded",
            &spare,
            &disabled,
            None,
            "source spare:",
            Some(undeclared.to_owned()),
        ),
        (
            "disabled, unrecorded",
            &spare,
            &disabled,
            Some(unrecorded("sources", "spare")),
            "source spare:",
            None,
        ),
        (
            "not fetched, recorded",
            &spare,
            &unfetched,
            None,
            "source spare:",
            Some(format!("source spare: {unserved}")),
        ),
        (
            "not fetched, unrecorded",
            &spare,
            &unfetched,
            Some(unrecorded("sources", "spare")),
            "source spare:",
            None,
        ),
        (
            "pinned set unserved, recorded",
            &starter,
            &pinned,
            Some(repointed),
            "set starter:",
            Some(format!("set starter: {unserved}")),
        ),
        (
            "pinned set unserved, unrecorded",
            &starter,
            &pinned,
            Some(unrecorded("bundles", "starter")),
            "set starter:",
            None,
        ),
    ];
    for (label, from, to, edit, subject, named) in cases {
        git(&world.project, &["checkout", "-q", "-B", "case", INSTALLED]);
        let manifest = world.project.join("kendex.toml");
        let text = fs::read_to_string(&manifest).unwrap();
        assert_eq!(text.matches(from).count(), 1, "{label}");
        write(&manifest, &text.replace(from, to));
        if let Some(edit) = edit {
            edit(&world);
        }
        commit(&world.project, label);
        let (output, document) = verify(&world, Some(INSTALLED));
        let record = row(&document, "record", RECORD, None)
            .unwrap_or_else(|| panic!("{label}: no record row: {}", said(&output)));
        let detail = record.detail.as_deref().unwrap_or_default();
        match named {
            Some(named) => {
                assert!(!output.status.success(), "{label}: {}", said(&output));
                assert_eq!(record.state, State::Failed, "{label}: {record:?}");
                assert!(detail.contains(&named), "{label}: {record:?}");
            }
            None => assert!(!detail.contains(subject), "{label}: {record:?}"),
        }
    }
}

/// A scope whose last package is gone keeps a record of its sources, and
/// that record is held to what the pass reads though the plan writes no
/// entry: a commit edited on it fails the row, and the next apply puts
/// the record right again.
#[test]
#[allow(clippy::unwrap_used)]
fn a_record_with_no_entries_is_held_to_the_sources_the_pass_reads() {
    let world = world();
    git(&world.project, &["checkout", "-q", "-B", "case", INSTALLED]);
    let manifest = world.project.join("kendex.toml");
    let text = fs::read_to_string(&manifest).unwrap();
    let packages = text.find("[skills.second]").unwrap();
    write(&manifest, &text[..packages]);
    let apply = || {
        let output = kendex(&world.home, &world.project, &["apply", "-y", "--leave"]);
        assert!(output.status.success(), "apply: {}", said(&output));
    };
    apply();
    let lock: serde_json::Value =
        serde_json::from_str(&fs::read_to_string(world.project.join(RECORD)).unwrap()).unwrap();
    assert!(
        lock["entries"]
            .as_object()
            .is_none_or(|entries| entries.is_empty()),
        "{lock}"
    );
    assert!(lock["sources"]["spare"].is_object(), "{lock}");
    commit(&world.project, "every package removed");
    edit_json(&world.project.join(RECORD), |lock| {
        lock["sources"]["spare"]["commit"] = "deadbeefdeadbeefdeadbeefdeadbeefdeadbeef".into();
    });
    commit(&world.project, "a repointed source commit");
    let (output, document) = verify(&world, None);
    assert!(!output.status.success(), "{}", said(&output));
    let record = row(&document, "record", RECORD, None).unwrap();
    assert_eq!(record.state, State::Failed, "{record:?}");
    assert!(
        record.detail.as_deref().unwrap_or_default().contains(
            "source spare: commit deadbeefdeadbeefdeadbeefdeadbeefdeadbeef is not on the declared revision's history"
        ),
        "{record:?}"
    );
    apply();
    commit(&world.project, "applied");
    let (_, document) = verify(&world, None);
    let record = row(&document, "record", RECORD, None).unwrap();
    assert_eq!(record.state, State::Ok, "{record:?}");
}

/// A recorded commit the mirror cannot place is named as one to fetch,
/// never as one off the declared revision's history: a runner whose mirror
/// is cold has edited nothing, and the accusation would send its reader
/// searching the record for an edit nobody made. Here the mirror is moved
/// aside and one entry's commit is repointed, the same edit the warm
/// mirror answers with the off-history sentence in the table above.
#[test]
#[allow(clippy::unwrap_used)]
fn a_commit_a_cold_mirror_cannot_place_is_named_as_one_to_fetch() {
    let world = world();
    let mirror = mirror(&world);
    fs::rename(&mirror, mirror.with_extension("aside")).unwrap();
    git(&world.project, &["checkout", "-q", "-B", "case", INSTALLED]);
    edit_json(&world.project.join(RECORD), |lock| {
        lock["entries"][SECOND]["sourceCommit"] = "deadbeefdeadbeefdeadbeefdeadbeefdeadbeef".into();
    });
    commit(&world.project, "a repointed entry commit");
    let (output, document) = verify(&world, Some(INSTALLED));
    assert!(!output.status.success(), "{}", said(&output));
    let record = row(&document, "record", RECORD, None).unwrap();
    assert_eq!(record.state, State::Failed, "{record:?}");
    let detail = record.detail.as_deref().unwrap_or_default();
    let named = format!(
        "{SECOND}: sourceCommit deadbeefdeadbeefdeadbeefdeadbeefdeadbeef cannot be placed: the mirror of file://{} does not answer for it",
        world.catalog.display()
    );
    assert!(detail.contains(&named), "{record:?} does not say {named:?}");
    assert!(
        !detail.contains("is not on the declared revision's history"),
        "{record:?} accuses the record"
    );
}

/// `--base` names a revision of the project, and the global scope has no
/// project: its files sit under the home directory, which may be a
/// repository of its own, and a revision resolved there would judge a
/// global file against a history that is not this project's. Every global
/// keys position answers `unknown` under a base the home resolves, while
/// the project scope beside it still judges its own files.
#[test]
#[allow(clippy::unwrap_used)]
fn a_global_keys_position_is_unknown_under_a_base_the_home_resolves() {
    let world = world();
    let env = Env::host_rooted(&world.home);
    write(
        &env.global_manifest_file(),
        &format!(
            "schema = 6\n\n[sources.cat]\n{}\n\n[install]\nharnesses = [\"claude\"]\nmethod = \"copy\"\n\n[hooks.guard]\nsource = \"cat\"\n\n[mcp-servers.gh]\nsource = \"cat\"\n",
            source_path(&world.catalog),
        ),
    );
    let installed = kendex(
        &world.home,
        &world.project,
        &["apply", "-y", "--leave", "--scope", "global"],
    );
    assert!(installed.status.success(), "{}", said(&installed));
    repository(&world.home);
    git(
        &world.home,
        &["add", "--", ".claude/settings.json", ".claude.json"],
    );
    git(
        &world.home,
        &["commit", "-q", "-m", "the dotfiles as installed"],
    );
    git(&world.home, &["tag", "dotfiles"]);

    let (output, document) = verify_scope(&world, "global", Some("dotfiles"));
    assert!(output.status.success(), "{}", said(&output));
    let keys: Vec<(&str, Option<Foreign>)> = document
        .rows
        .iter()
        .flat_map(|row| row.positions.iter())
        .filter(|position| position.owns == Owns::Keys)
        .map(|position| (position.path.as_str(), position.foreign))
        .collect();
    assert_eq!(
        keys,
        vec![
            (".claude/settings.json", Some(Foreign::Unknown)),
            (".claude.json", Some(Foreign::Unknown)),
        ],
        "{document:?}"
    );

    let (output, project) = verify(&world, Some(INSTALLED));
    assert!(output.status.success(), "{}", said(&output));
    let hook = row(&project, "hook", "guard", Some(HarnessId::Claude)).unwrap();
    assert_eq!(
        hook.positions
            .iter()
            .map(|position| position.foreign)
            .collect::<Vec<_>>(),
        vec![None, Some(Foreign::Unchanged)],
        "{hook:?}"
    );
}

/// A base revision the project cannot resolve answers `unknown` for every
/// keys position rather than reading an absent copy as an empty one: a
/// file kendex created from nothing is byte for byte its own edits over
/// the empty string, so anything but this answer would vouch for it
/// against a revision nobody has. Beside the row without a base and the
/// row with the installed tag, this is the third of the three answers.
#[test]
#[allow(clippy::unwrap_used)]
fn a_base_the_project_cannot_resolve_answers_unknown_for_every_keys_position() {
    let world = world();
    let (output, document) = verify(&world, Some("deadbeefdeadbeefdeadbeefdeadbeefdeadbeef"));
    assert!(output.status.success(), "{}", said(&output));
    assert_eq!(keys_judged(&document), every_key_unknown(), "{document:?}");
}

/// A base revision whose record another lock version wrote is one this
/// build cannot read, as it cannot read the same record at the head: a
/// field the older shape lacks is a wrong answer, not a missing one, so
/// the replay reads nothing from it and every keys position answers
/// `unknown` rather than `unchanged` over a record it could not judge.
/// The record here differs from the head's in its version alone.
#[test]
#[allow(clippy::unwrap_used)]
fn a_base_record_from_another_lock_version_answers_unknown_for_every_keys_position() {
    let world = world();
    git(
        &world.project,
        &["checkout", "-q", "-B", "older", INSTALLED],
    );
    edit_json(&world.project.join(RECORD), |lock| {
        lock["version"] = (LOCK_VERSION - 1).into();
    });
    commit(&world.project, "the record as an earlier kendex wrote it");
    git(&world.project, &["checkout", "-q", "-B", "case", INSTALLED]);
    let (output, document) = verify(&world, Some("older"));
    assert!(output.status.success(), "{}", said(&output));
    assert_eq!(keys_judged(&document), every_key_unknown(), "{document:?}");
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

/// A shared file kendex wrote end to end is judged as the revision held
/// it, nothing, with this pass's edits applied in the order the writer
/// applies them: the plan's own item order, never the record's key order.
/// The two differ here by construction, a plugin's `enabledPlugins` key
/// planned before a custom hook's `hooks` key while `hook:` sorts before
/// `plugin:`, and the file's top-level keys keep insertion order, so a
/// replay in key order rebuilds the same two keys the other way round and
/// would answer that the rest of a file nobody touched moved.
/// The commit a second project is tagged at before kendex wrote to it.
const BEFORE: &str = "before";

/// A second project in the fixture home, declaring the plugin registry
/// as its one source and `declarations` on Claude alone, committed and
/// tagged `BEFORE` with nothing of kendex's in it yet.
fn second_project(world: &World, declarations: &str) -> PathBuf {
    let project = world.home.join("dev/two");
    write(
        &project.join("kendex.toml"),
        &format!(
            "schema = 6\n\n[sources.market]\n{}\n\n[install]\nharnesses = [\"claude\"]\nmethod = \"copy\"\n\n{declarations}",
            source_path(&world.home.join("market")),
        ),
    );
    repository(&project);
    commit(&project, "before kendex");
    git(&project, &["tag", BEFORE]);
    project
}

/// Every keys position a document prints, with the row it sits on: kind,
/// name, path, and what the foreign comparison said.
fn keys_positions(document: &Document) -> Vec<(&str, &str, &str, Option<Foreign>)> {
    document
        .rows
        .iter()
        .flat_map(|row| {
            row.positions
                .iter()
                .filter(|position| position.owns == Owns::Keys)
                .map(move |position| {
                    (
                        row.kind.as_str(),
                        row.name.as_str(),
                        position.path.as_str(),
                        position.foreign,
                    )
                })
        })
        .collect()
}

#[test]
#[allow(clippy::unwrap_used)]
fn a_file_two_registrations_wrote_from_nothing_is_replayed_in_the_writers_order() {
    let world = world();
    let project = second_project(
        &world,
        "[plugins.\"fmt@market\"]\nenabled = true\nharness = \"claude\"\n\n[[custom-hooks]]\nname = \"zebra\"\nevent = \"PreToolUse\"\nmatcher = \"Bash\"\ncommand = \"./zebra.sh\"\nagents = \"all\"\n",
    );
    let installed = kendex(&world.home, &project, &["apply", "-y", "--leave"]);
    assert!(installed.status.success(), "{}", said(&installed));
    commit(&project, "installed");

    let (output, document) = verify_from(&world.home, &project, "project", Some(BEFORE));
    assert!(output.status.success(), "{}", said(&output));
    let keys = keys_positions(&document);
    assert_eq!(
        keys,
        vec![
            (
                "hook",
                "zebra",
                ".claude/settings.json",
                Some(Foreign::Unchanged)
            ),
            (
                "plugin",
                "fmt@market",
                ".claude/settings.json",
                Some(Foreign::Unchanged)
            ),
        ],
        "{document:?}"
    );
}

/// A hook the catalog or the manifest moved to another event is one
/// entry in its new place, not two: the pass that moved it retired the
/// entry the record named before it registered the current one. Judged
/// against the revision that held the old entry, the replay retires the
/// same entry first, read off that revision's record, so the file the
/// move wrote is as the writer left it and nothing in it is foreign.
#[test]
#[allow(clippy::unwrap_used)]
fn a_moved_hook_is_replayed_with_its_retirement_first() {
    let world = world();
    let hook = |event: &str| {
        format!(
            "[[custom-hooks]]\nname = \"zebra\"\nevent = \"{event}\"\nmatcher = \"Bash\"\ncommand = \"./zebra.sh\"\nagents = \"all\"\n"
        )
    };
    let project = second_project(&world, &hook("PreToolUse"));
    let installed = kendex(&world.home, &project, &["apply", "-y", "--leave"]);
    assert!(installed.status.success(), "{}", said(&installed));
    commit(&project, "installed");
    git(&project, &["tag", "under-the-old-event"]);

    let manifest = world.home.join("dev/two/kendex.toml");
    let text = fs::read_to_string(&manifest).unwrap();
    fs::write(
        &manifest,
        text.replace(&hook("PreToolUse"), &hook("PostToolUse")),
    )
    .unwrap();
    let moved = kendex(&world.home, &project, &["apply", "-y", "--leave"]);
    assert!(moved.status.success(), "{}", said(&moved));
    commit(&project, "moved");
    let settings = fs::read_to_string(project.join(".claude/settings.json")).unwrap();
    assert!(
        settings.contains("PostToolUse") && !settings.contains("PreToolUse"),
        "the move left two entries: {settings}"
    );

    let (output, document) = verify_from(
        &world.home,
        &project,
        "project",
        Some("under-the-old-event"),
    );
    assert!(output.status.success(), "{}", said(&output));
    assert_eq!(
        keys_positions(&document),
        vec![(
            "hook",
            "zebra",
            ".claude/settings.json",
            Some(Foreign::Unchanged)
        )],
        "{document:?}"
    );
}
