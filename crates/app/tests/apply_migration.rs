//! What the app does with an unsupported manifest schema: says so, and
//! leaves it alone. The preview reports the refusal as a scope error and
//! the apply refuses too, so nothing rewrites a file this build cannot read
//! — the person's comments included.
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

/// The tables accepted by manifest schema 5 and rejected by schema 6.
const RETIRED: &str = "[safety-overrides.\"skill:gh:claude\"]\nreview-hash = \"abc\"\nruleset = 3\nfindings = [\"f1\"]\ngranted-at = \"2026-01-01T00:00:00Z\"\n\n[safety-reviews.\"skill:gh:claude\"]\nreview-hash = \"abc\"\nruleset = 3\n\n[safety-reviews.\"skill:gh:claude\".dismissed.f2]\nreason = \"intended\"\ndismissed-at = \"2026-01-01T00:00:00Z\"\n";

#[allow(clippy::unwrap_used)]
fn schema5_fixture() -> Fixture {
    fixture(|source| {
        format!(
            "{}\n{RETIRED}",
            KEPT.replace("{schema}", "5")
                .replace("{source}", &source_path(source))
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

/// A manifest this build cannot read is a scope error of its own kind, so
/// the page can say what to do with a file that is intact and the person's
/// own, and every byte of it (comments and trailing comments included) is
/// exactly where it was. One row per shape: a schema-5 manifest still
/// carrying the retired safety tables; a manifest naming no schema (a v0.1
/// file); a retired table put back by hand into a current manifest, which
/// is invalid rather than outdated.
#[test]
#[allow(clippy::unwrap_used)]
fn a_manifest_this_build_cannot_read_is_refused_and_left_byte_identical() {
    type Build = fn(&std::path::Path) -> String;
    let rows: [(&str, Build, ScopeErrorKind); 3] = [
        (
            "schema 5 with the retired tables",
            |source| {
                format!(
                    "{}\n{RETIRED}",
                    KEPT.replace("{schema}", "5")
                        .replace("{source}", &source_path(source))
                )
            },
            ScopeErrorKind::ManifestOutdated,
        ),
        (
            "no schema at all",
            |source| {
                KEPT.replace("schema = {schema}\n", "")
                    .replace("{source}", &source_path(source))
            },
            ScopeErrorKind::ManifestOutdated,
        ),
        (
            "a retired table in a current schema",
            |source| {
                format!(
                    "{}\n{RETIRED}",
                    KEPT.replace("{schema}", &MANIFEST_SCHEMA.to_string())
                        .replace("{source}", &source_path(source))
                )
            },
            ScopeErrorKind::ManifestInvalid,
        ),
    ];
    for (what, build, kind) in rows {
        let f = fixture(build);
        let original = fs::read_to_string(&f.manifest_path).unwrap();

        let before = view(&f.env, &f.scope);
        let error = before.error.expect(what);
        assert!(
            std::mem::discriminant(&error.kind) == std::mem::discriminant(&kind),
            "{what}: {}",
            error.message
        );
        assert!(before.plan.is_empty(), "{what}: {:?}", before.plan);
        assert_eq!(
            fs::read_to_string(&f.manifest_path).unwrap(),
            original,
            "{what}"
        );
    }
}

/// The apply refuses the same file the preview refused, and installs
/// nothing.
#[test]
#[allow(clippy::unwrap_used)]
fn applying_an_older_manifest_refuses_and_installs_nothing() {
    let f = schema5_fixture();
    let original = fs::read_to_string(&f.manifest_path).unwrap();

    assert!(apply_scope(&f.env, &f.scope, false).is_err());
    assert_eq!(fs::read_to_string(&f.manifest_path).unwrap(), original);
    assert!(
        !f.scope_root().join(".claude/skills/gh").exists(),
        "a refused scope installs nothing"
    );
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
