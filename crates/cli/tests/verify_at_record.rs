//! `kendex verify --at-record`: each package that follows its source is
//! rendered at the commit the install record names, and each such commit
//! is held to the history of the one its source resolves to now and, with
//! `--base`, to not being older than the base revision's record.
//!
//! The fixture is `verify_records`'s consumer. The must-fail controls are
//! the history and floor checks in `attest::record`: each off-history and
//! rollback row passes with its check removed. The declaration row's
//! control is its own plain verify, which still reads the current
//! closure; reading that closure under `--at-record` too turns the row
//! red.
#![cfg(unix)]

use std::fs;

use kendex_core::attest::{Document, State};
use kendex_core::drift::report::Remedy;
use kendex_core::env::Env;
use kendex_core::model::HarnessId;

use super::verify_records::{
    INSTALLED, RECORD, World, commit, edit_json, git, kendex, row, said, verify, verify_scope,
    world, write,
};

/// One `--at-record` run of the project scope, with the document it
/// printed.
#[allow(clippy::unwrap_used)]
fn at_record(world: &World, base: Option<&str>) -> (std::process::Output, Document) {
    let mut args = vec!["verify", "--scope", "project", "--json", "--at-record"];
    if let Some(base) = base {
        args.extend(["--base", base]);
    }
    let output = kendex(&world.home, &world.project, &args);
    let document: Document = serde_json::from_slice(&output.stdout)
        .unwrap_or_else(|error| panic!("the document does not parse: {error}\n{}", said(&output)));
    (output, document)
}

/// One edit to the record's JSON.
type RecordEdit = Box<dyn Fn(&mut serde_json::Value)>;

/// The stale list as (source, recorded, resolved).
fn trails(document: &Document) -> Vec<(&str, &str, &str)> {
    document
        .stale
        .iter()
        .map(|stale| {
            (
                stale.source.as_str(),
                stale.recorded.as_str(),
                stale.resolved.as_str(),
            )
        })
        .collect()
}

/// The record row's detail, which names each problem the record check
/// found.
#[allow(clippy::unwrap_used)]
fn record_detail(document: &Document) -> String {
    row(document, "record", RECORD, None)
        .unwrap()
        .detail
        .clone()
        .unwrap_or_default()
}

#[allow(clippy::unwrap_used)]
fn head(dir: &std::path::Path) -> String {
    git(dir, &["rev-parse", "HEAD"]).trim().to_owned()
}

/// Appends a paragraph to a catalog file.
#[allow(clippy::unwrap_used)]
fn append(world: &World, path: &str, text: &str) {
    let path = world.catalog.join(path);
    let before = fs::read_to_string(&path).unwrap();
    write(&path, &format!("{before}{text}"));
}

/// The same source-backed packages installed globally, with a separate
/// record and renders from the project's copies.
fn install_global(world: &World) -> Env {
    let env = Env::host_rooted(&world.home);
    write(
        &env.global_manifest_file(),
        &format!(
            "schema = 6\n[sources.cat]\nrepo = \"file://{}\"\n[install]\nharnesses = [\"claude\", \"codex\"]\nmethod = \"copy\"\n[skills.second]\nsource = \"cat\"\n[agents.review]\nsource = \"cat\"\nharnesses = [\"claude\"]\n[bundles.starter]\nsource = \"cat\"\nharnesses = [\"codex\"]\n",
            world.catalog.display(),
        ),
    );
    let output = kendex(
        &world.home,
        &world.project,
        &["apply", "-y", "--leave", "--scope", "global"],
    );
    assert!(output.status.success(), "{}", said(&output));
    env
}

/// A catalog that moved on past the install, a skill and a Pi extension
/// both changed, stales the plain verify, while the same record weighed
/// at its own commits is clean and lists every source commit it trails.
/// A record that is current trails nothing. A commit the mirror holds off
/// the declared revision's history, here a side branch whose bytes are
/// the installed ones, renders identically, so only the history check
/// refuses it, for an item's entries and for a set alike.
#[test]
#[allow(clippy::unwrap_used)]
fn at_record_weighs_a_record_the_source_moved_past_on_its_own_commits() {
    let world = world();
    install_global(&world);
    let (current, document) = at_record(&world, None);
    assert!(current.status.success(), "{}", said(&current));
    assert_eq!(trails(&document), Vec::new(), "{document:?}");

    let installed_at = head(&world.catalog);
    git(&world.catalog, &["checkout", "-q", "-b", "side"]);
    write(&world.catalog.join("NOTES.md"), "A side note.\n");
    commit(&world.catalog, "a side branch");
    let side = head(&world.catalog);
    git(&world.catalog, &["checkout", "-q", "main"]);
    append(
        &world,
        "skills/second/SKILL.md",
        "\nA paragraph added later.\n",
    );
    append(
        &world,
        "pi-extensions/@scope/widgets/index.js",
        "export const later = 2;\n",
    );
    commit(&world.catalog, "the catalog moves on");
    let tip = head(&world.catalog);
    let fetched = kendex(&world.home, &world.project, &["source", "refresh"]);
    assert!(fetched.status.success(), "{}", said(&fetched));

    let (plain, plain_document) = verify(&world, None);
    assert!(!plain.status.success(), "{}", said(&plain));
    assert_eq!(plain_document.version, 1);
    let stale = row(&plain_document, "skill", "second", Some(HarnessId::Claude)).unwrap();
    assert_eq!(stale.state, State::Failed);
    assert_eq!(stale.remedy, Some(Remedy::Refresh { global: false }));
    let (global, global_document) = verify_scope(&world, "global", None);
    assert!(!global.status.success(), "{}", said(&global));
    let stale = row(&global_document, "skill", "second", Some(HarnessId::Claude)).unwrap();
    assert_eq!(stale.state, State::Failed);
    assert_eq!(stale.remedy, Some(Remedy::Refresh { global: true }));
    let (held, document) = at_record(&world, None);
    assert!(held.status.success(), "{}", said(&held));
    assert_eq!(
        trails(&document),
        vec![
            ("cat", installed_at.as_str(), tip.as_str()),
            ("picat", installed_at.as_str(), tip.as_str()),
            ("spare", installed_at.as_str(), tip.as_str()),
        ],
        "{document:?}"
    );

    let project = world.project.clone();
    let off_history: [(&str, RecordEdit, String); 2] = [
        (
            "an item's entries",
            Box::new({
                let side = side.clone();
                move |lock| {
                    for key in ["skill:second:claude", "skill:second:codex"] {
                        lock["entries"][key]["sourceCommit"] =
                            serde_json::Value::String(side.clone());
                    }
                }
            }),
            format!("skill second: held at {side} is not on the declared revision's history"),
        ),
        (
            "a set",
            Box::new({
                let side = side.clone();
                move |lock| {
                    lock["bundles"]["starter"]["commit"] = serde_json::Value::String(side.clone())
                }
            }),
            format!("set starter: held at {side} is not on the declared revision's history"),
        ),
    ];
    for (label, edit, problem) in off_history {
        git(&project, &["checkout", "-q", "--", RECORD]);
        edit_json(&project.join(RECORD), edit);
        let (output, document) = at_record(&world, None);
        assert!(!output.status.success(), "{label}: {}", said(&output));
        let detail = record_detail(&document);
        assert!(detail.contains(&problem), "{label}: {detail}");
    }
}

/// Sets the `dependencies.required` line of the catalog's `second` skill.
fn requires(world: &World, required: &str) {
    write(
        &world.catalog.join("skills/second/SKILL.md"),
        &format!(
            "---\nname: second\ndescription: a second skill\ndependencies:\n  required: [{required}]\n---\n# Second\n\nBody.\n"
        ),
    );
}

/// The states every row naming `name` holds.
fn states<'a>(document: &'a Document, name: &str) -> Vec<&'a State> {
    document
        .rows
        .iter()
        .filter(|row| row.name == name)
        .map(|row| &row.state)
        .collect()
}

/// A refresh whose skill required one dependency, `first`, and whose
/// catalog later required a second, `third`, of that skill: the closure
/// verify declares is read at the commit the record holds the skill at, as
/// the render is, so the new dependency is not owed a record entry and
/// every checked row is OK. The plain verify reads the catalog now and still owes
/// `third` an entry.
#[test]
#[allow(clippy::unwrap_used)]
fn at_record_declares_the_dependencies_the_recorded_commit_required() {
    let world = world();
    write(
        &world.catalog.join("skills/first/SKILL.md"),
        "---\nname: first\ndescription: a first skill\n---\n# First\n",
    );
    requires(&world, "first");
    commit(&world.catalog, "second requires first");
    let output = kendex(&world.home, &world.project, &["refresh", "-y", "--leave"]);
    assert!(output.status.success(), "{}", said(&output));
    commit(&world.project, "refreshed");
    let (refreshed, document) = at_record(&world, None);
    assert!(refreshed.status.success(), "{}", said(&refreshed));
    let installed = states(&document, "first");
    assert!(
        !installed.is_empty() && installed.iter().all(|state| **state == State::Ok),
        "{document:?}"
    );

    write(
        &world.catalog.join("skills/third/SKILL.md"),
        "---\nname: third\ndescription: a third skill\n---\n# Third\n",
    );
    requires(&world, "first, third");
    commit(&world.catalog, "second requires third too");
    let fetched = kendex(&world.home, &world.project, &["source", "refresh"]);
    assert!(fetched.status.success(), "{}", said(&fetched));

    let (plain, document) = verify(&world, None);
    assert!(!plain.status.success(), "{}", said(&plain));
    let owed = states(&document, "third");
    assert!(
        !owed.is_empty() && owed.iter().all(|state| **state == State::Unrecorded),
        "{document:?}"
    );

    let (held, document) = at_record(&world, None);
    assert!(held.status.success(), "{}", said(&held));
    assert_eq!(
        states(&document, "third"),
        Vec::<&State>::new(),
        "{document:?}"
    );
    // The fixture's hook pin notices stand under either reading and never
    // fail a run; every other row is a checked one.
    assert!(
        document.clean
            && document.failed == 0
            && document
                .rows
                .iter()
                .all(|row| matches!(row.state, State::Ok | State::Notice)),
        "{document:?}"
    );
}

/// A change that puts back an older install, record and renders together,
/// renders clean at its own commits, and the base revision's record is
/// what refuses it: every held commit is at least as new as the one that
/// record names.
#[test]
#[allow(clippy::unwrap_used)]
fn at_record_refuses_a_record_older_than_the_base_record() {
    let world = world();
    append(
        &world,
        "skills/second/SKILL.md",
        "\nA paragraph added later.\n",
    );
    commit(&world.catalog, "the catalog moves on");
    let output = kendex(&world.home, &world.project, &["refresh", "-y", "--leave"]);
    assert!(output.status.success(), "{}", said(&output));
    commit(&world.project, "brought current");
    git(&world.project, &["tag", "current"]);
    git(&world.project, &["checkout", "-q", INSTALLED, "--", "."]);
    commit(&world.project, "the older install put back");

    let (unbounded, _) = at_record(&world, None);
    assert!(unbounded.status.success(), "{}", said(&unbounded));
    let (bounded, document) = at_record(&world, Some("current"));
    assert!(!bounded.status.success(), "{}", said(&bounded));
    let detail = record_detail(&document);
    assert!(
        detail.contains("skill second: held at")
            && detail.contains("the base revision's record names")
            && detail.contains("which is not on its history"),
        "{detail}"
    );
    assert_eq!(row(&document, "record", RECORD, None).unwrap().remedy, None);
}

/// Hand-edited head commits and hashes cannot be repaired by fetching an
/// invented commit or reapplying the held record. They need scope refresh.
#[test]
#[allow(clippy::unwrap_used)]
fn head_record_failures_carry_a_scoped_refresh_remedy() {
    let world = world();
    let env = install_global(&world);
    for (scope, record_path, global) in [
        ("project", world.project.join(RECORD), false),
        ("global", env.global_lock_file(), true),
    ] {
        let original = fs::read_to_string(&record_path).unwrap();
        for path in [
            vec!["entries", "skill:second:claude", "sourceCommit"],
            vec!["sources", "cat", "commit"],
            vec!["bundles", "starter", "commit"],
            vec!["entries", "skill:second:claude", "sourceHash"],
            vec!["entries", "skill:second:claude", "renderedHash"],
        ] {
            write(&record_path, &original);
            edit_json(&record_path, |lock| {
                let value = path.iter().fold(lock, |value, key| &mut value[*key]);
                *value = "deadbeefdeadbeefdeadbeefdeadbeefdeadbeef".into();
            });
            let (output, document) = verify_scope(&world, scope, None);
            assert!(!output.status.success(), "{}", said(&output));
            let record = document
                .rows
                .iter()
                .find(|row| row.kind == "record")
                .unwrap();
            assert_eq!(record.state, State::Failed, "{path:?}");
            assert_eq!(
                record.remedy,
                Some(Remedy::Refresh { global }),
                "{scope}: {path:?}"
            );
        }
        write(&record_path, &original);
    }
}

/// A removed declaration permits refresh to remove an unchanged copy.
/// A person-edited copy stays in place and carries no refresh action.
#[test]
#[allow(clippy::unwrap_used)]
fn removed_packages_carry_refresh_only_for_unedited_copies() {
    let world = world();
    let env = install_global(&world);
    let declaration = "[agents.review]\nsource = \"cat\"\nharnesses = [\"claude\"]\n";
    for (scope, manifest, installed, global) in [
        (
            "project",
            world.project.join("kendex.toml"),
            world.project.join(".claude/agents/review.md"),
            false,
        ),
        (
            "global",
            env.global_manifest_file(),
            world.home.join(".claude/agents/review.md"),
            true,
        ),
    ] {
        let before = fs::read_to_string(&manifest).unwrap();
        assert_eq!(before.matches(declaration).count(), 1);
        write(&manifest, &before.replace(declaration, ""));
        let original = fs::read_to_string(&installed).unwrap();
        for (edited, expected) in [(false, Some(Remedy::Refresh { global })), (true, None)] {
            if edited {
                write(&installed, &format!("{original}\nPersonal edit.\n"));
            }
            let (output, document) = verify_scope(&world, scope, None);
            assert!(!output.status.success(), "{}", said(&output));
            let removed = row(&document, "agent", "review", Some(HarnessId::Claude)).unwrap();
            assert_eq!(removed.state, State::Failed, "{scope}: edited={edited}");
            assert_eq!(removed.remedy, expected, "{scope}: edited={edited}");
        }
    }
}

/// A base whose record this build cannot read sets no floor it could
/// trust, so every held commit is refused rather than left unbounded: a
/// record a newer kendex wrote, or one committed with conflict markers,
/// would otherwise let a rolled-back record through.
#[test]
#[allow(clippy::unwrap_used)]
fn at_record_refuses_every_held_commit_under_an_unreadable_base_record() {
    let world = world();
    let record = world.project.join(RECORD);
    let text = fs::read_to_string(&record).unwrap();
    write(&record, "<<<<<<< ours\n{}\n>>>>>>> theirs\n");
    commit(&world.project, "a record no build reads");
    git(&world.project, &["tag", "unreadable"]);
    write(&record, &text);
    commit(&world.project, "the record restored");

    let (output, document) = at_record(&world, Some("unreadable"));
    assert!(!output.status.success(), "{}", said(&output));
    let detail = record_detail(&document);
    assert!(
        detail.contains("skill second: held at")
            && detail.contains("the base revision's record cannot be read"),
        "{detail}"
    );
}

/// A declaration with a revision of its own is read at it and never held,
/// so its commit answers to that revision alone: an agent pinned to a
/// side branch stays clean after the source moves on. The fixture's set
/// carries a member the manifest also declares, so a revision on the set
/// alone asks for that member at two revisions under either reading and
/// is no case of this surface's.
#[test]
#[allow(clippy::unwrap_used)]
fn at_record_leaves_a_declared_revision_to_itself() {
    let world = world();
    git(&world.catalog, &["checkout", "-q", "-b", "side"]);
    write(&world.catalog.join("NOTES.md"), "A side note.\n");
    commit(&world.catalog, "a side branch");
    let side = head(&world.catalog);
    git(&world.catalog, &["checkout", "-q", "main"]);
    let manifest = world.project.join("kendex.toml");
    let text = fs::read_to_string(&manifest).unwrap();
    let pinned = text.replace(
        "[agents.review]\nsource = \"cat\"\n",
        &format!("[agents.review]\nsource = \"cat\"\nrev = \"{side}\"\n"),
    );
    assert_ne!(pinned, text, "the manifest took the pin");
    write(&manifest, &pinned);
    for args in [&["source", "refresh"][..], &["apply", "-y", "--leave"]] {
        let output = kendex(&world.home, &world.project, args);
        assert!(
            output.status.success(),
            "kendex {args:?}: {}",
            said(&output)
        );
    }
    commit(&world.project, "pinned");
    append(
        &world,
        "skills/second/SKILL.md",
        "\nA paragraph added later.\n",
    );
    commit(&world.catalog, "the catalog moves on");
    let fetched = kendex(&world.home, &world.project, &["source", "refresh"]);
    assert!(fetched.status.success(), "{}", said(&fetched));

    let (output, document) = at_record(&world, None);
    assert!(output.status.success(), "{}", said(&output));
    assert_eq!(record_detail(&document), "", "{document:?}");
}

/// A record whose source entry was edited by hand to another repository
/// or revision speaks for a declaration the manifest does not make, and
/// the record row fails under `--at-record`.
#[test]
#[allow(clippy::unwrap_used)]
fn at_record_holds_the_records_source_entry_to_the_manifest() {
    let world = world();
    let rows: [(&str, RecordEdit); 2] = [
        (
            "another repository",
            Box::new(|lock| lock["sources"]["cat"]["repo"] = "other/repo".into()),
        ),
        (
            "another revision",
            Box::new(|lock| {
                let entry = lock["sources"]["cat"].clone();
                lock["sources"]["cat"] = serde_json::json!({
                    "repo": entry["repo"],
                    "rev": "v1",
                    "commit": entry["commit"],
                });
            }),
        ),
    ];
    for (label, edit) in rows {
        git(&world.project, &["checkout", "-q", "--", RECORD]);
        edit_json(&world.project.join(RECORD), edit);
        let (output, document) = at_record(&world, None);
        assert!(!output.status.success(), "{label}: {}", said(&output));
        let record = row(&document, "record", RECORD, None).unwrap();
        assert_eq!(record.state, State::Failed, "{label}: {record:?}");
    }
}

/// A `[sources]` revision edit no write has applied yet leaves every
/// follower held at its recorded commit, and `--at-record` reads the
/// source at the revision declared now: the record row fails, each held
/// commit is listed as stale against the declared revision it differs
/// from, and a revision the mirror cannot serve fails rather than passes.
#[test]
#[allow(clippy::unwrap_used)]
fn at_record_weighs_an_unapplied_revision_edit_at_the_declared_revision() {
    /// The revision a row declares the catalog at.
    enum Declared {
        Moved,
        Installed,
        Unserved,
    }
    for (label, current_first, declares) in [
        ("forward to the moved catalog", false, Declared::Moved),
        ("back to the install commit", true, Declared::Installed),
        (
            "a revision the mirror cannot serve",
            false,
            Declared::Unserved,
        ),
    ] {
        let world = world();
        let installed = head(&world.catalog);
        append(
            &world,
            "skills/second/SKILL.md",
            "\nA paragraph added later.\n",
        );
        commit(&world.catalog, "the catalog moves on");
        let moved = head(&world.catalog);
        let fetched = kendex(&world.home, &world.project, &["source", "refresh"]);
        assert!(fetched.status.success(), "{label}: {}", said(&fetched));
        if current_first {
            let output = kendex(&world.home, &world.project, &["refresh", "-y", "--leave"]);
            assert!(output.status.success(), "{label}: {}", said(&output));
            commit(&world.project, "brought current");
        }
        let held_at = if current_first { &moved } else { &installed };
        let declared = match declares {
            Declared::Moved => moved.as_str(),
            Declared::Installed => installed.as_str(),
            Declared::Unserved => "no-such-branch",
        };
        let manifest = world.project.join("kendex.toml");
        let text = fs::read_to_string(&manifest).unwrap();
        let redeclared = text.replacen(
            "[sources.cat]\n",
            &format!("[sources.cat]\nrev = \"{declared}\"\n"),
            1,
        );
        assert_ne!(redeclared, text, "{label}");
        write(&manifest, &redeclared);
        commit(&world.project, "the catalog pinned, not applied");

        let (output, document) = at_record(&world, None);
        assert!(!output.status.success(), "{label}: {}", said(&output));
        let record = row(&document, "record", RECORD, None).unwrap();
        assert_eq!(record.state, State::Failed, "{label}: {record:?}");
        match declares {
            Declared::Unserved => {}
            Declared::Moved | Declared::Installed => assert!(
                trails(&document).contains(&("cat", held_at.as_str(), declared)),
                "{label}: {document:?}"
            ),
        }
    }
}
