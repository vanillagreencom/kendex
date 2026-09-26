//! A Pi extension a project's manifest declares that the global manifest
//! declares too. Pi reads the two scopes' package lists together at
//! startup and will not start with one package registered twice, so the
//! pair of declarations is the conflict on its own: `kendex check` names
//! it from the manifests alone and says which declaration stays.

#![cfg(unix)]

use crate::test_util;
use test_util::rooted;

use std::fs;
use std::path::{Path, PathBuf};
use std::process::{Command, Output};

fn kendex(home: &Path, cwd: &Path, args: &[&str]) -> Output {
    kendex_with(home, cwd, args, &[])
}

/// The same run with `extra` set on top of the suite's environment.
#[allow(clippy::expect_used)]
fn kendex_with(home: &Path, cwd: &Path, args: &[&str], extra: &[(&str, &str)]) -> Output {
    let mut run = Command::new(env!("CARGO_BIN_EXE_kendex"));
    run.args(args)
        .current_dir(cwd)
        .env_clear()
        .envs(test_util::fixture_env(home))
        .env("KENDEX_BACKGROUND_REFRESH", "off")
        .env("PATH", std::env::var_os("PATH").unwrap_or_default());
    for (name, value) in extra {
        run.env(name, value);
    }
    run.output().expect("kendex binary runs")
}

fn said(output: &Output) -> String {
    format!(
        "{}{}",
        String::from_utf8_lossy(&output.stdout),
        String::from_utf8_lossy(&output.stderr)
    )
}

#[allow(clippy::unwrap_used)]
fn write(path: &Path, text: &str) {
    fs::create_dir_all(path.parent().unwrap()).unwrap();
    fs::write(path, text).unwrap();
}

/// A global manifest with an unterminated table header: it will not parse,
/// so no read of it can answer whether a package is declared twice.
const BROKEN_GLOBAL: &str = "schema = 6\n[pi-extensions\n";

/// The whole of what a could-not-check line says when an unreadable global
/// manifest leaves the duplicate check unrun: the file at fault and the
/// check it skipped, before the parser's own words.
const SKIPPED_CHECK: &str = "pi declared at both scopes: global manifest: ";

/// A manifest declaring one Pi extension from a catalog beside it.
fn manifest(name: &str) -> String {
    format!(
        "schema = 6\n\n[sources.cat]\npath = \"catalog\"\n\n[pi-extensions.\"{name}\"]\nsource = \"cat\"\n"
    )
}

#[allow(clippy::unwrap_used)]
fn global_manifest_file(home: &Path) -> PathBuf {
    kendex_core::env::Env::host_rooted(home).global_manifest_file()
}

/// Which file a project declares its installs in. A source catalog's own
/// `kendex.toml` is the definition it publishes, so kendex routes that
/// project's declarations to the sibling and the row must send the reader
/// there instead.
enum Declares {
    InManifest,
    InLocalManifest,
}

impl Declares {
    /// The file name the row names, spelled here rather than read from the
    /// production constant, so the row is pinned and not re-derived.
    fn file(&self) -> &'static str {
        match self {
            Declares::InManifest => "kendex.toml",
            Declares::InLocalManifest => "kendex-local.toml",
        }
    }
}

/// A home whose global manifest declares `global`, and a project under it
/// whose own manifest declares `project`, in the file `declares` names.
/// Nothing is installed anywhere: the declarations alone are what the
/// check reads.
#[allow(clippy::unwrap_used)]
fn fixture(
    global: Option<&str>,
    project: &str,
    declares: &Declares,
) -> (tempfile::TempDir, PathBuf, PathBuf) {
    let tmp = tempfile::tempdir().unwrap();
    let home = rooted(&tmp);
    let root = home.join("dev/app");
    fs::create_dir_all(root.join(".pi")).unwrap();
    if let Declares::InLocalManifest = declares {
        // The marker kendex reads to route install state to the sibling.
        write(
            &root.join("kendex.toml"),
            "is_source_catalog = true\n\n[marketplace]\nname = \"cat\"\n",
        );
    }
    write(&root.join(declares.file()), &manifest(project));
    if let Some(global) = global {
        write(&global_manifest_file(&home), &manifest(global));
    }
    (tmp, home, root)
}

/// The whole row, through end of line. Which declaration survives is the
/// judgement this feature adds, so the line is pinned entire rather than
/// by a prefix: a prefix match stands while a remedy or a clause naming
/// the global copy is appended after it.
fn expected_row(project: &str, global: &str, declares: &Declares, root: &Path) -> String {
    let manifest = root.join(declares.file());
    format!(
        "pi-declared-twice={project}: the global manifest declares '{global}' too; \
         Pi loads both scopes' package lists together and will not start with one \
         package registered twice; keep the global declaration, which reaches every \
         project; remove the [pi-extensions.\"{project}\"] table from this \
         project's {}; edit: ${{EDITOR:-vi}} {}",
        declares.file(),
        kendex_core::names::quoted(&manifest.display().to_string())
    )
}

/// The one line of the report that carries the key, with its leading
/// indent and any per-scope prefix stripped, so a case can compare the
/// whole of it and see what follows the clause it cares about.
fn rows_in(text: &str) -> Vec<String> {
    text.lines()
        .filter(|line| line.contains("pi-declared-twice="))
        .map(|line| {
            let start = line
                .find("pi-declared-twice=")
                .unwrap_or_else(|| unreachable!("the filter above matched this line"));
            line[start..].trim_end().to_owned()
        })
        .collect()
}

/// One package under any pair of its spellings is one registration to Pi,
/// since Pi de-duplicates by package identity and a rename leaves the same
/// package under two names. Each pair is one row: it opens on the stable
/// key, names the global manifest's spelling, says what a Pi session
/// loses, says which declaration stays, and names the edit that settles
/// it. The row carries no remedy, so the machine shape's `remedy` is
/// absent.
#[test]
fn a_project_declaration_the_global_manifest_also_holds_is_named_with_the_copy_to_keep() {
    let rows = [
        (
            "both under the current name",
            "pi-widgets",
            "pi-widgets",
            Declares::InManifest,
        ),
        (
            "the project under an earlier name",
            "@vanillagreen/pi-hooks",
            "pi-hooks",
            Declares::InManifest,
        ),
        (
            "the global under an earlier name",
            "pi-hooks",
            "@vanillagreen/pi-hooks",
            Declares::InManifest,
        ),
        // Two earlier names of one package, the pair a pairwise legacy
        // test reads as two packages while Pi registers one twice.
        (
            "both under different earlier names",
            "pi-subagents",
            "pi-agents-tmux",
            Declares::InManifest,
        ),
        // A source catalog publishes its own kendex.toml, so its install
        // declarations sit in the sibling: the edit named there would
        // change the catalog and leave Pi refusing to start.
        (
            "a source catalog, declaring in the sibling",
            "pi-widgets",
            "pi-widgets",
            Declares::InLocalManifest,
        ),
    ];
    for (case, global, project, declares) in rows {
        let (_tmp, home, root) = fixture(Some(global), project, &declares);
        // The conflict is the pair of declarations: no scope has the
        // package on disk, and the row still lands.
        assert!(
            !root.join(".pi/packages").exists(),
            "{case}: the fixture installs nothing"
        );

        let check = kendex(&home, &root, &["check", "--scope", "project"]);
        assert_eq!(check.status.code(), Some(1), "{case}: {}", said(&check));
        let text = said(&check);
        assert!(text.contains("declared at both scopes:"), "{case}: {text}");
        assert_eq!(
            rows_in(&text),
            vec![expected_row(project, global, &declares, &root)],
            "{case}: {text}"
        );

        let json = kendex(&home, &root, &["check", "--json", "--scope", "project"]);
        assert_eq!(json.status.code(), Some(1), "{case}: {}", said(&json));
        let report: serde_json::Value = serde_json::from_slice(&json.stdout)
            .unwrap_or_else(|error| panic!("{case}: check --json is JSON: {error}"));
        let section = report["sections"]
            .as_array()
            .and_then(|sections| {
                sections
                    .iter()
                    .find(|section| section["title"] == "declared at both scopes")
            })
            .unwrap_or_else(|| panic!("{case}: no declared-at-both-scopes section: {report}"));
        let lines = section["lines"]
            .as_array()
            .unwrap_or_else(|| panic!("{case}: section carries no lines: {report}"));
        assert_eq!(lines.len(), 1, "{case}: {report}");
        assert_eq!(
            lines[0]["text"],
            expected_row(project, global, &declares, &root),
            "{case}"
        );
        assert_eq!(lines[0]["class"], "drift", "{case}");
        // No remedy: the fix is an edit to the person's own file, and a
        // remedy here would name a verb that removes nothing.
        assert!(lines[0].get("remedy").is_none(), "{case}: {report}");
    }
}

/// The invocation the changelog and the Pi adapter doc name, with no
/// scope flag: the project and the global scope are covered in one run,
/// the row carries the project's scope word, and the global scope adds no
/// second row for the same pair.
/// The edit the row names is a command, so a terminal too narrow for the
/// row still gets it whole on a line of its own: split at its space it
/// reads as `${EDITOR:-vi}` alone, with the path left on the next line as
/// if it were prose.
#[test]
fn a_narrow_terminal_draws_the_edit_command_whole() {
    let (_tmp, home, root) = fixture(Some("pi-widgets"), "pi-widgets", &Declares::InManifest);
    let check = kendex_with(
        &home,
        &root,
        &["check", "--scope", "project"],
        &[
            ("KENDEX_UI", "pretty"),
            ("COLUMNS", "40"),
            ("LANG", "C.UTF-8"),
        ],
    );
    let edit = format!(
        "${{EDITOR:-vi}} {}",
        kendex_core::names::quoted(&root.join("kendex.toml").display().to_string())
    );
    let text = String::from_utf8_lossy(&check.stdout).into_owned();
    let unpainted: Vec<String> = text
        .lines()
        .map(|line| {
            let mut parts = line.split('\u{1b}');
            let mut plain = parts.next().unwrap_or_default().to_owned();
            for part in parts {
                plain.push_str(part.split_once('m').map_or(part, |(_, rest)| rest));
            }
            plain.trim().to_owned()
        })
        .collect();
    // Wider than the 40 columns, so a line of its own and nothing else.
    assert!(
        unpainted.contains(&edit),
        "the edit command was broken across lines: {unpainted:#?}"
    );
}

#[test]
fn an_unqualified_check_names_the_pair_once_under_the_project_scope_word() {
    let (_tmp, home, root) = fixture(Some("pi-widgets"), "pi-widgets", &Declares::InManifest);

    let check = kendex(&home, &root, &["check"]);
    assert_eq!(check.status.code(), Some(1), "{}", said(&check));
    let text = said(&check);
    assert_eq!(rows_in(&text).len(), 1, "{text}");
    assert!(
        text.contains(&format!(
            "app: {}",
            expected_row("pi-widgets", "pi-widgets", &Declares::InManifest, &root)
        )),
        "{text}"
    );
}

/// No second registration, no row: a global manifest that is not there and
/// one that declares a different package both leave the project's
/// declaration alone.
#[test]
fn a_project_declaration_the_global_manifest_does_not_hold_gets_no_row() {
    let rows = [
        ("no global manifest at all", None),
        (
            "a global manifest declaring another package",
            Some("@vanillagreen/pi-qol"),
        ),
    ];
    for (case, global) in rows {
        let (_tmp, home, root) = fixture(global, "pi-widgets", &Declares::InManifest);
        let check = kendex(&home, &root, &["check", "--scope", "project"]);
        let text = said(&check);
        // Exit 1, not 2: the declared package is not installed, which is
        // drift. A global manifest that is simply absent is an answer,
        // so reading it as could-not-check would make every machine
        // without one report the project unverifiable.
        assert_eq!(check.status.code(), Some(1), "{case}: {text}");
        assert!(!text.contains("pi-declared-twice"), "{case}: {text}");
        assert!(!text.contains("declared at both scopes"), "{case}: {text}");
    }
}

/// The global declaration is the copy that stays, so the global scope is
/// never told to drop it.
#[test]
fn the_global_scope_is_not_told_to_drop_its_own_declaration() {
    let (_tmp, home, root) = fixture(Some("pi-widgets"), "pi-widgets", &Declares::InManifest);
    let check = kendex(&home, &root, &["check", "--scope", "global"]);
    let text = said(&check);
    assert_eq!(check.status.code(), Some(1), "{text}");
    assert!(!text.contains("pi-declared-twice"), "{text}");
}

/// A global manifest that will not parse leaves the duplication unjudged.
/// That is a could-not-check line and exit 2, never a project reported
/// free of a conflict nothing looked for.
///
/// One file at fault is one line whichever scopes the run covers. The
/// unqualified run reaches the global scope too, whose own manifest read
/// names that same file with that same error, so the project scope adds
/// nothing beside it; a second line would put one file in the closing
/// count twice and read as a second file at fault.
#[test]
fn an_unreadable_global_manifest_is_reported_once_and_never_read_as_no_duplicate() {
    let rows = [
        // The duplicate check names the file and the check it skipped.
        (
            "the project scope alone",
            vec!["check", "--scope", "project"],
            SKIPPED_CHECK,
        ),
        // The global scope is in the run, so its own manifest read names
        // that same file first and the duplicate check adds nothing.
        (
            "the unqualified run, both scopes",
            vec!["check"],
            "global: manifest: ",
        ),
    ];
    for (case, args, wording) in rows {
        let (_tmp, home, root) = fixture(Some("pi-widgets"), "pi-widgets", &Declares::InManifest);
        let global = global_manifest_file(&home);
        write(&global, BROKEN_GLOBAL);

        let check = kendex(&home, &root, &args);
        assert_eq!(check.status.code(), Some(2), "{case}: {}", said(&check));
        let text = said(&check);
        assert!(text.contains("could not check:"), "{case}: {text}");
        // Counted over the lines that name the file itself: one file at
        // fault is one line. The bare word "manifest" would count both
        // this line and a scope's own manifest read, so a line that
        // stopped saying which file it is about would still pass.
        let named: Vec<&str> = text
            .lines()
            .filter(|line| line.contains(&global.display().to_string()))
            .collect();
        assert_eq!(named.len(), 1, "{case}: {text}");
        // The whole wording, and the parser's own words after it, so the
        // reader learns which file will not read and why.
        assert!(named[0].contains(wording), "{case}: {text}");
        assert!(named[0].contains("unclosed table"), "{case}: {text}");
        assert!(!text.contains("pi-declared-twice"), "{case}: {text}");
    }
}

/// A global manifest that will not read is a could-not-check line only
/// where the duplicate check would have run. A scope that declares no Pi
/// extension, and a directory that is not a kendex project at all, never
/// reach it: reporting them unverifiable would fail every project on a
/// machine whose global manifest is a schema behind, mid-upgrade.
#[test]
#[allow(clippy::unwrap_used)]
fn a_scope_the_duplicate_check_never_reaches_is_clean_under_an_unreadable_global_manifest() {
    let rows = [
        (
            "a project manifest declaring no Pi extension",
            Some("schema = 6\n\n[sources.cat]\npath = \"catalog\"\n"),
        ),
        ("a directory with no kendex.toml", None),
    ];
    for (case, project) in rows {
        let tmp = tempfile::tempdir().unwrap();
        let home = rooted(&tmp);
        let root = home.join("dev/app");
        fs::create_dir_all(root.join(".pi")).unwrap();
        if let Some(project) = project {
            write(&root.join("kendex.toml"), project);
        }
        write(&global_manifest_file(&home), BROKEN_GLOBAL);

        let check = kendex(&home, &root, &["check", "--scope", "project"]);
        let text = said(&check);
        assert_eq!(check.status.code(), Some(0), "{case}: {text}");
        assert!(!text.contains("global manifest"), "{case}: {text}");
        assert!(!text.contains(SKIPPED_CHECK), "{case}: {text}");
    }
}
