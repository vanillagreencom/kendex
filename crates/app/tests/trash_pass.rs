//! The pass the desktop's apply and remove close on: the trash is brought
//! within its bounds once the command's own writes are done, what the
//! command itself moved there stays whatever the bounds say, and a pass
//! that stops is a note on the view rather than a failure of the command.
#![cfg(unix)]

use crate::test_util;
use test_util::{rooted, source_path};

use std::collections::BTreeSet;
use std::fs;
use std::path::PathBuf;

use kendex_app::audit::{AuditView, apply_scope, remove};
use kendex_core::env::{Env, FakeOs};
use kendex_core::model::{ItemKind, Scope};
use kendex_core::trash::{KEEP_DAYS_VAR, KEEP_MB_VAR};

const DAY: u64 = 86_400;

struct Fixture {
    _tmp: tempfile::TempDir,
    env: Env,
    scope: Scope,
    manifest: PathBuf,
    catalog: PathBuf,
}

/// The two desktop commands that close on the pass.
#[derive(Clone, Copy, Debug)]
enum Verb {
    /// The Audit page's apply, with orphan removal on, over a manifest
    /// the person has since taken the skill out of.
    Apply,
    /// The package page's remove.
    Remove,
}

/// A project with skill `deploy` installed by copy from a local catalog,
/// then the machine a fresh command gets, holding nothing of the install's
/// own and reading these two bounds.
#[allow(clippy::unwrap_used)]
fn installed(days: &str, mb: &str) -> Fixture {
    let tmp = tempfile::tempdir().unwrap();
    let home = rooted(&tmp);
    let project = home.join("dev/app");
    let catalog = home.join("catalog");
    fs::create_dir_all(catalog.join("skills/deploy")).unwrap();
    fs::write(
        catalog.join("skills/deploy/SKILL.md"),
        "---\nname: deploy\ndescription: ship it\n---\nUpstream.\n",
    )
    .unwrap();
    fs::create_dir_all(project.join(".claude")).unwrap();
    let manifest = project.join("kendex.toml");
    fs::write(&manifest, declaring(&catalog, true)).unwrap();
    let scope = Scope::Project {
        root: project.clone(),
    };
    let env = Env::fake(&home, FakeOs::Linux);
    let installed = apply_scope(&env, &scope, false).unwrap();
    assert!(
        installed.error.is_none(),
        "{}",
        installed
            .error
            .map(|error| error.message)
            .unwrap_or_default()
    );
    assert!(project.join(".claude/skills/deploy/SKILL.md").is_file());
    Fixture {
        env: env
            .next_invocation()
            .with_var(KEEP_DAYS_VAR, days)
            .with_var(KEEP_MB_VAR, mb),
        scope,
        manifest,
        catalog,
        _tmp: tmp,
    }
}

/// The manifest with skill `deploy` declared, or with the declaration
/// taken out by hand.
fn declaring(catalog: &std::path::Path, deploy: bool) -> String {
    let declaration = match deploy {
        true => "\n\n[skills.deploy]\nsource = \"cat\"",
        false => "",
    };
    format!(
        "schema = 6\n\n[sources.cat]\n{}\n\n[install]\nharnesses = [\"claude\"]\nmethod = \"copy\"{declaration}\n",
        source_path(catalog)
    )
}

/// An entry an earlier command moved into the trash `age` seconds ago
/// under `base`, holding one file of `bytes` bytes.
#[allow(clippy::unwrap_used)]
fn plant(f: &Fixture, age: u64, base: &str, bytes: usize) -> String {
    let stamp =
        kendex_core::clock::iso_from_unix(kendex_core::clock::unix_now() - age).replace(':', "-");
    let name = format!("{stamp}-{base}");
    let entry = f.env.trash_dir().join(&name);
    fs::create_dir_all(&entry).unwrap();
    fs::write(entry.join("blob"), vec![b'x'; bytes]).unwrap();
    name
}

#[allow(clippy::unwrap_used)]
fn names(f: &Fixture) -> BTreeSet<String> {
    fs::read_dir(f.env.trash_dir())
        .unwrap()
        .map(|entry| entry.unwrap().file_name().to_string_lossy().into_owned())
        .collect()
}

#[allow(clippy::unwrap_used)]
fn run(f: &Fixture, verb: Verb) -> AuditView {
    match verb {
        Verb::Apply => {
            fs::write(&f.manifest, declaring(&f.catalog, false)).unwrap();
            apply_scope(&f.env, &f.scope, true).unwrap()
        }
        Verb::Remove => remove(&f.env, &f.scope, ItemKind::Skill, "deploy").unwrap(),
    }
}

/// Both commands close on the pass after their own writes: under a size
/// bound of zero every entry an earlier command left goes, the tree this
/// command moved aside stays, and the view says what went. Under a bound
/// that is not a count the pass stops with everything intact, the command
/// still answers, and the view says why the entries were kept. One row per
/// command and per outcome.
#[test]
fn apply_and_remove_close_on_the_pass_and_say_what_it_did() {
    /// What the row is, the command, its two bounds, the line the view
    /// says, and whether the planted entries stay.
    type Row<'a> = (&'a str, Verb, (&'a str, &'a str), &'a str, bool);
    let rows: [Row; 3] = [
        (
            "apply",
            Verb::Apply,
            ("7", "0"),
            "trash: removed 3 older entries",
            false,
        ),
        (
            "remove",
            Verb::Remove,
            ("7", "0"),
            "trash: removed 3 older entries",
            false,
        ),
        (
            "apply under a bound that is not a count",
            Verb::Apply,
            ("7", "lots"),
            "trash: older entries kept (KENDEX_TRASH_KEEP_MB=\"lots\" is not a count)",
            true,
        ),
    ];
    for (what, verb, (days, mb), note, planted_stay) in rows {
        let f = installed(days, mb);
        let planted: BTreeSet<String> = [
            plant(&f, DAY, "young", 10),
            plant(&f, 3 * DAY, "large", 2 * 1024 * 1024),
            plant(&f, 40 * DAY, "old", 10),
        ]
        .into_iter()
        .collect();

        let view = run(&f, verb);

        assert!(
            view.error.is_none(),
            "{what}: {}",
            view.error.map(|error| error.message).unwrap_or_default()
        );
        assert!(
            view.notes.iter().any(|line| line == note),
            "{what}: {:?}",
            view.notes
        );
        let kept = names(&f);
        let moved_aside: Vec<&String> = kept
            .iter()
            .filter(|name| name.ends_with("-deploy"))
            .collect();
        assert_eq!(
            moved_aside.len(),
            1,
            "{what}: the tree this command moved aside: {kept:?}"
        );
        let planted_kept: BTreeSet<&String> = kept.intersection(&planted).collect();
        match planted_stay {
            true => assert_eq!(planted_kept.len(), planted.len(), "{what}: {kept:?}"),
            false => assert!(planted_kept.is_empty(), "{what}: {kept:?}"),
        }
    }
}
