//! The pass the desktop's writes close on: the trash is brought within its
//! bounds once a command's own writes are done, what the command itself
//! moved there stays whatever the bounds say, and a pass that stops is a
//! line on the account rather than a failure of the command.
#![cfg(unix)]

use crate::repo_effects::fixture::git;
use crate::test_util;
use test_util::{rooted, source_path};

use std::collections::BTreeSet;
use std::fs;
use std::path::PathBuf;

use kendex_app::audit::{apply_scope, remove};
use kendex_app::commit_offer::{RestoreResult, restore};
use kendex_app::unsubscribe::unsubscribe;
use kendex_core::env::{Env, FakeOs};
use kendex_core::model::{ItemKind, Scope};
use kendex_core::trash::{KEEP_DAYS_VAR, KEEP_MB_VAR};

const DAY: u64 = 86_400;

/// The rendered skill, relative to the project.
const RENDERED: &str = ".claude/skills/deploy/SKILL.md";

struct Fixture {
    _tmp: tempfile::TempDir,
    env: Env,
    scope: Scope,
    project: PathBuf,
}

/// Three commands that move a copy into the trash, one per call site of
/// the pass and one more through the same site.
#[derive(Clone, Copy, Debug)]
enum Verb {
    /// The package page's remove: a report through the one executor.
    Remove,
    /// The marketplace's unsubscribe without keeping the packages: a
    /// report through the same executor, answered with its own shape.
    Unsubscribe,
    /// The project-changes restore of the rendered skill, which moves it
    /// to the trash with no plan behind it.
    Restore,
}

/// A git project with skill `deploy` installed by copy from a local
/// catalog and not committed, then the machine a fresh command gets,
/// holding nothing of the install's own and reading these two bounds.
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
    git(&project, &["init", "--quiet", "-b", "main"]);
    fs::write(project.join("README.md"), "the app\n").unwrap();
    git(&project, &["add", "."]);
    git(&project, &["commit", "--quiet", "-m", "start"]);
    fs::write(
        project.join("kendex.toml"),
        format!(
            "schema = 6\n\n[sources.cat]\n{}\n\n[install]\nharnesses = [\"claude\"]\nmethod = \"copy\"\n\n[skills.deploy]\nsource = \"cat\"\n",
            source_path(&catalog)
        ),
    )
    .unwrap();
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
    assert!(project.join(RENDERED).is_file());
    Fixture {
        env: env
            .next_invocation()
            .with_var(KEEP_DAYS_VAR, days)
            .with_var(KEEP_MB_VAR, mb),
        scope,
        project,
        _tmp: tmp,
    }
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

/// Every name the trash directory holds but the size record's.
#[allow(clippy::unwrap_used)]
fn names(f: &Fixture) -> BTreeSet<String> {
    fs::read_dir(f.env.trash_dir())
        .unwrap()
        .map(|entry| entry.unwrap().file_name().to_string_lossy().into_owned())
        .filter(|name| name != kendex_core::trash::SIZES_FILE)
        .collect()
}

/// Run the command and hand back the account it answered with; a restore
/// answers with paths alone, so its account is empty.
#[allow(clippy::unwrap_used)]
fn run(f: &Fixture, verb: Verb) -> Vec<String> {
    match verb {
        Verb::Remove => {
            remove(&f.env, &f.scope, ItemKind::Skill, "deploy")
                .unwrap()
                .undone
        }
        Verb::Unsubscribe => {
            unsubscribe(&f.env, &f.scope, "cat", false, false)
                .unwrap()
                .undone
        }
        Verb::Restore => {
            let result = restore(&f.env, f.project.clone(), vec![RENDERED.to_owned()]).unwrap();
            match result {
                RestoreResult::Effect { effect } => {
                    assert!(
                        effect.removed.contains(&RENDERED.to_owned()),
                        "the rendered skill was not taken away: {effect:?}"
                    );
                }
                RestoreResult::Refused { .. } => panic!("the restore refused: {result:?}"),
            }
            Vec::new()
        }
    }
}

/// Every command closes on the pass after its own writes: under a size
/// bound of zero every entry an earlier command left goes, what this
/// command moved aside stays, and the account says what went where the
/// command answers with one. Under a bound that is not a count the pass
/// stops with everything intact, the command still answers, and the
/// account says why the entries were kept. One row per command and per
/// outcome.
#[test]
fn every_write_closes_on_the_pass_and_the_account_says_what_it_did() {
    /// What the row is, the command, its two bounds, the line the account
    /// carries where the command has one, and whether the planted entries
    /// stay.
    type Row<'a> = (&'a str, Verb, (&'a str, &'a str), Option<&'a str>, bool);
    let rows: [Row; 4] = [
        (
            "remove",
            Verb::Remove,
            ("7", "0"),
            Some("trash: removed 3 older entries"),
            false,
        ),
        (
            "unsubscribe",
            Verb::Unsubscribe,
            ("7", "0"),
            Some("trash: removed 3 older entries"),
            false,
        ),
        ("restore", Verb::Restore, ("7", "0"), None, false),
        (
            "remove under a bound that is not a count",
            Verb::Remove,
            ("7", "lots"),
            Some("trash: pass stopped (KENDEX_TRASH_KEEP_MB=\"lots\" is not a count)"),
            true,
        ),
    ];
    for (what, verb, (days, mb), line, planted_stay) in rows {
        let f = installed(days, mb);
        let planted: BTreeSet<String> = [
            plant(&f, DAY, "young", 10),
            plant(&f, 3 * DAY, "large", 2 * 1024 * 1024),
            plant(&f, 40 * DAY, "old", 10),
        ]
        .into_iter()
        .collect();

        let account = run(&f, verb);

        assert_eq!(
            account.iter().find(|said| said.starts_with("trash:")),
            line.map(str::to_owned).as_ref(),
            "{what}: {account:?}"
        );
        let kept = names(&f);
        let own: BTreeSet<&String> = kept.difference(&planted).collect();
        assert!(
            own.iter()
                .any(|name| name.ends_with("-deploy") || name.ends_with("-SKILL.md")),
            "{what}: what this command moved aside is gone: {kept:?}"
        );
        assert!(
            !f.project.join(RENDERED).exists(),
            "{what}: the rendered skill is still installed"
        );
        let planted_kept: BTreeSet<&String> = kept.intersection(&planted).collect();
        match planted_stay {
            true => assert_eq!(planted_kept.len(), planted.len(), "{what}: {kept:?}"),
            false => assert!(planted_kept.is_empty(), "{what}: {kept:?}"),
        }
    }
}
