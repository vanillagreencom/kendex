//! What a person reads about a package, wherever it is named.
//!
//! One line — the author's `summary`, else the `description` they wrote
//! instead — reaches the catalog row, the directory index, the installed
//! row and the package page. A hook and an MCP server keep no prose in the
//! file a tool registers them in, so the words come from the script the
//! install wrote and from the declaration the records name; the command
//! and the endpoint stay where execution is inspected and never stand in
//! for words nobody wrote.
#![cfg(unix)]

#[path = "../../test_util.rs"]
mod test_util;
use test_util::{rooted, source_path};

use std::fs;
use std::path::{Path, PathBuf};

use kendex_core::apply;
use kendex_core::engine::audit;
use kendex_core::env::{Env, FakeOs};
use kendex_core::model::{ItemKind, ObservedItem, Scope};
use kendex_core::source::browse;
use kendex_core::source_read::SealedSource;

/// A hook whose author wrote both lines: the constraint for the agent, and
/// the sentence for the person.
const GUARD: &str = "#!/usr/bin/env bash\n# ---\n# name: guard\n# event: PreToolUse\n# matcher: Bash\n# description: Refuse a command matching the deny pattern.\n# summary: Stops shell commands your project has ruled out.\n# ---\nexit 0\n";

/// A hook with a description and no summary: the description is shown.
const PLAIN: &str = "#!/usr/bin/env bash\n# ---\n# name: plain\n# event: Stop\n# description: Says nothing at all.\n# ---\nexit 0\n";

/// A script with no header kendex can read. Nothing authored is reachable,
/// and nothing is invented from the file around it.
const NOISE: &str = "#!/usr/bin/env bash\necho summary: not a header\nexit 0\n";

const DB_MCP: &str = "command = \"db-mcp\"\nsummary = \"Reads and writes the project database.\"\n";

/// An agent whose two lines differ: a harness selects on the description,
/// and a person reads the summary. Neither rendered agent file carries the
/// summary — it is not a rendering input — so the row that shows it has to
/// read the declaration.
const RUST_AGENT: &str = "---\nname: rust\ndescription: Use for hot paths and lock-free code.\nsummary: Tunes the slow parts of a Rust program.\n---\nBody.\n";

/// A command Codex installs as a generated one-file skill, whose
/// frontmatter kendex writes from the name and the description alone.
const SCRUB_COMMAND: &str = "---\ndescription: Scrub the code\nsummary: Takes the secrets out of a file before you share it.\n---\nBody.\n";

struct Fixture {
    _tmp: tempfile::TempDir,
    env: Env,
    scope: Scope,
    project: PathBuf,
    catalog: PathBuf,
}

#[allow(clippy::unwrap_used)]
fn fixture(declarations: &str) -> Fixture {
    fixture_for(&["claude"], declarations)
}

/// The same project, installing into the named tools. Which tool holds a
/// package decides what the file on disk looks like — a Codex command is a
/// generated skill, a Cursor hook is a rule file kendex titled — so a case
/// about the words a row shows names the tools it means.
#[allow(clippy::unwrap_used)]
fn fixture_for(harnesses: &[&str], declarations: &str) -> Fixture {
    let tmp = tempfile::tempdir().unwrap();
    let home = rooted(&tmp);
    let env = Env::fake(&home, FakeOs::Linux);
    let project = home.join("dev/app");
    fs::create_dir_all(project.join(".claude")).unwrap();

    let catalog = home.join("catalog");
    write_catalog(&catalog);
    let installed = harnesses
        .iter()
        .map(|harness| format!("\"{harness}\""))
        .collect::<Vec<_>>()
        .join(", ");
    fs::write(
        project.join("kendex.toml"),
        format!(
            "schema = 6\n\n[sources.cat]\n{}\n\n[install]\nharnesses = [{installed}]\nmethod = \"copy\"\n\n{declarations}",
            source_path(&catalog)
        ),
    )
    .unwrap();

    Fixture {
        env,
        scope: Scope::Project {
            root: project.clone(),
        },
        project,
        catalog,
        _tmp: tmp,
    }
}

/// One catalog offering a package of every kind whose words are read.
#[allow(clippy::unwrap_used)]
fn write_catalog(catalog: &Path) {
    for dir in ["hooks", "mcp", "agents", "commands"] {
        fs::create_dir_all(catalog.join(dir)).unwrap();
    }
    fs::write(catalog.join("hooks/guard.sh"), GUARD).unwrap();
    fs::write(catalog.join("hooks/plain.sh"), PLAIN).unwrap();
    fs::write(catalog.join("hooks/noise.sh"), NOISE).unwrap();
    fs::write(catalog.join("mcp/db.toml"), DB_MCP).unwrap();
    fs::write(catalog.join("agents/rust.md"), RUST_AGENT).unwrap();
    fs::write(catalog.join("commands/scrub.md"), SCRUB_COMMAND).unwrap();
    fs::write(catalog.join("kendex.toml"), "is_source_catalog = true\n").unwrap();
}

#[allow(clippy::unwrap_used)]
fn apply_now(f: &Fixture) {
    let report = audit(&f.env, &f.scope).unwrap();
    apply::execute(&f.env, &report.plan).unwrap();
}

#[allow(clippy::unwrap_used)]
fn scanned(f: &Fixture, kind: ItemKind) -> Vec<ObservedItem> {
    let result = kendex_core::scan::scan_scopes(
        &f.env,
        &std::collections::BTreeMap::new(),
        std::slice::from_ref(&f.scope),
    );
    let mut items: Vec<ObservedItem> = result
        .items
        .into_iter()
        .filter(|item| item.kind == kind)
        .collect();
    items.sort_by(|a, b| a.name.cmp(&b.name));
    items
}

/// One adopted agent, at the slot the reserved `local` source reads it
/// from. Adoption writes no catalog manifest, so this is the whole of what
/// a capture leaves behind.
#[allow(clippy::unwrap_used)]
fn capture(root: &Path, summary: &str) {
    fs::create_dir_all(root.join("agents")).unwrap();
    fs::write(
        root.join("agents/notes.md"),
        format!("---\nname: notes\ndescription: Use when writing notes.\nsummary: {summary}\n---\nBody.\n"),
    )
    .unwrap();
}

/// One more entry in a tool's hooks file, as a person adds one of their
/// own beside whatever kendex put there.
#[allow(clippy::unwrap_used)]
fn add_registration(settings: &Path, command: &str) {
    let mut value: serde_json::Value = match fs::read_to_string(settings) {
        Ok(text) => serde_json::from_str(&text).unwrap(),
        Err(_) => serde_json::json!({}),
    };
    let groups = value
        .as_object_mut()
        .unwrap()
        .entry("hooks")
        .or_insert_with(|| serde_json::json!({}))
        .as_object_mut()
        .unwrap()
        .entry("PreToolUse")
        .or_insert_with(|| serde_json::json!([]));
    groups.as_array_mut().unwrap().push(serde_json::json!({
        "matcher": "Bash",
        "hooks": [{"type": "command", "command": command}],
    }));
    fs::write(settings, serde_json::to_string(&value).unwrap()).unwrap();
}

/// The Packages table and the directory index read one header, so a
/// catalog row and the row a directory publishes for it cannot say
/// different things about one version.
#[test]
#[allow(clippy::unwrap_used)]
fn a_catalog_reads_a_hooks_own_words_and_invents_none() {
    let f = fixture("");
    let rows = browse::packages(
        &f.env,
        &browse::Catalog::Subscription {
            scope: f.scope.clone(),
            source: "cat".to_owned(),
        },
    )
    .unwrap();
    let of = |name: &str| {
        rows.iter()
            .find(|row| row.kind == ItemKind::Hook && row.name == name)
            .unwrap_or_else(|| panic!("{name} not offered"))
    };
    // A summary is the person's line; the description stays the agent's,
    // so writing one never rewrites the other.
    assert_eq!(
        of("guard").summary.as_deref(),
        Some("Stops shell commands your project has ruled out.")
    );
    assert_eq!(
        of("guard").description.as_deref(),
        Some("Refuse a command matching the deny pattern.")
    );
    assert_eq!(
        of("plain").summary.as_deref(),
        Some("Says nothing at all."),
        "a hook with no summary is shown its description"
    );
    assert_eq!(
        of("noise").summary,
        None,
        "no header to read is a blank row, never a line built from the script"
    );

    let index =
        kendex_core::source::index::index(&SealedSource::open(&f.catalog).unwrap(), "catalog")
            .unwrap();
    let indexed = |name: &str| {
        index
            .packages
            .iter()
            .find(|row| row.kind == "hook" && row.name == name)
            .unwrap_or_else(|| panic!("{name} not indexed"))
    };
    assert_eq!(indexed("guard").summary, of("guard").summary);
    assert_eq!(indexed("plain").summary, of("plain").summary);
    assert_eq!(indexed("noise").summary, None);
}

/// An installed hook is a command in the tool's settings file. Its words
/// come from the script that command runs, and the command itself stays on
/// the row as what it is.
#[test]
#[allow(clippy::unwrap_used)]
fn an_installed_hooks_words_come_from_its_script() {
    let f = fixture("[hooks.guard]\nsource = \"cat\"\n");
    apply_now(&f);

    let hooks = scanned(&f, ItemKind::Hook);
    let row = hooks.first().expect("the registration was scanned");
    assert_eq!(
        row.summary.as_deref(),
        Some("Stops shell commands your project has ruled out.")
    );
    let command = row.action.clone().expect("the registration runs something");
    assert!(
        command.contains("guard.sh"),
        "the command a person inspects stays on the row: {command}"
    );
    assert_ne!(
        row.summary.as_deref(),
        Some(command.as_str()),
        "a command is never promoted into a description"
    );
}

/// A registration kendex did not write says nothing about a package,
/// however close its command looks.
///
/// A registration is named by the stem of the command it runs, and two
/// commands share a stem the moment one names the other's script: a
/// person's own `sh .claude/hooks/guard.sh --theirs` reduces to `guard`,
/// the name of an installed hook standing right beside it. Only the whole
/// command kendex would have registered claims that script's words; a
/// stem alone claims nothing, and neither does a command naming a file
/// that is not there.
#[test]
#[allow(clippy::unwrap_used)]
fn a_registration_kendex_did_not_write_says_nothing() {
    let f = fixture("[hooks.guard]\nsource = \"cat\"\n");
    apply_now(&f);
    let ours = scanned(&f, ItemKind::Hook)
        .first()
        .and_then(|row| row.action.clone())
        .expect("the install registered something");
    // Their own entry, in the same file, running the script kendex wrote —
    // under a command kendex would never have written.
    let theirs = format!("sh {ours} --theirs");
    add_registration(&f.project.join(".claude/settings.json"), &theirs);
    add_registration(
        &f.project.join(".claude/settings.json"),
        "bash /elsewhere/theirs.sh",
    );

    let rows = scanned(&f, ItemKind::Hook);
    assert_eq!(rows.len(), 3, "every entry in the file was scanned");
    let of = |command: &str| {
        rows.iter()
            .find(|row| row.action.as_deref() == Some(command))
            .unwrap_or_else(|| panic!("{command} was not scanned"))
            .summary
            .as_deref()
    };
    assert!(
        of(&ours).is_some(),
        "kendex's own registration keeps its words"
    );
    assert_eq!(
        of(&theirs),
        None,
        "a command kendex did not write claims no package's words"
    );
    assert_eq!(of("bash /elsewhere/theirs.sh"), None);
}

/// An MCP server's entry records how to reach it and nothing else. The
/// words come from the declaration's own source, at the version installed
/// here, through the records that say which package the entry is.
#[test]
#[allow(clippy::unwrap_used)]
fn an_mcp_servers_words_come_from_its_declaration() {
    let f = fixture("[mcp-servers.db]\nsource = \"cat\"\n");
    apply_now(&f);

    let servers = scanned(&f, ItemKind::McpServer);
    let observed = servers.first().expect("the server was scanned");
    assert_eq!(
        observed.summary, None,
        "a tool's config file holds no words about the package"
    );
    assert_eq!(observed.action.as_deref(), Some("db-mcp"));

    let rows = kendex_core::library::provenance(&f.env, std::slice::from_ref(&f.scope)).unwrap();
    let row = rows
        .iter()
        .find(|row| row.kind == ItemKind::McpServer && row.name == "db")
        .expect("the server has a provenance row");
    assert_eq!(
        row.summary.as_deref(),
        Some("Reads and writes the project database.")
    );
}

/// Every tool holding one package version says the same thing about it.
///
/// The file kendex renders is what a tool loads, not what the author
/// wrote: an agent's frontmatter carries the `description` its harness
/// selects on and no summary, a Codex command is a wrapper generated from
/// the name and the description, and a Cursor hook is a rule file kendex
/// titled after the hook. Reading the installed file would give one
/// package three voices, one of them kendex's own.
#[test]
#[allow(clippy::unwrap_used)]
fn one_package_reads_the_same_in_every_tool_holding_it() {
    let f = fixture_for(
        &["claude", "codex", "cursor"],
        "[agents.rust]\nsource = \"cat\"\n\n[commands.scrub]\nsource = \"cat\"\n\n[hooks.guard]\nsource = \"cat\"\n",
    );
    apply_now(&f);

    let rows = kendex_core::library::provenance(&f.env, std::slice::from_ref(&f.scope)).unwrap();
    let words = |kind: ItemKind, name: &str| {
        let mut said: Vec<Option<String>> = rows
            .iter()
            .filter(|row| row.package_ref().kind == kind && row.package_ref().name == name)
            .map(|row| row.summary.clone())
            .collect();
        assert!(!said.is_empty(), "{name} has no installed row");
        said.sort();
        said.dedup();
        said
    };
    assert_eq!(
        words(ItemKind::Agent, "rust"),
        vec![Some("Tunes the slow parts of a Rust program.".to_owned())],
        "an agent row reads the author's summary, never the line a harness selects on"
    );
    assert_eq!(
        words(ItemKind::Command, "scrub"),
        vec![Some(
            "Takes the secrets out of a file before you share it.".to_owned()
        )],
        "a command reads the same in Codex, whose file kendex generated, as in Claude"
    );
    assert_eq!(
        words(ItemKind::Hook, "guard"),
        vec![Some(
            "Stops shell commands your project has ruled out.".to_owned()
        )],
        "a hook reads the same in Cursor, whose rule file kendex titled, as in Claude"
    );

    // The marketplace row for the same version is that one line as well.
    let offered = browse::packages(
        &f.env,
        &browse::Catalog::Subscription {
            scope: f.scope.clone(),
            source: "cat".to_owned(),
        },
    )
    .unwrap();
    for (kind, name) in [
        (ItemKind::Agent, "rust"),
        (ItemKind::Command, "scrub"),
        (ItemKind::Hook, "guard"),
    ] {
        let catalog_row = offered
            .iter()
            .find(|row| row.kind == kind && row.name == name)
            .unwrap_or_else(|| panic!("{name} not offered"));
        assert_eq!(vec![catalog_row.summary.clone()], words(kind, name));
    }
}

/// The reserved `local` source is a different catalog in every scope, and
/// each row reads its own.
///
/// `local` is the name adoption writes: capturing a package globally puts
/// it under the global local-source root, capturing one in a project puts
/// it under that project's. Nobody declares the name, so nothing warns
/// that two scopes are using it, and a person who adopted a package in
/// both places has two catalogs offering one name. A reader that
/// remembers a source name without the scope that spelled it hands the
/// second scope the first scope's catalog and answers with somebody
/// else's words.
#[test]
#[allow(clippy::unwrap_used)]
fn the_reserved_local_source_reads_each_scopes_own_capture() {
    let f = fixture("[agents.notes]\nsource = \"local\"\n");
    // What an adopt leaves behind in each scope: the package at the slot
    // the reserved source reads it from.
    capture(
        &kendex_core::source::local_source_root(&f.env, &f.scope),
        "Keeps this project's decisions where the team can find them.",
    );
    capture(
        &kendex_core::source::local_source_root(&f.env, &Scope::Global),
        "Keeps the notes you write for yourself.",
    );
    let global_manifest = kendex_core::manifest::manifest_path(&f.env, &Scope::Global);
    fs::create_dir_all(global_manifest.parent().unwrap()).unwrap();
    fs::write(
        &global_manifest,
        "schema = 6\n\n[install]\nharnesses = [\"claude\"]\nmethod = \"copy\"\n\n[agents.notes]\nsource = \"local\"\n",
    )
    .unwrap();

    apply_now(&f);
    let report = audit(&f.env, &Scope::Global).unwrap();
    apply::execute(&f.env, &report.plan).unwrap();

    // Global first, as the app asks for every scope: the scope that asks
    // first is the one that would freeze the catalog for the rest.
    let scopes = [Scope::Global, f.scope.clone()];
    let rows = kendex_core::library::provenance(&f.env, &scopes).unwrap();
    let of = |scope: &Scope| {
        rows.iter()
            .find(|row| &row.scope == scope && row.package_ref().name == "notes")
            .unwrap_or_else(|| panic!("no row for {}", scope.label()))
            .summary
            .clone()
    };
    assert_eq!(
        of(&Scope::Global),
        Some("Keeps the notes you write for yourself.".to_owned())
    );
    assert_eq!(
        of(&f.scope),
        Some("Keeps this project's decisions where the team can find them.".to_owned())
    );
}

/// A person's Library row reads the version they installed, not the
/// version upstream has moved to since.
///
/// A declaration naming no revision, or naming a branch or a tag, names a
/// selector: what it resolves to is whatever the cache holds, and the
/// stale-source refresh moves that on its own. The bytes on disk stay
/// where the install put them. Resolving the words through the selector
/// would put the newer upstream's sentence on an older installed version,
/// which is the borrowed reading the record exists to prevent.
#[test]
#[allow(clippy::unwrap_used)]
fn a_row_reads_the_version_installed_not_the_one_upstream_moved_to() {
    let tmp = tempfile::tempdir().unwrap();
    let home = rooted(&tmp);
    let base = format!("file://{}", home.join("base").display());
    let env = Env::fake(&home, FakeOs::Linux).with_var("KENDEX_GIT_BASE", &base);
    let project = home.join("dev/app");
    fs::create_dir_all(project.join(".claude")).unwrap();
    fs::write(
        project.join("kendex.toml"),
        "schema = 6\n\n[sources.up]\nrepo = \"team/tools\"\n\n[install]\nharnesses = [\"claude\"]\nmethod = \"copy\"\n\n[agents.notes]\nsource = \"up\"\n",
    )
    .unwrap();
    let scope = Scope::Project {
        root: project.clone(),
    };

    let upstream = home.join("base/team/tools");
    fs::create_dir_all(upstream.join("agents")).unwrap();
    fs::write(upstream.join("kendex.toml"), "is_source_catalog = true\n").unwrap();
    write_notes(&upstream, "Keeps the notes you had when you installed it.");
    git(&upstream, &["init", "--quiet", "-b", "main"]);
    git(&upstream, &["add", "-A"]);
    git(&upstream, &["commit", "--quiet", "-m", "one"]);
    kendex_core::remote::sync(&env, "team/tools", None).unwrap();

    let report = audit(&env, &scope).unwrap();
    apply::execute(&env, &report.plan).unwrap();

    // Upstream moves and the refresh brings the cache with it. Nothing
    // rewrites the file the install put on disk.
    write_notes(&upstream, "Keeps notes nobody here has installed yet.");
    git(&upstream, &["add", "-A"]);
    git(&upstream, &["commit", "--quiet", "-m", "two"]);
    kendex_core::remote::sync(&env, "team/tools", None).unwrap();

    let rows = kendex_core::library::provenance(&env, std::slice::from_ref(&scope)).unwrap();
    let row = rows
        .iter()
        .find(|row| row.package_ref().name == "notes")
        .expect("the agent has a provenance row");
    assert_eq!(
        row.summary.as_deref(),
        Some("Keeps the notes you had when you installed it.")
    );
}

/// The catalog's agent, at one version of its words.
#[allow(clippy::unwrap_used)]
fn write_notes(catalog: &Path, summary: &str) {
    fs::write(
        catalog.join("agents/notes.md"),
        format!("---\nname: notes\ndescription: Use when writing notes.\nsummary: {summary}\n---\nBody.\n"),
    )
    .unwrap();
}

/// Git in a fixture, with the caller's git environment dropped: run from a
/// commit hook, `GIT_DIR` and friends point at the repository being
/// committed to and every command here would act on that one instead.
#[allow(clippy::unwrap_used)]
fn git(dir: &Path, args: &[&str]) {
    let output = std::process::Command::new("git")
        .args(["-c", "user.email=t@t", "-c", "user.name=t"])
        .args(args)
        .current_dir(dir)
        .env_remove("GIT_DIR")
        .env_remove("GIT_COMMON_DIR")
        .env_remove("GIT_WORK_TREE")
        .env_remove("GIT_INDEX_FILE")
        .env_remove("GIT_OBJECT_DIRECTORY")
        .env_remove("GIT_PREFIX")
        .output()
        .unwrap();
    assert!(
        output.status.success(),
        "git {args:?} failed: {}",
        String::from_utf8_lossy(&output.stderr)
    );
}

/// A rebound manifest does not rewrite what is already installed, and the
/// row goes on describing what is.
///
/// A declaration is what a scope asks for now. Editing an item's `source`,
/// or re-pointing a source at another repository, is a request for
/// different bytes; until an apply fetches them the bytes on disk are the
/// ones the record names. A reader that took the identity from the
/// declaration would answer with the new catalog's account of a package
/// that catalog did not write — the same borrowed reading the scope key
/// and the recorded commit already close, arriving through the source.
#[test]
#[allow(clippy::unwrap_used)]
fn a_rebound_declaration_does_not_relabel_what_is_installed() {
    // Both rebinds, as a person writes them: the item pointed at another
    // declared source, and the source itself pointed at another folder.
    let rebinds = [
        (
            "the item now names another source",
            "[sources.up]\n{up}\n\n[sources.other]\n{other}\n\n[skills.gh]\nsource = \"other\"\n",
        ),
        (
            "the source now reads another folder",
            "[sources.up]\n{other}\n\n[skills.gh]\nsource = \"up\"\n",
        ),
    ];
    for (rebind, declarations) in rebinds {
        let tmp = tempfile::tempdir().unwrap();
        let home = rooted(&tmp);
        let env = Env::fake(&home, FakeOs::Linux);
        let project = home.join("dev/app");
        fs::create_dir_all(project.join(".claude")).unwrap();

        let up = home.join("up");
        let other = home.join("other");
        write_gh(&up, "Reads the repositories you work in.");
        write_gh(&other, "A different catalog's idea of what gh is.");
        let manifest = |declarations: &str| {
            format!(
                "schema = 6\n\n[install]\nharnesses = [\"claude\"]\nmethod = \"copy\"\n\n{}",
                declarations
                    .replace("{up}", &source_path(&up))
                    .replace("{other}", &source_path(&other))
            )
        };
        fs::write(
            project.join("kendex.toml"),
            manifest("[sources.up]\n{up}\n\n[skills.gh]\nsource = \"up\"\n"),
        )
        .unwrap();
        let scope = Scope::Project {
            root: project.clone(),
        };
        let report = audit(&env, &scope).unwrap();
        apply::execute(&env, &report.plan).unwrap();

        // The edit, with no apply behind it: the files on disk are still
        // the ones the first install wrote.
        fs::write(project.join("kendex.toml"), manifest(declarations)).unwrap();

        let rows = kendex_core::library::provenance(&env, std::slice::from_ref(&scope)).unwrap();
        let row = rows
            .iter()
            .find(|row| row.package_ref().name == "gh")
            .unwrap_or_else(|| panic!("{rebind}: the skill has no provenance row"));
        assert_eq!(
            row.summary.as_deref(),
            Some("Reads the repositories you work in."),
            "{rebind}"
        );
    }
}

/// One catalog offering `gh`, at one account of what it is.
#[allow(clippy::unwrap_used)]
fn write_gh(catalog: &Path, summary: &str) {
    fs::create_dir_all(catalog.join("skills/gh")).unwrap();
    fs::write(catalog.join("kendex.toml"), "is_source_catalog = true\n").unwrap();
    fs::write(
        catalog.join("skills/gh/SKILL.md"),
        format!(
            "---\nname: gh\ndescription: Use for GitHub work.\nsummary: {summary}\n---\nBody.\n"
        ),
    )
    .unwrap();
}
