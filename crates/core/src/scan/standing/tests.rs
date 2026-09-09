use std::collections::BTreeMap;
use std::fs;
use std::path::{Path, PathBuf};

use super::WarningStanding;
use crate::env::{Env, FakeOs};
use crate::model::{HarnessId, ItemKind, Scope};
use crate::scan::{ScanProblem, ScanWarning, scan_scopes};

/// Antigravity's optional MCP container at the global root, holding
/// whatever another program left in it.
fn container(home: &Path, contents: &str) -> PathBuf {
    let path = home.join(".gemini/config/mcp_config.json");
    fs::create_dir_all(path.parent().expect("the container has a directory")).unwrap();
    fs::write(&path, contents).unwrap();
    path
}

fn global_manifest(env: &Env, text: &str) {
    let path = crate::manifest::manifest_path(env, &Scope::Global);
    fs::create_dir_all(path.parent().expect("the manifest has a directory")).unwrap();
    fs::write(path, text).unwrap();
}

fn scope_manifest(env: &Env, scope: &Scope, text: &str) {
    let path = crate::manifest::manifest_path(env, scope);
    fs::create_dir_all(path.parent().expect("the manifest has a directory")).unwrap();
    fs::write(path, text).unwrap();
}

fn global_lock(env: &Env, text: &str) {
    let path = crate::lock::lock_path(env, &Scope::Global);
    fs::create_dir_all(path.parent().expect("the lock has a directory")).unwrap();
    fs::write(path, text).unwrap();
}

/// A record naming one installed MCP server on `harness`.
fn record_with_server(harness: HarnessId) -> String {
    format!(
        r#"{{"version": {}, "entries": {{"mcp-server:gh:{harness}": {{
            "name": "gh", "kind": "mcp-server", "harness": "{harness}",
            "source": "kendex", "sourceRepo": "vanillagreencom/kendex",
            "method": "copy", "installedAt": "2026-01-01T00:00:00Z",
            "sourceHash": "abc", "enabled": true
        }}}}}}"#,
        crate::lock::LOCK_VERSION,
        harness = harness.name(),
    )
}

/// A manifest declaring one MCP server for `harness`, from a source that
/// resolves: a path source rooted at a directory the fixture makes.
fn manifest_declaring_server(catalog: &Path, harness: HarnessId) -> String {
    fs::create_dir_all(catalog).unwrap();
    format!(
        "schema = {}\n[sources.shelf]\n{}\n[mcp-servers.gh]\nsource = \"shelf\"\nharnesses = [\"{}\"]\n",
        crate::manifest::MANIFEST_SCHEMA,
        crate::test_util::source_path(catalog),
        harness.name(),
    )
}

fn scan_global(env: &Env) -> Vec<ScanWarning> {
    scan_scopes(env, &BTreeMap::new(), &[Scope::Global]).warnings
}

fn about<'a>(warnings: &'a [ScanWarning], path: &Path) -> &'a ScanWarning {
    warnings
        .iter()
        .find(|warning| warning.path == path)
        .unwrap_or_else(|| panic!("nothing was said about {}", path.display()))
}

/// An MCP container is optional: no harness needs one, and a program that
/// writes its config before it has anything to put in it leaves an empty
/// file behind. Empty reads as no servers, so on a machine that declares
/// and records none the file is information, and the reader is asked to
/// change nothing in another program's file. Every other shape the same
/// surface can be in still is.
#[test]
fn an_empty_container_is_neutral_and_every_other_shape_stays_actionable() {
    type Expected = Option<(fn(&ScanProblem) -> bool, WarningStanding)>;
    let rows: [(&str, Expected); 5] = [
        (
            "",
            Some((
                |problem| *problem == ScanProblem::EmptyFile,
                WarningStanding::UnusedEmptyContainer,
            )),
        ),
        (
            "   \n// only a comment\n",
            Some((
                |problem| *problem == ScanProblem::EmptyFile,
                WarningStanding::UnusedEmptyContainer,
            )),
        ),
        (
            "{\"mcpServers\": {",
            Some((
                |problem| matches!(problem, ScanProblem::InvalidJson { .. }),
                WarningStanding::Actionable,
            )),
        ),
        ("{\"mcpServers\": {}}", None),
        (
            "{\"mcpServers\": {\"gh\": {\"command\": \"gh-mcp\"}}}",
            None,
        ),
    ];
    for (contents, expected) in rows {
        let tmp = tempfile::tempdir().unwrap();
        let home = crate::test_util::rooted(&tmp);
        let env = Env::fake(&home, FakeOs::Linux);
        let path = container(&home, contents);

        let warnings = scan_global(&env);

        let found = warnings.iter().find(|warning| warning.path == path);
        match (found, expected) {
            (Some(warning), Some((shape, standing))) => {
                assert!(shape(&warning.problem), "{contents:?}: {warning}");
                assert_eq!(warning.standing, standing, "{contents:?}: {warning}");
                assert_eq!(
                    (warning.harness, warning.kind),
                    (HarnessId::Antigravity, ItemKind::McpServer),
                    "{contents:?}: {warning}"
                );
            }
            (None, None) => {}
            (found, _) => panic!("{contents:?}: {found:?}"),
        }
    }
}

/// The evidence that a container is unused is the scope's own records and
/// declarations, read the one way every ownership question reads them. A
/// server declared for the harness, or recorded as installed on it, is a
/// managed server that is now missing from the file — the reader has a
/// repair to make and the warning keeps its remedy.
#[test]
fn an_expected_server_keeps_the_empty_container_actionable() {
    let tmp = tempfile::tempdir().unwrap();
    let home = crate::test_util::rooted(&tmp);
    let env = Env::fake(&home, FakeOs::Linux);
    let catalog = home.join("shelf");
    let rows: [(&str, Option<String>, Option<String>, WarningStanding); 4] = [
        (
            "nothing asked for",
            None,
            None,
            WarningStanding::UnusedEmptyContainer,
        ),
        (
            "declared for this harness",
            Some(manifest_declaring_server(&catalog, HarnessId::Antigravity)),
            None,
            WarningStanding::Actionable,
        ),
        (
            "recorded on this harness",
            None,
            Some(record_with_server(HarnessId::Antigravity)),
            WarningStanding::Actionable,
        ),
        (
            "declared and recorded for another harness",
            Some(manifest_declaring_server(&catalog, HarnessId::Claude)),
            Some(record_with_server(HarnessId::Claude)),
            WarningStanding::UnusedEmptyContainer,
        ),
    ];
    for (case, manifest, lock, standing) in rows {
        let path = container(&home, "");
        global_manifest(&env, manifest.as_deref().unwrap_or(""));
        global_lock(&env, lock.as_deref().unwrap_or("{\"version\": 0}"));
        if lock.is_none() {
            fs::remove_file(crate::lock::lock_path(&env, &Scope::Global)).unwrap();
        }
        if manifest.is_none() {
            fs::remove_file(crate::manifest::manifest_path(&env, &Scope::Global)).unwrap();
        }

        let warnings = scan_global(&env);

        let warning = about(&warnings, &path);
        assert_eq!(warning.problem, ScanProblem::EmptyFile, "{case}: {warning}");
        assert_eq!(warning.standing, standing, "{case}: {warning}");
    }
}

/// Whether a scope asks for a server is a question the manifest and the
/// record answer. A file that will not read answers nothing, and an
/// unanswered question is never the answer that nothing is expected: the
/// warning keeps its remedy until the record can be read.
#[test]
fn ownership_evidence_that_cannot_be_read_keeps_the_warning_actionable() {
    let rows: [(&str, &str, &str); 3] = [
        ("a damaged record", "{\"version\": 10, \"entries\": ", ""),
        (
            "a record from a newer kendex",
            "{\"version\": 4000, \"entries\": {}}",
            "",
        ),
        (
            "a manifest under a retired schema",
            "{\"version\": 0}",
            "schema = 1\n",
        ),
    ];
    for (case, lock, manifest) in rows {
        let tmp = tempfile::tempdir().unwrap();
        let home = crate::test_util::rooted(&tmp);
        let env = Env::fake(&home, FakeOs::Linux);
        let path = container(&home, "");
        global_lock(&env, lock);
        if manifest.is_empty() {
            let _ = fs::remove_file(crate::manifest::manifest_path(&env, &Scope::Global));
        } else {
            global_manifest(&env, manifest);
        }

        let warnings = scan_global(&env);

        let warning = about(&warnings, &path);
        assert_eq!(warning.problem, ScanProblem::EmptyFile, "{case}: {warning}");
        assert_eq!(
            warning.standing,
            WarningStanding::Actionable,
            "{case}: {warning}"
        );
    }
}

/// A file the scan cannot open at all is not an empty container: nothing
/// read it, so nothing knows what is in it, and the reader still has a
/// permissions question to answer.
#[test]
fn a_container_that_cannot_be_read_stays_actionable() {
    let tmp = tempfile::tempdir().unwrap();
    let home = crate::test_util::rooted(&tmp);
    let env = Env::fake(&home, FakeOs::Linux);
    let path = home.join(".gemini/config/mcp_config.json");
    fs::create_dir_all(&path).unwrap();

    let warnings = scan_global(&env);

    let warning = about(&warnings, &path);
    assert!(
        matches!(warning.problem, ScanProblem::Unreadable { .. }),
        "{warning}"
    );
    assert_eq!(warning.standing, WarningStanding::Actionable, "{warning}");
}

/// Claude reads `~/.claude.json` again for every project — its own entries
/// live in there under the project's path — but an apply writes a
/// project's servers to that project's `.mcp.json` and only the personal
/// scope's to the user file. So the personal scope is the one whose record
/// can say whether a server belongs in it, and a pass that leaves that
/// scope out, as `kendex list --scope project` does, has read the
/// container without its writer and settles nothing. The writer is read
/// off `engine::mcp_registry`, the same mapping an apply writes through.
#[test]
fn a_container_read_without_the_scope_that_writes_it_stays_actionable() {
    let tmp = tempfile::tempdir().unwrap();
    let home = crate::test_util::rooted(&tmp);
    let env = Env::fake(&home, FakeOs::Linux);
    let project = home.join("dev/app");
    fs::create_dir_all(&project).unwrap();
    let scope = Scope::Project {
        root: project.clone(),
    };
    let catalog = home.join("shelf");
    let user_file = home.join(".claude.json");

    type Declared = Option<HarnessId>;
    let rows: [(&str, &[Scope], Declared, Declared, WarningStanding); 5] = [
        (
            "the writing scope is in the pass and asks for nothing",
            &[Scope::Global, scope.clone()],
            None,
            None,
            WarningStanding::UnusedEmptyContainer,
        ),
        (
            "the writing scope is in the pass and asks for a server",
            &[Scope::Global, scope.clone()],
            Some(HarnessId::Claude),
            None,
            WarningStanding::Actionable,
        ),
        (
            "only a reading scope is in the pass, nothing declared anywhere",
            std::slice::from_ref(&scope),
            None,
            None,
            WarningStanding::Actionable,
        ),
        (
            "only a reading scope is in the pass, the writer asks for a server",
            std::slice::from_ref(&scope),
            Some(HarnessId::Claude),
            None,
            WarningStanding::Actionable,
        ),
        (
            "a reading scope asks for a server, which goes to its own file",
            &[Scope::Global, scope.clone()],
            None,
            Some(HarnessId::Claude),
            WarningStanding::UnusedEmptyContainer,
        ),
    ];
    for (case, scopes, global, project_decl, standing) in rows {
        fs::write(&user_file, "").unwrap();
        for (at, declared) in [(&Scope::Global, global), (&scope, project_decl)] {
            match declared {
                Some(harness) => {
                    scope_manifest(&env, at, &manifest_declaring_server(&catalog, harness));
                }
                None => {
                    let _ = fs::remove_file(crate::manifest::manifest_path(&env, at));
                }
            }
        }

        let warnings = scan_scopes(&env, &BTreeMap::new(), scopes).warnings;

        let warning = about(&warnings, &user_file);
        assert_eq!(warning.problem, ScanProblem::EmptyFile, "{case}: {warning}");
        assert_eq!(warning.standing, standing, "{case}: {warning}");
    }
}

/// Gemini's settings.json is its hook registry and its MCP server list at
/// once. An empty one is missing a hook registry as much as a server list,
/// and the warning about it names whichever surface reached it first — so
/// the kind on the warning never decides this, the set of surfaces reading
/// the file does.
#[test]
fn a_container_another_kind_is_also_read_from_stays_actionable() {
    let tmp = tempfile::tempdir().unwrap();
    let home = crate::test_util::rooted(&tmp);
    let env = Env::fake(&home, FakeOs::Linux);
    let path = home.join(".gemini/settings.json");
    fs::create_dir_all(path.parent().expect("settings has a directory")).unwrap();
    fs::write(&path, "").unwrap();

    let warnings = scan_global(&env);

    let warning = about(&warnings, &path);
    assert_eq!(warning.problem, ScanProblem::EmptyFile, "{warning}");
    assert_eq!(warning.standing, WarningStanding::Actionable, "{warning}");
}
