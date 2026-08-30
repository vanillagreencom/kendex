//! What the app does with a manifest an older kendex wrote: says so, and
//! leaves it alone. The preview reports the refusal as a scope error and
//! the apply refuses too, so nothing rewrites a file this build cannot
//! read — the person's comments included.
#![cfg(unix)]

#[path = "../../test_util.rs"]
mod test_util;
use test_util::source_path;

use std::fs;

use kendex_app::audit::{ScopeErrorKind, apply_scope, view};
use kendex_core::env::{Env, FakeOs};
use kendex_core::manifest::MANIFEST_SCHEMA;
use kendex_core::model::Scope;

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

/// The part of an older manifest a refusal must not touch: comments,
/// spacing and a trailing comment on a value.
const KEPT: &str = "# my project setup\nschema = {schema}\n\n# where the content comes from\n[sources.cat]\n{source}\n\n[install]\nharnesses = [\"claude\"]\nmethod = \"symlink\"\n\n[skills.gh]\nsource = \"cat\"   # keep this\n";

/// The tables schema 6 retired, as a pre-6 kendex wrote them.
const RETIRED: &str = "[safety-overrides.\"skill:gh:claude\"]\nreview-hash = \"abc\"\nruleset = 3\nfindings = [\"f1\"]\ngranted-at = \"2026-01-01T00:00:00Z\"\n\n[safety-reviews.\"skill:gh:claude\"]\nreview-hash = \"abc\"\nruleset = 3\n\n[safety-reviews.\"skill:gh:claude\".dismissed.f2]\nreason = \"intended\"\ndismissed-at = \"2026-01-01T00:00:00Z\"\n";

#[allow(clippy::unwrap_used)]
fn schema5_fixture() -> Fixture {
    fixture(|source| {
        format!(
            "{}\n{RETIRED}",
            KEPT.replace("{schema}", "5")
                .replace("{source}", &source_path(&source))
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

    Fixture {
        env,
        scope: Scope::Project {
            root: project.clone(),
        },
        manifest_path,
        _tmp: tmp,
    }
}

/// A schema-5 manifest still carrying the retired safety tables. The
/// preview says it cannot be read, the apply refuses, and every byte —
/// comments and trailing comments included — is exactly where it was.
#[test]
#[allow(clippy::unwrap_used)]
fn an_older_manifest_is_refused_and_left_byte_identical() {
    let f = schema5_fixture();
    let original = fs::read_to_string(&f.manifest_path).unwrap();

    let before = view(&f.env, &f.scope);
    let error = before.error.expect("an older manifest is a scope error");
    assert!(
        matches!(error.kind, ScopeErrorKind::ManifestOutdated),
        "its own kind, so the page can say what to do with a file that is
         intact and the person's own"
    );
    assert!(error.message.contains("schema 5"), "{}", error.message);
    assert!(error.message.contains("install fresh"), "{}", error.message);
    assert!(before.plan.is_empty(), "{:?}", before.plan);

    let Err(refused) = apply_scope(&f.env, &f.scope, false) else {
        panic!("applying an older manifest must refuse");
    };
    assert!(refused.contains("install fresh"), "{refused}");
    assert_eq!(fs::read_to_string(&f.manifest_path).unwrap(), original);
    assert!(
        !f.scope_root().join(".claude/skills/gh").exists(),
        "a refused scope installs nothing"
    );
}

/// A manifest naming no schema — a v0.1 file — is the same refusal.
#[test]
#[allow(clippy::unwrap_used)]
fn a_schema_less_manifest_is_refused_the_same_way() {
    let f = fixture(|source| {
        KEPT.replace("schema = {schema}\n", "")
            .replace("{source}", &source_path(&source))
    });
    let original = fs::read_to_string(&f.manifest_path).unwrap();

    let error = view(&f.env, &f.scope)
        .error
        .expect("a schema-less manifest is a scope error");
    assert!(error.message.contains("no schema"), "{}", error.message);
    assert_eq!(fs::read_to_string(&f.manifest_path).unwrap(), original);
}

/// A retired table put back by hand into a current manifest is named as
/// the stray key it is, not silently dropped on the next write.
#[test]
#[allow(clippy::unwrap_used)]
fn a_retired_table_in_a_current_manifest_is_named_not_dropped() {
    let f = fixture(|source| {
        format!(
            "{}\n{RETIRED}",
            KEPT.replace("{schema}", &MANIFEST_SCHEMA.to_string())
                .replace("{source}", &source_path(&source))
        )
    });
    let original = fs::read_to_string(&f.manifest_path).unwrap();

    let error = view(&f.env, &f.scope)
        .error
        .expect("a stray table is a scope error");
    assert!(matches!(error.kind, ScopeErrorKind::ManifestInvalid));
    assert!(
        error.message.contains("safety-overrides"),
        "the table is named: {}",
        error.message
    );
    assert_eq!(fs::read_to_string(&f.manifest_path).unwrap(), original);
}

/// A manifest that vanished between the preview and the click is an error
/// said out loud, never a silent empty apply.
#[test]
#[allow(clippy::unwrap_used)]
fn applying_without_a_manifest_is_an_error() {
    let f = schema5_fixture();
    fs::remove_file(&f.manifest_path).unwrap();
    let Err(error) = apply_scope(&f.env, &f.scope, false) else {
        panic!("applying without a manifest must error");
    };
    assert!(error.contains("no manifest"), "got: {error}");
}
