use std::path::Path;

use super::*;
use crate::error::CoreError;

fn entry(emitted: Option<EmittedArtifact>) -> LockEntry {
    LockEntry {
        registration: None,
        name: "gh".into(),
        kind: ItemKind::Skill,
        harness: HarnessId::Claude,
        source: "kendex".into(),
        source_repo: "vanillagreencom/kendex".into(),
        machine: Some(MachineRecord {
            method: Method::Symlink,
            installed_at: crate::clock::timestamp(),
        }),
        source_hash: "abc".into(),
        source_commit: None,
        rendered_hash: None,
        enabled: true,
        upstream_skills: None,
        emitted,
        reasons: BTreeSet::from([Reason::Requested]),
    }
}

fn skill_at(paths: Vec<PathBuf>) -> Option<EmittedArtifact> {
    Some(EmittedArtifact {
        kind: ItemKind::Skill,
        name: "gh".into(),
        paths,
    })
}

#[test]
fn lock_round_trips_and_missing_file_is_empty() {
    let tmp = tempfile::tempdir().unwrap();
    let path = tmp.path().join(".kendex-lock.json");
    assert_eq!(load(&path).unwrap().entries.len(), 0);

    let mut lock = Lock {
        version: LOCK_VERSION,
        ..Lock::default()
    };
    let mut github = entry(None);
    github.name = "github".into();
    github.reasons = BTreeSet::from([
        Reason::Requested,
        Reason::RequiredBy {
            by: InstallRef {
                source: "kendex".into(),
                kind: ItemKind::Skill,
                name: "dev".into(),
                harness: HarnessId::Claude,
            },
        },
        Reason::MemberOf {
            bundle: BundleRef {
                source: "kendex".into(),
                name: "starter".into(),
            },
        },
    ]);
    lock.entries.insert(
        entry_key(ItemKind::Skill, "github", HarnessId::Claude),
        github,
    );
    save(&path, &lock).unwrap();
    assert_eq!(load(&path).unwrap(), lock);
    assert!(std::fs::read_to_string(&path).unwrap().ends_with('\n'));
}

#[test]
fn timestamps_are_iso8601() {
    let ts = crate::clock::timestamp();
    assert_eq!(ts.len(), 20);
    assert!(ts.ends_with('Z'));
    assert!(ts.starts_with("20"));
}

/// A path as JSON data rather than text spliced into a literal: a
/// backslash in one is an escape JSON has to be told about.
fn json(path: &Path) -> String {
    serde_json::to_string(&path.display().to_string()).unwrap()
}

/// A record naming one position under `key`, written by hand the way the
/// committed file spells it: `emitted` is data, so whatever it states is
/// what the read judges.
fn recording(path: &Path, key: &str, emitted: &Path) {
    std::fs::write(
        path,
        format!(
            r#"{{"version":{LOCK_VERSION},"entries":{{"{key}":{{"name":"gh","kind":"skill","harness":"claude","source":"kendex","sourceRepo":"vanillagreencom/kendex","sourceHash":"abc","enabled":true,"emitted":{{"kind":"skill","name":"gh","paths":[{}]}}}}}}}}"#,
            json(emitted)
        ),
    )
    .unwrap();
}

/// What a record's version gets it: read, refused as a record this build
/// cannot read (its `LockCorrupt` message, or the JSON reader's own words
/// passed through whole where the text is not JSON), or refused as a
/// future kendex's.
enum Gate {
    Loads,
    Corrupt(String),
    TooNew(i64),
}

/// One row per version a record can name, and the gate's answer, through
/// `load_file` and `load` alike. The version is the whole gate: a record
/// naming this build's number loads whatever else it holds, and one naming
/// any other number — or none — is refused, because every field a later
/// version introduced is a fact this build reads and an older record does
/// not carry. A v1 lock (bare-name keys, a `harnesses` array, no singular
/// `harness`) is a shape this build does not read and nothing converts,
/// and neither is the version before this one, which spells every
/// position as a path on the machine that wrote it. Malformed JSON is a
/// damaged lock, distinct from the older and newer cases. A lock a future
/// kendex wrote refuses to load rather than being silently misread or
/// corrupted by an older build; that refusal is what every bump buys, so
/// it is held at exactly one version above this build's — the version the
/// next bump hands to the build before it — and against a record this
/// project could otherwise adopt, leaving the version as the only thing
/// refusing it.
#[test]
fn only_a_record_naming_this_builds_version_loads() {
    let ahead = i64::from(LOCK_VERSION) + 1;
    let older = |version: i64| {
        Gate::Corrupt(format!(
            "it is a version {version} record, and this kendex writes version {LOCK_VERSION}"
        ))
    };
    let readers_words = serde_json::from_str::<serde_json::Value>("{not json")
        .unwrap_err()
        .to_string();
    let rows: [(String, Gate); 8] = [
        (format!(r#"{{"version":{LOCK_VERSION},"entries":{{}}}}"#), Gate::Loads),
        (
            r#"{"version":1,"entries":{"gh":{"name":"gh","kind":"skill","source":"kendex","source_repo":"vanillagreencom/kendex","harnesses":["claude-code"],"method":"symlink","installed_at":"2026-01-01T00:00:00Z","source_hash":"abc"}}}"#.to_owned(),
            older(1),
        ),
        (r#"{"version":1,"entries":{}}"#.to_owned(), older(1)),
        (r#"{"version":2,"entries":{}}"#.to_owned(), older(2)),
        (
            format!(r#"{{"version":{},"root":ROOT,"entries":{{}}}}"#, LOCK_VERSION - 1),
            older(i64::from(LOCK_VERSION - 1)),
        ),
        (
            r#"{"entries":{}}"#.to_owned(),
            Gate::Corrupt(
                "it names no version, so nothing here can say what shape it is".to_owned(),
            ),
        ),
        (format!(r#"{{"version":{ahead},"entries":{{}}}}"#), Gate::TooNew(ahead)),
        ("{not json".to_owned(), Gate::Corrupt(readers_words)),
    ];
    for (record, gate) in rows {
        let tmp = tempfile::tempdir().unwrap();
        let path = tmp.path().join(".kendex-lock.json");
        std::fs::write(&path, record.replace("ROOT", &json(tmp.path()))).unwrap();
        let label = record.as_str();
        match gate {
            Gate::Loads => {
                assert!(
                    matches!(load_file(&path).unwrap(), LockFile::Current(_)),
                    "{label}"
                );
            }
            Gate::Corrupt(why) => {
                for refused in [load_file(&path).unwrap_err(), load(&path).unwrap_err()] {
                    match &refused {
                        CoreError::LockCorrupt { path: at, message } => {
                            assert_eq!((at, message), (&path, &why), "{label}");
                        }
                        other => panic!("{label}: expected a corrupt lock, got {other:?}"),
                    }
                }
            }
            Gate::TooNew(found) => {
                for refused in [load_file(&path).unwrap_err(), load(&path).unwrap_err()] {
                    assert!(
                        matches!(&refused, CoreError::SchemaTooNew { path: at, found: seen } if at == &path && *seen == found),
                        "{label}: {refused:?}"
                    );
                }
            }
        }
    }
}

/// What the corrupt-lock refusal must keep saying, and what it must not.
/// It asks for a fresh install. It names the pi files beside a scope
/// root, because this record is the only thing naming them and nothing
/// in this build looks there — a person who threw the lock away alone
/// would be left with the hook registered twice. And it asks for them to
/// be moved, never deleted: this refusal covers a damaged current lock as
/// much as an older one, and an older one may record that the move out
/// of the reserved name already finished, after which those files are the
/// person's own; nothing here can tell the two apart, so nothing here
/// tells anyone to delete anything. The same refusal reaches Personal and
/// a project alike, and the two scopes keep their locks under different
/// names (`lock.json` under the app's config directory, `.kendex-lock.json`
/// in a project), so the message names the path it was handed and nothing
/// else, a rule that stays true for both; the app's steps for this kind
/// carry the same rule beside their own copy, in
/// ui/src/lib/error-copy.test.ts.
#[test]
fn the_corrupt_lock_refusal_asks_for_a_move_and_names_no_path_of_its_own() {
    let tmp = tempfile::tempdir().unwrap();
    let path = tmp.path().join("lock.json");
    std::fs::write(&path, "{not json").unwrap();
    let said = load_file(&path).unwrap_err().to_string();
    assert!(said.contains("install fresh"), "{said}");
    assert!(said.contains("hooks.json"), "{said}");
    assert!(
        !said.contains("delet"),
        "no remedy of ours is destructive: {said}"
    );
    for named in [".kendex-lock.json", "kendex.toml", ".pi"] {
        assert!(!said.contains(named), "names {named}: {said}");
    }
}

/// The committed record names nothing about the checkout that wrote it.
/// Every position is the part of it under the root, slashed; a provenance
/// is written as it came, since a path source's is its declaration and
/// never a directory here (`crate::source::declared_path_identity`); the
/// root goes unwritten; and what only this machine knows — the delivery
/// and the time — is in this machine's half under the project's cache,
/// with the root it was written under. Read back here the two halves are
/// one record again, with every path absolute under this root.
#[test]
fn a_committed_record_spells_what_sits_under_the_root_as_remainders() {
    let tmp = tempfile::tempdir().unwrap();
    let root = crate::paths::canonical(tmp.path()).unwrap();
    let path = root.join(LOCK_FILE);
    let mut lock = Lock {
        version: LOCK_VERSION,
        ..Lock::default()
    };
    let mut from_the_project = entry(skill_at(vec![
        root.join(".agents/skills/gh"),
        root.join(".claude/skills/gh"),
    ]));
    from_the_project.source_repo = "../catalog".to_owned();
    lock.entries
        .insert("skill:gh:claude".to_owned(), from_the_project);
    lock.sources.insert(
        "self".to_owned(),
        SourceRev {
            repo: ".".to_owned(),
            rev: None,
            commit: "abc123".to_owned(),
        },
    );
    lock.bundles.insert(
        "set".to_owned(),
        BundleRev {
            source: "self".to_owned(),
            source_repo: ".".to_owned(),
            commit: "abc123".to_owned(),
        },
    );
    save(&path, &lock).unwrap();

    let committed: serde_json::Value =
        serde_json::from_str(&std::fs::read_to_string(&path).unwrap()).unwrap();
    let recorded = &committed["entries"]["skill:gh:claude"];
    assert_eq!(
        recorded["emitted"]["paths"],
        serde_json::json!([".agents/skills/gh", ".claude/skills/gh"])
    );
    assert_eq!(recorded["sourceRepo"], "../catalog");
    assert_eq!(committed["sources"]["self"]["repo"], ".");
    assert_eq!(committed["bundles"]["set"]["sourceRepo"], ".");
    for absent in ["method", "installedAt"] {
        assert!(recorded.get(absent).is_none(), "{absent} is this machine's");
    }
    assert!(committed.get("root").is_none(), "the root is the reader's");
    assert!(
        !std::fs::read_to_string(&path)
            .unwrap()
            .contains(&crate::paths::slashed(&root)),
        "nothing in the committed record spells this checkout"
    );

    let machine = machine_path(&path);
    assert_eq!(machine, root.join(".cache/kendex").join(MACHINE_FILE));
    let held: serde_json::Value =
        serde_json::from_str(&std::fs::read_to_string(&machine).unwrap()).unwrap();
    assert_eq!(held["version"], LOCK_VERSION);
    assert_eq!(held["written"].as_array().map(Vec::len), Some(1));
    assert_eq!(
        held["written"][0]["root"],
        crate::paths::slashed(&root).replace('/', std::path::MAIN_SEPARATOR_STR)
    );
    assert_eq!(
        held["written"][0]["entries"]["skill:gh:claude"]["method"],
        "symlink"
    );

    assert_eq!(load(&path).unwrap(), lock, "the two halves read as one");
    assert_eq!(stated_roots(&path).unwrap(), vec![root]);
}

/// One row per root a committed record can be read from, every one
/// reading it as its own: the remainder of each position lands under the
/// root reading, and every provenance reads as the record spells it, the
/// declaration being the same in every clone.
/// A nested checkout sits inside the project holding it, and a
/// containment check alone would take its positions for the parent's;
/// read as remainders they are the parent's own positions, and the nested
/// tree is never named. A clone at another path, a tree copied off
/// another box and a main checkout since moved all read the same way,
/// since nothing in the record names where it was written. And one
/// directory reached through two spellings is one root: the read
/// resolves the path it was handed once and joins onto that.
#[test]
fn a_committed_record_reads_as_the_project_reading_it() {
    /// The reading root, made.
    type Plant = fn(&Path) -> PathBuf;
    #[cfg_attr(not(unix), allow(unused_mut))]
    let mut rows: Vec<(&str, Plant)> = vec![
        ("a checkout nested below another project", |tmp| {
            let nested = tmp.join("here/vendor/thing");
            std::fs::create_dir_all(&nested).unwrap();
            nested
        }),
        ("a clone at a path nothing wrote it under", |tmp| {
            let root = tmp.join("elsewhere/clone");
            std::fs::create_dir_all(&root).unwrap();
            root
        }),
    ];
    #[cfg(unix)]
    rows.push(("a link to the root reading", |tmp| {
        let real = tmp.join("real");
        std::fs::create_dir(&real).unwrap();
        let via = tmp.join("via");
        std::os::unix::fs::symlink(&real, &via).unwrap();
        via
    }));
    for (label, plant) in rows {
        let tmp = tempfile::tempdir().unwrap();
        let root = plant(tmp.path());
        let path = root.join(LOCK_FILE);
        std::fs::write(
            &path,
            format!(
                r#"{{"version":{LOCK_VERSION},"entries":{{"skill:gh:claude":{{"name":"gh","kind":"skill","harness":"claude","source":"cat","sourceRepo":"../catalog","sourceHash":"abc","enabled":true,"emitted":{{"kind":"skill","name":"gh","paths":[".agents/skills/gh"]}}}}}},"sources":{{"cat":{{"repo":".","commit":"abc123"}}}},"bundles":{{"set":{{"source":"cat","sourceRepo":"../catalog","commit":"abc123"}}}}}}"#
            ),
        )
        .unwrap();

        let lock = load(&path).unwrap();
        let here = crate::paths::canonical(&root).unwrap();
        let entry = &lock.entries["skill:gh:claude"];
        assert_eq!(
            entry.emitted.as_ref().unwrap().paths,
            vec![here.join(".agents/skills/gh")],
            "{label}: the remainder lands under the root reading"
        );
        assert_eq!(
            entry.source_repo, "../catalog",
            "{label}: the entry's provenance is the declaration, not a directory here"
        );
        assert_eq!(
            lock.sources["cat"].repo, ".",
            "{label}: the source's last resolution, at the root itself"
        );
        assert_eq!(
            lock.bundles["set"].source_repo, "../catalog",
            "{label}: the set's, which is recorded apart from the source's"
        );
        assert_eq!(
            entry.machine, None,
            "{label}: this machine holds nothing about an install made elsewhere"
        );
    }
}

/// One row per position a project refuses to read as its own. A committed
/// record states remainders, and a position that is not one is a claim on
/// something outside this project: another tree outright, a walk back out
/// through `..`, a `.` that resolves to a place containment would wave
/// through, and the empty remainder, which rejoined would name the
/// reading project's whole directory as a place this scope owns. The
/// refusal names the position as recorded and the root it was read
/// against.
#[test]
fn a_position_that_is_no_remainder_of_the_project_is_refused() {
    /// The position as the file spells it.
    type Plant = fn(&Path) -> PathBuf;
    let rows: [(&str, Plant); 4] = [
        ("a position under another tree", |tmp| {
            tmp.join("there/.agents/skills/gh")
        }),
        ("a walk back out", |_| {
            PathBuf::from("../there/.agents/skills/gh")
        }),
        ("a position through the current directory", |_| {
            PathBuf::from("./.agents/skills/gh")
        }),
        ("the root itself", |_| PathBuf::new()),
    ];
    for (label, plant) in rows {
        let tmp = tempfile::tempdir().unwrap();
        let root = tmp.path().join("here");
        std::fs::create_dir_all(&root).unwrap();
        let path = root.join(LOCK_FILE);
        let position = plant(tmp.path());
        recording(&path, "skill:gh:claude", &position);

        let got = load(&path).unwrap_err();
        let here = crate::paths::canonical(&root).unwrap();
        assert!(
            matches!(
                &got,
                CoreError::LockOutsideProject { path: at, key, recorded, root: named }
                    if at == &path && key == "skill:gh:claude" && recorded == &position && named == &here
            ),
            "{label}: {got:?}"
        );
    }
}

/// The write end of the same rule: what a project lock cannot hand out it
/// cannot be made to hold. A position outside the root, one walking out
/// through `..` from under it, and the root itself are each refused
/// before anything is written.
#[test]
fn a_project_lock_is_never_written_claiming_another_tree() {
    /// The position the record claims, given the root.
    type Plant = fn(&Path, &Path) -> PathBuf;
    let rows: [(&str, Plant); 3] = [
        ("under another tree", |tmp, _| {
            tmp.join("there/.agents/skills/gh")
        }),
        ("walking back out", |_, root| {
            root.join("../there/.agents/skills/gh")
        }),
        ("the root itself", |_, root| root.to_path_buf()),
    ];
    for (label, plant) in rows {
        let tmp = tempfile::tempdir().unwrap();
        let root = tmp.path().join("here");
        std::fs::create_dir(&root).unwrap();
        let path = root.join(LOCK_FILE);
        let claimed = plant(tmp.path(), &root);
        let mut lock = Lock {
            version: LOCK_VERSION,
            ..Lock::default()
        };
        lock.entries.insert(
            entry_key(ItemKind::Skill, "gh", HarnessId::Claude),
            entry(skill_at(vec![claimed.clone()])),
        );

        let refused = save(&path, &lock).unwrap_err();
        assert!(
            matches!(
                &refused,
                CoreError::LockOutsideProject { path: at, key, recorded, root: named }
                    if at == &path && key == "skill:gh:claude" && recorded == &claimed && named == &crate::paths::canonical(&root).unwrap()
            ),
            "{label}: {refused:?}"
        );
        assert!(!path.exists(), "{label}: and nothing is left at the path");
        assert!(
            !machine_path(&path).exists(),
            "{label}: nor at this machine's half"
        );
    }
}

/// This machine's half is read only against the record it was written
/// beside: a record for an installation the committed lock no longer
/// names is dropped, and with the half gone every entry reads as one this
/// machine holds nothing about — a cleared cache or a fresh clone, which
/// the next apply records afresh.
#[test]
fn this_machines_half_follows_the_committed_record() {
    let tmp = tempfile::tempdir().unwrap();
    let root = crate::paths::canonical(tmp.path()).unwrap();
    let path = root.join(LOCK_FILE);
    let mut lock = Lock {
        version: LOCK_VERSION,
        ..Lock::default()
    };
    lock.entries
        .insert("skill:gh:claude".to_owned(), entry(None));
    save(&path, &lock).unwrap();

    // The committed half rewritten without the entry, as a pull that
    // dropped it would leave things.
    std::fs::write(
        &path,
        format!(r#"{{"version":{LOCK_VERSION},"entries":{{}}}}"#),
    )
    .unwrap();
    assert!(load(&path).unwrap().entries.is_empty());
    assert_eq!(stated_roots(&path).unwrap(), vec![root.clone()]);

    save(&path, &lock).unwrap();
    std::fs::remove_file(machine_path(&path)).unwrap();
    let mut without = lock.clone();
    without.entries.get_mut("skill:gh:claude").unwrap().machine = None;
    assert_eq!(load(&path).unwrap(), without);
    assert_eq!(stated_roots(&path).unwrap(), Vec::<PathBuf>::new());
}

/// Two checkouts whose `.cache` is one directory — a main checkout and a
/// linked worktree under the worktree convention this repository ships —
/// write one machine half. Each keeps its own row: a save from one
/// replaces only that root's delivery and timestamps, each reads back
/// what it wrote, and the file names both roots. The must-fail control
/// for keying the half by root: written whole, the second save replaced
/// the first checkout's timestamps and root with its own.
#[test]
#[cfg(unix)]
fn checkouts_sharing_one_cache_keep_their_own_halves() {
    let tmp = tempfile::tempdir().unwrap();
    let home = crate::paths::canonical(tmp.path()).unwrap();
    let main = home.join("main");
    let linked = home.join("worktrees/ken-1");
    std::fs::create_dir_all(main.join(".cache")).unwrap();
    std::fs::create_dir_all(&linked).unwrap();
    std::os::unix::fs::symlink(main.join(".cache"), linked.join(".cache")).unwrap();

    let mut at_main = Lock {
        version: LOCK_VERSION,
        ..Lock::default()
    };
    at_main.entries.insert(
        "skill:gh:claude".to_owned(),
        entry(skill_at(vec![main.join(".agents/skills/gh")])),
    );
    let mut at_linked = at_main.clone();
    let there = at_linked.entries.get_mut("skill:gh:claude").unwrap();
    there.emitted.as_mut().unwrap().paths = vec![linked.join(".agents/skills/gh")];
    there.machine.as_mut().unwrap().installed_at = "2026-02-02T00:00:00Z".to_owned();
    assert_ne!(
        at_main.entries["skill:gh:claude"].machine, at_linked.entries["skill:gh:claude"].machine,
        "the fixture plants two deliveries to tell apart"
    );

    save(&main.join(LOCK_FILE), &at_main).unwrap();
    save(&linked.join(LOCK_FILE), &at_linked).unwrap();
    assert_eq!(
        std::fs::read_to_string(machine_path(&main.join(LOCK_FILE))).unwrap(),
        std::fs::read_to_string(machine_path(&linked.join(LOCK_FILE))).unwrap(),
        "one file"
    );

    assert_eq!(load(&main.join(LOCK_FILE)).unwrap(), at_main);
    assert_eq!(load(&linked.join(LOCK_FILE)).unwrap(), at_linked);
    for lock in [main.join(LOCK_FILE), linked.join(LOCK_FILE)] {
        assert_eq!(
            stated_roots(&lock).unwrap(),
            vec![main.clone(), linked.clone()],
            "{}",
            lock.display()
        );
    }
}

/// A root has one spelling (invariant 17), and neither end holds it: the
/// record goes down canonical while a caller may name the same directory
/// through a link — which is the spelling macOS hands every temp path,
/// `/var` fronting `/private/var`. Compared as text a root does not equal
/// itself, and every project reached that way loses its own lock.
#[test]
#[cfg(unix)]
fn a_project_lock_read_through_a_linked_spelling_of_its_root_is_still_its_own() {
    let tmp = tempfile::tempdir().unwrap();
    let real = tmp.path().join("real");
    std::fs::create_dir(&real).unwrap();
    let via = tmp.path().join("via");
    std::os::unix::fs::symlink(&real, &via).unwrap();

    // The engine resolves a scope root before writing any position under
    // it (invariant 17), so the record it hands the writer is spelled
    // under `real` whichever way the lock path names the directory.
    let canonical = crate::paths::canonical(&real).unwrap();
    let mut lock = Lock {
        version: LOCK_VERSION,
        ..Lock::default()
    };
    lock.entries.insert(
        entry_key(ItemKind::Skill, "gh", HarnessId::Claude),
        entry(skill_at(vec![canonical.join(".agents/skills/gh")])),
    );
    save(&via.join(LOCK_FILE), &lock).unwrap();

    assert_eq!(
        stated_roots(&via.join(LOCK_FILE)).unwrap(),
        vec![canonical.clone()],
        "the write records the directory, not the way in"
    );
    for spelling in [&real, &via] {
        let read = load(&spelling.join(LOCK_FILE)).expect("its own root, however spelled");
        assert_eq!(
            read.entries["skill:gh:claude"]
                .emitted
                .as_ref()
                .unwrap()
                .paths,
            vec![canonical.join(".agents/skills/gh")],
            "{}: positions rejoin onto the one spelling",
            spelling.display()
        );
    }
}

/// A lock named relatively is the current directory's, and that directory
/// is a place — never the bare `.` a spelling makes of it, and never the
/// empty prefix `Path::parent` gives back, which every path starts with and
/// which containment would wave anything through. A position rejoins onto
/// the resolved directory, so nothing this hands out is a string read
/// against whatever the process's directory happens to be later.
#[test]
fn a_relatively_named_project_lock_reads_as_the_directory_it_names() {
    let tmp = tempfile::tempdir().unwrap();
    let path = tmp.path().join(LOCK_FILE);
    let here = crate::paths::canonical(Path::new(".")).unwrap();
    recording(&path, "skill:gh:claude", Path::new(".agents/skills/gh"));
    let text = std::fs::read_to_string(&path).unwrap();
    let lock = match parse_text(Path::new(LOCK_FILE), &text).unwrap() {
        LockFile::Current(lock) => lock,
        LockFile::Absent => unreachable!("the text is a record"),
    };
    assert_eq!(
        lock.entries["skill:gh:claude"]
            .emitted
            .as_ref()
            .unwrap()
            .paths,
        vec![here.join(".agents/skills/gh")],
        "the position resolves to a place, not to a name read again later"
    );
}

/// The global lock has no single root — each harness owns a directory of
/// its own, and none of them is under the app directory the lock sits in
/// — so its positions are written and read as they are, and this
/// machine's half sits beside it under its own name.
#[test]
fn the_global_lock_records_paths_outside_its_own_directory() {
    let tmp = tempfile::tempdir().unwrap();
    let app = tmp.path().join("config/kendex");
    std::fs::create_dir_all(&app).unwrap();
    let path = app.join("lock.json");
    // A harness directory, which is nowhere near the app's own.
    let elsewhere = tmp.path().join("home/.claude/skills/gh");
    let mut lock = Lock {
        version: LOCK_VERSION,
        ..Lock::default()
    };
    lock.entries.insert(
        entry_key(ItemKind::Skill, "gh", HarnessId::Claude),
        entry(skill_at(vec![elsewhere.clone()])),
    );
    save(&path, &lock).unwrap();
    assert_eq!(machine_path(&path), app.join(MACHINE_FILE));
    assert_eq!(load(&path).unwrap(), lock);
    assert_eq!(
        stated_roots(&path).unwrap(),
        Vec::<PathBuf>::new(),
        "no root to state"
    );
}

/// One row per machine half this build cannot read — not JSON, another
/// build's version either side, no version at all, the empty file an
/// interrupted write leaves — and every one reads as no machine half: the
/// committed record loads with `machine` absent and states no root. A
/// refusal here would stop an install over a cache the install does not
/// need, with a remedy written for the committed record; the next save
/// writes the half whole.
#[test]
fn an_unreadable_machine_half_reads_as_absent() {
    for (label, text) in [
        ("not json", "{not json".to_owned()),
        (
            "a version behind",
            format!(r#"{{"version":{},"entries":{{}}}}"#, LOCK_VERSION - 1),
        ),
        (
            "a version ahead",
            format!(r#"{{"version":{},"entries":{{}}}}"#, LOCK_VERSION + 1),
        ),
        ("no version", r#"{"entries":{}}"#.to_owned()),
        ("an empty file", String::new()),
    ] {
        let tmp = tempfile::tempdir().unwrap();
        let root = crate::paths::canonical(tmp.path()).unwrap();
        let path = root.join(LOCK_FILE);
        recording(&path, "skill:gh:claude", Path::new(".agents/skills/gh"));
        let machine = machine_path(&path);
        std::fs::create_dir_all(machine.parent().unwrap()).unwrap();
        std::fs::write(&machine, &text).unwrap();

        let lock = load(&path).unwrap_or_else(|error| panic!("{label}: {error}"));
        assert_eq!(lock.entries["skill:gh:claude"].machine, None, "{label}");
        assert_eq!(
            stated_roots(&path).unwrap(),
            Vec::<PathBuf>::new(),
            "{label}"
        );
    }
}
