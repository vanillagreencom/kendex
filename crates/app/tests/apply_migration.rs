//! The apply the user confirms must do what the preview said. An older
//! manifest's first apply promises "Upgrade kendex.toml to the current
//! format" — this pins that the app's apply path actually writes it,
//! rather than re-planning from a mutation-normalized manifest that no
//! longer looks old, and that the upgrade moves only the bytes it has to.
#![cfg(unix)]

#[path = "../../test_util.rs"]
mod test_util;
use test_util::source_path;

use std::fs;

use kendex_app::audit::{apply_scope, view};
use kendex_core::env::{Env, FakeOs};
use kendex_core::manifest::MANIFEST_SCHEMA;
use kendex_core::model::Scope;

const UPGRADE_OP: &str = "Upgrade kendex.toml to the current format";

struct Fixture {
    _tmp: tempfile::TempDir,
    env: Env,
    scope: Scope,
    manifest_path: std::path::PathBuf,
}

impl Fixture {
    fn scope_root(&self) -> &std::path::Path {
        match &self.scope {
            Scope::Project { root } => root,
            Scope::Global => unreachable!("every fixture here is a project"),
        }
    }
}

#[allow(clippy::unwrap_used)]
fn v01_fixture() -> Fixture {
    fixture(|source| {
        format!(
            "# my project setup\nschema = 1\n\n[sources.cat]\n{}\n\n[install]\nharnesses = [\"claude\"]\nmethod = \"symlink\"\n\n[skills.gh]\nsource = \"cat\"\n",
            source_path(&source)
        )
    })
}

/// The part of a schema-5 manifest that survives: comments, spacing and a
/// trailing comment on a value, every byte the upgrade must keep.
const KEPT: &str = "# my project setup\nschema = 5\n\n# where the content comes from\n[sources.cat]\n{source}\n\n[install]\nharnesses = [\"claude\"]\nmethod = \"symlink\"\n\n[skills.gh]\nsource = \"cat\"   # keep this\n";

/// The tables schema 6 retired, as a pre-6 kendex wrote them.
const RETIRED: &str = "[safety-overrides.\"skill:gh:claude\"]\nreview-hash = \"abc\"\nruleset = 3\nfindings = [\"f1\"]\ngranted-at = \"2026-01-01T00:00:00Z\"\n\n[safety-reviews.\"skill:gh:claude\"]\nreview-hash = \"abc\"\nruleset = 3\n\n[safety-reviews.\"skill:gh:claude\".dismissed.f2]\nreason = \"intended\"\ndismissed-at = \"2026-01-01T00:00:00Z\"\n";

#[allow(clippy::unwrap_used)]
fn schema5_fixture() -> Fixture {
    fixture(|source| {
        // The blank line introduces the retired table, and goes with it.
        format!(
            "{}\n{RETIRED}",
            KEPT.replace("{source}", &source_path(&source))
        )
    })
}

#[allow(clippy::unwrap_used)]
fn fixture(manifest: impl FnOnce(&std::path::Path) -> String) -> Fixture {
    let tmp = tempfile::tempdir().unwrap();
    let home = tmp.path().to_path_buf();
    let env = Env::fake(&home, FakeOs::Linux);
    let project = home.join("dev/app");
    fs::create_dir_all(project.join(".claude")).unwrap();

    // The catalog sits under a name holding an apostrophe: every fixture
    // here writes its path into TOML, and an apostrophe is what closes a
    // literal string early. Spelled by hand rather than by the serializer,
    // the manifests below stop parsing.
    let source = home.join("o'brien/catalog");
    fs::create_dir_all(source.join("skills/gh")).unwrap();
    fs::write(
        source.join("skills/gh/SKILL.md"),
        "---\nname: gh\ndescription: Work with GitHub.\n---\nBody.\n",
    )
    .unwrap();

    let manifest_path = project.join("kendex.toml");
    fs::write(&manifest_path, manifest(&source)).unwrap();
    fs::write(
        project.join(".kendex-lock.json"),
        format!(
            "{{\n  \"version\": 1,\n  \"root\": {},\n  \"entries\": {{}}\n}}\n",
            serde_json::to_string(&project.display().to_string()).unwrap()
        ),
    )
    .unwrap();

    Fixture {
        env,
        scope: Scope::Project {
            root: project.clone(),
        },
        manifest_path,
        _tmp: tmp,
    }
}

#[test]
#[allow(clippy::unwrap_used)]
fn apply_performs_the_upgrade_the_preview_promised() {
    let f = v01_fixture();

    let before = view(&f.env, &f.scope);
    assert!(
        before.plan.iter().any(|op| op == UPGRADE_OP),
        "preview must promise the schema upgrade, got: {:?}",
        before.plan
    );

    let original = fs::read_to_string(&f.manifest_path).unwrap();
    apply_scope(&f.env, &f.scope, false).unwrap();

    let migrated = fs::read_to_string(&f.manifest_path).unwrap();
    assert_eq!(
        migrated,
        original.replacen("schema = 1", &format!("schema = {MANIFEST_SCHEMA}"), 1),
        "the upgrade must change the schema line and nothing else"
    );

    let after = view(&f.env, &f.scope);
    assert!(
        !after.plan.iter().any(|op| op == UPGRADE_OP),
        "a second look must not promise the upgrade again, got: {:?}",
        after.plan
    );
}

/// A schema-5 manifest still carries the safety-decision tables. One apply
/// upgrades it: the schema line moves, the retired tables go, and every
/// other byte — comments, spacing, a trailing comment — stays exactly where
/// it was. The declared skill installs in the same apply.
#[test]
#[allow(clippy::unwrap_used)]
fn the_upgrade_drops_the_retired_tables_and_keeps_every_other_byte() {
    let f = schema5_fixture();
    let before = view(&f.env, &f.scope);
    assert!(
        before.error.is_none(),
        "{:?}",
        before.error.as_ref().map(|error| &error.message)
    );
    assert!(
        before.plan.iter().any(|op| op == UPGRADE_OP),
        "preview must promise the schema upgrade, got: {:?}",
        before.plan
    );

    let original = fs::read_to_string(&f.manifest_path).unwrap();
    let kept = original
        .strip_suffix(RETIRED)
        .unwrap()
        .strip_suffix('\n')
        .unwrap();
    apply_scope(&f.env, &f.scope, false).unwrap();

    let migrated = fs::read_to_string(&f.manifest_path).unwrap();
    assert_eq!(
        migrated,
        kept.replacen("schema = 5", &format!("schema = {MANIFEST_SCHEMA}"), 1),
        "the upgrade moves the schema line, cuts the retired tables and nothing else"
    );
    assert!(!migrated.contains("safety-overrides"), "{migrated}");
    assert!(!migrated.contains("safety-reviews"), "{migrated}");
    assert!(migrated.contains("# keep this"), "{migrated}");
    assert!(
        f.scope_root().join(".claude/skills/gh").is_symlink(),
        "the declared skill installs in the same apply"
    );

    let after = view(&f.env, &f.scope);
    assert!(
        !after.plan.iter().any(|op| op == UPGRADE_OP),
        "a second look must not promise the upgrade again, got: {:?}",
        after.plan
    );
}

/// The retired tables in spellings the text cut does not recognise — a
/// quoted header, a top-level dotted key, an inline table. The loader gate
/// sends each to the full rewrite: after one apply the file loads at the
/// current schema and carries neither name. (Written surgically, such a
/// file would keep the table and be refused on every later load.)
#[test]
#[allow(clippy::unwrap_used)]
fn every_spelling_of_a_retired_table_is_gone_after_one_apply() {
    let quoted = (
        "",
        "[\"safety-overrides\".\"skill:gh:claude\"]\nreview-hash = \"abc\"\n",
    );
    let dotted = (
        "safety-reviews.\"skill:gh:claude\".review-hash = \"abc\"\n",
        "",
    );
    let inline = (
        "safety-overrides = { \"skill:gh:claude\" = { review-hash = \"abc\" } }\n",
        "",
    );
    for (top, tail) in [quoted, dotted, inline] {
        let f = fixture(|source| {
            let kept = KEPT.replace("{source}", &source_path(&source));
            format!(
                "{}\n{tail}",
                kept.replacen("schema = 5\n", &format!("schema = 5\n{top}"), 1)
            )
        });
        let before = view(&f.env, &f.scope);
        assert!(
            before.error.is_none(),
            "{top}{tail}: {:?}",
            before.error.map(|e| e.message)
        );
        assert!(
            before.plan.iter().any(|op| op == UPGRADE_OP),
            "{:?}",
            before.plan
        );

        apply_scope(&f.env, &f.scope, false).unwrap();

        let migrated = fs::read_to_string(&f.manifest_path).unwrap();
        assert!(
            !migrated.contains("safety-overrides"),
            "{top}{tail}: {migrated}"
        );
        assert!(
            !migrated.contains("safety-reviews"),
            "{top}{tail}: {migrated}"
        );
        assert!(
            migrated.contains(&format!("schema = {MANIFEST_SCHEMA}")),
            "{migrated}"
        );
        assert!(migrated.contains("[skills.gh]"), "{migrated}");
        let after = view(&f.env, &f.scope);
        assert!(
            after.error.is_none(),
            "{top}{tail}: {:?}",
            after.error.map(|e| e.message)
        );
        assert!(
            !after.plan.iter().any(|op| op == UPGRADE_OP),
            "{:?}",
            after.plan
        );
    }
}

/// A manifest that vanished between the preview and the click is an error
/// said out loud, never a silent empty apply.
#[test]
#[allow(clippy::unwrap_used)]
fn applying_without_a_manifest_is_an_error() {
    let f = v01_fixture();
    fs::remove_file(&f.manifest_path).unwrap();
    let Err(error) = apply_scope(&f.env, &f.scope, false) else {
        panic!("applying without a manifest must error");
    };
    assert!(error.contains("no manifest"), "got: {error}");
}
