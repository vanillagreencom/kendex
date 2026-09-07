use std::path::Path;

use super::*;
use crate::error::CoreError;

#[test]
fn lock_round_trips_and_missing_file_is_empty() {
    let tmp = tempfile::tempdir().unwrap();
    let path = tmp.path().join(".kendex-lock.json");
    assert_eq!(load(&path).unwrap().entries.len(), 0);

    let mut lock = Lock {
        version: LOCK_VERSION,
        ..Lock::default()
    };
    lock.entries.insert(
        entry_key(ItemKind::Skill, "github", HarnessId::Claude),
        LockEntry {
            registration: None,
            name: "github".into(),
            kind: ItemKind::Skill,
            harness: HarnessId::Claude,
            source: "kendex".into(),
            source_repo: "vanillagreencom/kendex".into(),
            method: Method::Symlink,
            installed_at: crate::clock::timestamp(),
            source_hash: "abc".into(),
            source_commit: None,
            rendered_hash: None,
            enabled: true,
            upstream_skills: None,
            emitted: None,
            reasons: BTreeSet::from([
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
            ]),
        },
    );
    save(&path, &lock).unwrap();
    let loaded = load(&path).unwrap();
    assert_eq!(
        loaded.root,
        Some(crate::paths::canonical(tmp.path()).unwrap()),
        "the write names the project it went down under"
    );
    assert_eq!(
        Lock {
            root: None,
            ..loaded
        },
        lock
    );
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

/// A record whose `emitted.paths` reach outside the project holding it, as
/// written by hand under `key` — the shape a lock copied from another
/// checkout has. `wrote_it` is the project the record names as its own;
/// `None` writes the field out, which is what the global lock holds.
fn recording(path: &Path, key: &str, emitted: &Path, wrote_it: Option<&Path>) {
    std::fs::write(
        path,
        format!(
            r#"{{"version":{LOCK_VERSION},{}"entries":{{"{key}":{{"name":"gh","kind":"skill","harness":"claude","source":"kendex","sourceRepo":"vanillagreencom/kendex","method":"symlink","installedAt":"2026-01-01T00:00:00Z","sourceHash":"abc","enabled":true,"emitted":{{"kind":"skill","name":"gh","paths":[{}]}}}}}}}}"#,
            wrote_it.map_or(String::new(), |root| format!(
                r#""root":{},"#,
                json(root)
            )),
            // A path is data here, not text spliced into the literal: a
            // backslash in it is an escape JSON has to be told about.
            json(emitted)
        ),
    )
    .unwrap();
}

/// What a record's version gets it: read, refused as a record this build
/// cannot read (its `LockCorrupt` message, or the JSON reader's own words
/// where the text is not JSON), or refused as a future kendex's.
enum Gate {
    Loads,
    Corrupt(Option<String>),
    TooNew(i64),
}

/// One row per version a record can name, and the gate's answer, through
/// `load_file` and `load` alike. The version is the whole gate: a record
/// naming this build's number loads whatever else it holds, and one naming
/// any other number — or none — is refused, because every field a later
/// version introduced is a fact this build reads and an older record does
/// not carry. A v1 lock (bare-name keys, a `harnesses` array, no singular
/// `harness`) is a shape this build does not read and nothing converts.
/// Malformed JSON is a damaged lock, distinct from the older and newer
/// cases. A lock a future kendex wrote refuses to load rather than being
/// silently misread or corrupted by an older build; that refusal is what
/// every bump buys, so it is held at exactly one version above this
/// build's — the version the next bump hands to the build before it — and
/// against a record this project could otherwise adopt, leaving the
/// version as the only thing refusing it.
#[test]
fn only_a_record_naming_this_builds_version_loads() {
    let ahead = i64::from(LOCK_VERSION) + 1;
    let older = |version: i64| {
        Gate::Corrupt(Some(format!(
            "it is a version {version} record, and this kendex writes version {LOCK_VERSION}"
        )))
    };
    let rows: [(String, Gate); 8] = [
        (format!(r#"{{"version":{LOCK_VERSION},"root":ROOT,"entries":{{}}}}"#), Gate::Loads),
        (
            r#"{"version":1,"entries":{"gh":{"name":"gh","kind":"skill","source":"kendex","source_repo":"vanillagreencom/kendex","harnesses":["claude-code"],"method":"symlink","installed_at":"2026-01-01T00:00:00Z","source_hash":"abc"}}}"#.to_owned(),
            older(1),
        ),
        (r#"{"version":1,"root":ROOT,"entries":{}}"#.to_owned(), older(1)),
        (r#"{"version":2,"root":ROOT,"entries":{}}"#.to_owned(), older(2)),
        (
            format!(r#"{{"version":{},"root":ROOT,"entries":{{}}}}"#, LOCK_VERSION - 1),
            older(i64::from(LOCK_VERSION - 1)),
        ),
        (
            r#"{"root":ROOT,"entries":{}}"#.to_owned(),
            Gate::Corrupt(Some(
                "it names no version, so nothing here can say what shape it is".to_owned(),
            )),
        ),
        (format!(r#"{{"version":{ahead},"root":ROOT,"entries":{{}}}}"#), Gate::TooNew(ahead)),
        ("{not json".to_owned(), Gate::Corrupt(None)),
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
                            assert_eq!(at, &path, "{label}");
                            if let Some(why) = &why {
                                assert_eq!(message, why, "{label}");
                            }
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

/// One row per root a travelled record can name as its own, every one
/// resolving onto the project reading it: the remainder of each position
/// lands under the reading root, and the record is that project's from
/// here on. Containment cannot answer whose record this is: a checkout
/// nested below this root sits inside it, so every path a lock carried
/// out of that checkout names passes the boundary and the nested tree is
/// what a refresh would then take back; the record says which root wrote
/// it, so each position is read as a remainder of that root. A writing
/// root that is no path on this machine — a clone at another path, a tree
/// copied off another box, a main checkout since moved — resolves the
/// same way, since resolution turns on the record naming the root it
/// went down under, never on that root still being reachable, and a read
/// that required it would refuse exactly the copies this exists for. The
/// project's own root loads as itself. And one directory reached through
/// two spellings is still two prefixes: a record written under `via`, a
/// link to `real`, spells every position under `via`, and read at `real`
/// a comparison that resolved the two roots to one directory would skip
/// the strip and leave every position outside the root reading; what
/// settles it is the spelling, because the spelling is what comes off the
/// front of each position.
#[test]
fn a_travelled_record_resolves_onto_the_root_reading_it() {
    /// The reading root and the root the record names as its own.
    type Plant = fn(&Path) -> (PathBuf, PathBuf);
    #[cfg_attr(not(unix), allow(unused_mut))]
    let mut rows: Vec<(&str, Plant)> = vec![
        ("a checkout nested below this root", |tmp| {
            let root = tmp.join("here");
            let nested = root.join("vendor/thing");
            std::fs::create_dir_all(&nested).unwrap();
            (root, nested)
        }),
        ("a root that is no path on this machine", |tmp| {
            let root = tmp.join("here");
            std::fs::create_dir_all(&root).unwrap();
            let gone = tmp.join("was/here");
            assert!(!gone.exists(), "the writing root is not on this machine");
            (root, gone)
        }),
        ("its own root", |tmp| {
            let root = tmp.join("here");
            std::fs::create_dir_all(&root).unwrap();
            (root.clone(), root)
        }),
    ];
    #[cfg(unix)]
    rows.push(("a link to the root reading", |tmp| {
        let real = tmp.join("real");
        std::fs::create_dir(&real).unwrap();
        let via = tmp.join("via");
        std::os::unix::fs::symlink(&real, &via).unwrap();
        assert_eq!(
            crate::paths::canonical(&via).unwrap(),
            crate::paths::canonical(&real).unwrap(),
            "the two spellings are one directory, which is what makes this the case"
        );
        (real, via)
    }));
    for (label, plant) in rows {
        let tmp = tempfile::tempdir().unwrap();
        let (root, wrote_it) = plant(tmp.path());
        let path = root.join(LOCK_FILE);
        recording(
            &path,
            "skill:gh:claude",
            &wrote_it.join(".agents/skills/gh"),
            Some(&wrote_it),
        );

        let lock = load(&path).unwrap();
        let here = crate::paths::canonical(&root).unwrap();
        assert_eq!(
            lock.entries["skill:gh:claude"]
                .emitted
                .as_ref()
                .unwrap()
                .paths,
            vec![here.join(".agents/skills/gh")],
            "{label}: the remainder lands under the root reading"
        );
        assert_eq!(
            lock.root,
            Some(here),
            "{label}: the record is this project's from here on"
        );
    }
}

/// Why a project record is refused at the read.
enum Refused {
    /// A position outside the root that wrote the record: the key, the
    /// position, and the root the record names.
    Outside(&'static str, PathBuf, PathBuf),
    /// No root named at all.
    WithoutProject,
}

/// One row per record a project refuses to read as its own. A position
/// stating no remainder of the root the record went down under is refused,
/// not left to the containment check: it never was a position that project
/// wrote, and under the root reading it there is a whole tree of places it
/// could land inside and still not be this scope's — a position inside the
/// reading project but outside the writing one, and the writing root
/// itself, which states no remainder at all and rejoined would name the
/// reading project's whole directory as a place this scope owns. A project
/// lock may claim only what sits under its own root: the paths a refresh
/// reads back are the ones it takes off disk, and past the root those
/// belong to another project. A record naming no project is refused rather
/// than adopted: nothing knows who wrote it, and reading it as this
/// project's is the guess the refusal exists to stop.
#[test]
fn a_record_a_project_cannot_call_its_own_is_refused() {
    /// The position recorded, the root the record names, and the refusal.
    type Plant = fn(&Path) -> (PathBuf, Option<PathBuf>, Refused);
    let rows: [(&str, Plant); 4] = [
        ("a position inside the reader, outside the writer", |tmp| {
            let root = tmp.join("here");
            let wrote_it = tmp.join("there");
            std::fs::create_dir_all(&wrote_it).unwrap();
            let inside = root.join("vendor/somebody-elses/link");
            (
                inside.clone(),
                Some(wrote_it.clone()),
                Refused::Outside("skill:gh:claude", inside, wrote_it),
            )
        }),
        ("the writing root itself", |tmp| {
            let wrote_it = tmp.join("there");
            std::fs::create_dir_all(&wrote_it).unwrap();
            (
                wrote_it.clone(),
                Some(wrote_it.clone()),
                Refused::Outside("skill:gh:claude", wrote_it.clone(), wrote_it),
            )
        }),
        ("a position under another tree", |tmp| {
            let root = tmp.join("here");
            let elsewhere = tmp.join("there/.agents/skills/gh");
            (
                elsewhere.clone(),
                Some(root.clone()),
                Refused::Outside(
                    "skill:gh:claude",
                    elsewhere,
                    crate::paths::canonical(&root).unwrap(),
                ),
            )
        }),
        ("no project named", |tmp| {
            (
                tmp.join("here/.agents/skills/gh"),
                None,
                Refused::WithoutProject,
            )
        }),
    ];
    for (label, plant) in rows {
        let tmp = tempfile::tempdir().unwrap();
        let root = tmp.path().join("here");
        std::fs::create_dir_all(&root).unwrap();
        let path = root.join(LOCK_FILE);
        let (emitted, wrote_it, refused) = plant(tmp.path());
        recording(&path, "skill:gh:claude", &emitted, wrote_it.as_deref());

        let got = load(&path).unwrap_err();
        match refused {
            Refused::Outside(key, recorded, named) => assert!(
                matches!(
                    &got,
                    CoreError::LockOutsideProject { key: k, recorded: r, root: n, .. }
                        if k == key && r == &recorded && n == &named
                ),
                "{label}: {got:?}"
            ),
            Refused::WithoutProject => assert!(
                matches!(&got, CoreError::LockWithoutProject { path: at } if at == &path),
                "{label}: {got:?}"
            ),
        }
    }
}

/// Provenance is resolved wherever the record keeps it, not only on the
/// entries: a source's last resolution and an installed set's both record
/// the directory a path source read from, and read from another checkout
/// each names the other one.
#[test]
fn a_travelled_record_resolves_the_provenance_it_keeps_beside_the_entries() {
    let tmp = tempfile::tempdir().unwrap();
    let root = tmp.path().join("here");
    std::fs::create_dir_all(&root).unwrap();
    let wrote_it = tmp.path().join("wrote/here");
    let path = root.join(LOCK_FILE);
    let catalog = |under: &Path| crate::paths::slashed(&under.join("catalog"));
    std::fs::write(
        &path,
        format!(
            r#"{{"version":{LOCK_VERSION},"root":{},"entries":{{"skill:gh:claude":{{"name":"gh","kind":"skill","harness":"claude","source":"cat","sourceRepo":{},"method":"symlink","installedAt":"2026-01-01T00:00:00Z","sourceHash":"abc","enabled":true,"emitted":{{"kind":"skill","name":"gh","paths":[{}]}}}}}},"sources":{{"cat":{{"repo":{},"commit":"abc123"}}}},"bundles":{{"set":{{"source":"cat","sourceRepo":{},"commit":"abc123"}}}}}}"#,
            json(&wrote_it),
            serde_json::to_string(&catalog(&wrote_it)).unwrap(),
            json(&wrote_it.join(".agents/skills/gh")),
            serde_json::to_string(&catalog(&wrote_it)).unwrap(),
            serde_json::to_string(&catalog(&wrote_it)).unwrap(),
        ),
    )
    .unwrap();

    let lock = load(&path).unwrap();
    let here = catalog(&crate::paths::canonical(&root).unwrap());
    assert_eq!(
        lock.entries["skill:gh:claude"].source_repo, here,
        "the entry's provenance"
    );
    assert_eq!(
        lock.sources["cat"].repo, here,
        "the source's last resolution"
    );
    assert_eq!(
        lock.bundles["set"].source_repo, here,
        "the set's, which is recorded apart from the source's"
    );
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

    let lock = Lock {
        version: LOCK_VERSION,
        ..Lock::default()
    };
    save(&via.join(LOCK_FILE), &lock).unwrap();

    assert_eq!(
        load(&via.join(LOCK_FILE)).unwrap().root,
        Some(crate::paths::canonical(&real).unwrap()),
        "the write records the directory, not the way in"
    );
    load(&real.join(LOCK_FILE)).expect("its own root, spelled directly");
    load(&via.join(LOCK_FILE)).expect("its own root, spelled through the link");
}

/// The write end of the ownership rule: what a project lock cannot hand out
/// it cannot be made to hold.
#[test]
fn a_project_lock_is_never_written_naming_another_project() {
    let tmp = tempfile::tempdir().unwrap();
    let root = tmp.path().join("here");
    let nested = root.join("vendor/thing");
    std::fs::create_dir_all(&nested).unwrap();
    let path = root.join(LOCK_FILE);

    let lock = Lock {
        version: LOCK_VERSION,
        root: Some(nested.clone()),
        ..Lock::default()
    };

    let refused = save(&path, &lock).unwrap_err();
    assert!(
        matches!(
            &refused,
            CoreError::LockFromAnotherProject { path: at, recorded, root: named }
                if at == &path && recorded == &nested && named == &crate::paths::canonical(&root).unwrap()
        ),
        "{refused:?}"
    );
    assert!(!path.exists(), "and nothing is left at the path");
}

/// The record is refused at the writing end too: what a project lock cannot
/// hand out it cannot be made to hold.
#[test]
fn a_project_lock_is_never_written_claiming_another_tree() {
    let tmp = tempfile::tempdir().unwrap();
    let root = tmp.path().join("here");
    std::fs::create_dir(&root).unwrap();
    let path = root.join(LOCK_FILE);
    let elsewhere = tmp.path().join("there/.agents/skills/gh");

    let mut lock = Lock {
        version: LOCK_VERSION,
        ..Lock::default()
    };
    lock.entries.insert(
        entry_key(ItemKind::Skill, "gh", HarnessId::Claude),
        LockEntry {
            registration: None,
            name: "gh".into(),
            kind: ItemKind::Skill,
            harness: HarnessId::Claude,
            source: "kendex".into(),
            source_repo: "vanillagreencom/kendex".into(),
            method: Method::Symlink,
            installed_at: crate::clock::timestamp(),
            source_hash: "abc".into(),
            source_commit: None,
            rendered_hash: None,
            enabled: true,
            upstream_skills: None,
            emitted: Some(EmittedArtifact {
                kind: ItemKind::Skill,
                name: "gh".into(),
                paths: vec![elsewhere.clone()],
            }),
            reasons: BTreeSet::from([Reason::Requested]),
        },
    );

    let refused = save(&path, &lock).unwrap_err();
    assert!(
        matches!(
            &refused,
            CoreError::LockOutsideProject { key, recorded, root: named, .. }
                if key == "skill:gh:claude" && recorded == &elsewhere && named == &crate::paths::canonical(&root).unwrap()
        ),
        "{refused:?}"
    );
    assert!(!path.exists(), "and nothing is left at the path");
}

/// A lock named relatively is the current directory's, and that directory
/// is a place — never the bare `.` a spelling makes of it, and never the
/// empty prefix `Path::parent` gives back, which every path starts with and
/// which containment would wave anything through.
///
/// Both halves of the read hold to it. A record written under the
/// directory being read has its claims judged against that directory, and
/// one written elsewhere rebases onto it — resolved, so nothing this hands
/// out is a string read against whatever the process's directory happens to
/// be later.
#[test]
fn a_relatively_named_project_lock_reads_as_the_directory_it_names() {
    let tmp = tempfile::tempdir().unwrap();
    let path = tmp.path().join(LOCK_FILE);
    let here = crate::paths::canonical(Path::new(".")).unwrap();
    let elsewhere = tmp.path().join("there/.agents/skills/gh");

    // Written under the directory being read, so nothing rebases and the
    // claim is judged where it stands.
    recording(&path, "skill:gh:claude", &elsewhere, Some(&here));
    let text = std::fs::read_to_string(&path).unwrap();
    assert!(matches!(
        parse_text(Path::new(LOCK_FILE), &text),
        Err(CoreError::LockOutsideProject { .. })
    ));

    // Written under another root, so it rebases — onto the directory the
    // relative name resolves to, not onto the name.
    recording(&path, "skill:gh:claude", &elsewhere, Some(tmp.path()));
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
        vec![here.join("there/.agents/skills/gh")],
        "the position resolves to a place, not to a name read again later"
    );
    assert_eq!(lock.root, Some(here));
}

/// The global lock has no single root — each harness owns a directory of
/// its own, and none of them is under the app directory the lock sits in.
#[test]
fn the_global_lock_records_paths_outside_its_own_directory() {
    let tmp = tempfile::tempdir().unwrap();
    let app = tmp.path().join("config/kendex");
    std::fs::create_dir_all(&app).unwrap();
    let path = app.join("lock.json");
    // A harness directory, which is nowhere near the app's own.
    let elsewhere = tmp.path().join("home/.claude/skills/gh");
    recording(&path, "skill:gh:claude", &elsewhere, None);
    assert_eq!(load(&path).unwrap().entries.len(), 1);
}
