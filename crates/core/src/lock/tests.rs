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

/// A v1 lock (bare-name keys, a `harnesses` array, no singular
/// `harness`) is a shape this build does not read. Nothing converts it:
/// the load fails, and the message names the path out — move it aside and
/// install fresh.
#[test]
fn a_v1_lock_fails_to_load_and_names_the_fresh_install() {
    let tmp = tempfile::tempdir().unwrap();
    let path = tmp.path().join(".kendex-lock.json");
    std::fs::write(
        &path,
        r#"{"version":1,"entries":{"gh":{"name":"gh","kind":"skill","source":"kendex","source_repo":"vanillagreencom/kendex","harnesses":["claude-code"],"method":"symlink","installed_at":"2026-01-01T00:00:00Z","source_hash":"abc"}}}"#,
    )
    .unwrap();
    let error = load_file(&path).unwrap_err();
    assert!(matches!(error, CoreError::LockCorrupt { .. }), "{error}");
    let said = error.to_string();
    assert!(said.contains("install fresh"), "{said}");
    // Two things this message must keep saying. It names the pi files
    // beside a scope root, because this record is the only thing naming
    // them and nothing in this build looks there — a person who threw the
    // lock away alone would be left with the hook registered twice. And
    // it asks for them to be moved, never deleted: this refusal covers a
    // damaged current lock as much as an older one, and an older one may
    // record that the move out of the reserved name already finished,
    // after which those files are the person's own. Nothing here can tell
    // the two apart, so nothing here tells anyone to delete anything.
    assert!(said.contains("hooks.json"), "{said}");
    assert!(
        !said.contains("delet"),
        "no remedy of ours is destructive: {said}"
    );
    assert!(matches!(load(&path), Err(CoreError::LockCorrupt { .. })));
}

/// The same refusal reaches Personal and a project alike, and the two
/// scopes keep their locks under different names: `lock.json` under the
/// app's config directory, `.kendex-lock.json` in a project. So the
/// message names the path it was handed and nothing else, which is a rule
/// that stays true for both. The app's steps for this kind carry the same
/// rule beside their own copy, in ui/src/lib/error-copy.test.ts.
#[test]
fn the_lock_refusal_names_no_path_of_its_own() {
    let tmp = tempfile::tempdir().unwrap();
    let path = tmp.path().join("lock.json");
    std::fs::write(&path, "{not json").unwrap();
    let said = load_file(&path).unwrap_err().to_string();
    assert!(said.contains("install fresh"), "{said}");
    for named in [".kendex-lock.json", "kendex.toml", ".pi"] {
        assert!(!said.contains(named), "names {named}: {said}");
    }
}

/// Malformed JSON is reported as a damaged lock, distinct from the v1
/// and future-version cases.
#[test]
fn unparseable_json_is_reported_as_corrupt() {
    let tmp = tempfile::tempdir().unwrap();
    let path = tmp.path().join(".kendex-lock.json");
    std::fs::write(&path, "{not json").unwrap();
    assert!(matches!(
        load_file(&path),
        Err(CoreError::LockCorrupt { .. })
    ));
    assert!(matches!(load(&path), Err(CoreError::LockCorrupt { .. })));
}

/// A lock a future kendex wrote refuses to load rather than being
/// silently misread or corrupted by an older build. That refusal is what
/// every bump buys, so it is held at exactly one version above this
/// build's — the version the next bump hands to the build before it — and
/// against a record this project could otherwise adopt, leaving the
/// version as the only thing refusing it.
#[test]
fn a_newer_lock_refuses_to_load() {
    let tmp = tempfile::tempdir().unwrap();
    let path = tmp.path().join(".kendex-lock.json");
    let ahead = i64::from(LOCK_VERSION) + 1;
    std::fs::write(
        &path,
        format!(
            r#"{{"version":{ahead},"root":{},"entries":{{}}}}"#,
            json(tmp.path())
        ),
    )
    .unwrap();
    let refused = load_file(&path).unwrap_err();
    assert!(
        matches!(refused, CoreError::SchemaTooNew { found, .. } if found == ahead),
        "{refused}"
    );
    let refused = load(&path).unwrap_err();
    assert!(
        matches!(refused, CoreError::SchemaTooNew { found, .. } if found == ahead),
        "{refused}"
    );
}

/// The version is the whole gate: a record naming this build's number
/// loads whatever else it holds, and one naming any other number — or
/// none — is refused, because every field a later version added is a fact
/// this build reads and an older record does not carry.
#[test]
fn only_this_builds_version_loads() {
    let tmp = tempfile::tempdir().unwrap();
    let path = tmp.path().join(".kendex-lock.json");
    let write = |version: &str| {
        std::fs::write(
            &path,
            format!(r#"{{{version}"root":{},"entries":{{}}}}"#, json(tmp.path())),
        )
        .unwrap();
    };

    write(&format!(r#""version":{LOCK_VERSION},"#));
    assert!(matches!(load_file(&path).unwrap(), LockFile::Current(_)));

    for older in ["1", "2", &(LOCK_VERSION - 1).to_string()] {
        write(&format!(r#""version":{older},"#));
        let error = load_file(&path).unwrap_err();
        assert!(matches!(error, CoreError::LockCorrupt { .. }), "{error}");
        assert!(error.to_string().contains("install fresh"), "{error}");
    }

    write("");
    let error = load_file(&path).unwrap_err();
    assert!(matches!(error, CoreError::LockCorrupt { .. }), "{error}");
    assert!(error.to_string().contains("names no version"), "{error}");
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

/// Containment cannot answer whose record this is: a checkout nested below
/// this root sits inside it, so every path a lock carried out of that
/// checkout names passes the boundary and the nested tree is what a
/// refresh would then take back. The record says which root wrote it, so
/// each position is read as a remainder of that root and resolves onto the
/// one reading — which is this project's own tree, never the writer's.
#[test]
fn a_project_lock_another_project_wrote_resolves_onto_the_project_reading_it() {
    let tmp = tempfile::tempdir().unwrap();
    let root = tmp.path().join("here");
    let nested = root.join("vendor/thing");
    std::fs::create_dir_all(&nested).unwrap();
    let path = root.join(LOCK_FILE);
    recording(
        &path,
        "skill:gh:claude",
        &nested.join(".agents/skills/gh"),
        Some(&nested),
    );

    let lock = load(&path).unwrap();
    assert_eq!(
        lock.entries["skill:gh:claude"]
            .emitted
            .as_ref()
            .unwrap()
            .paths,
        vec![
            crate::paths::canonical(&root)
                .unwrap()
                .join(".agents/skills/gh")
        ],
        "the remainder lands under the root reading, not the one that wrote it"
    );
    assert_eq!(
        lock.root,
        Some(crate::paths::canonical(&root).unwrap()),
        "and the record is this project's from here on"
    );
}

/// A record whose writing root is no path on this machine — a clone at
/// another path, a tree copied off another box, a main checkout since
/// moved. Resolution turns on the record naming the root it went down
/// under, never on that root still being reachable, and a read that
/// required it would refuse exactly the copies this exists for.
#[test]
fn a_project_lock_a_root_that_is_gone_wrote_still_resolves() {
    let tmp = tempfile::tempdir().unwrap();
    let root = tmp.path().join("here");
    std::fs::create_dir_all(&root).unwrap();
    let gone = tmp.path().join("was/here");
    assert!(!gone.exists(), "the writing root is not on this machine");
    let path = root.join(LOCK_FILE);
    recording(
        &path,
        "skill:gh:claude",
        &gone.join(".agents/skills/gh"),
        Some(&gone),
    );

    let lock = load(&path).unwrap();
    assert_eq!(
        lock.entries["skill:gh:claude"]
            .emitted
            .as_ref()
            .unwrap()
            .paths,
        vec![
            crate::paths::canonical(&root)
                .unwrap()
                .join(".agents/skills/gh")
        ],
        "the remainder lands under the root reading"
    );
    assert_eq!(
        lock.root,
        Some(crate::paths::canonical(&root).unwrap()),
        "and the record is this project's from here on"
    );
}

/// A position stating no remainder of the root the record went down under
/// is refused, not left to the containment check: it never was a position
/// that project wrote, and under the root reading it there is a whole tree
/// of places it could land inside and still not be this scope's.
#[test]
fn a_travelled_record_claiming_a_position_its_own_root_never_held_is_refused() {
    let tmp = tempfile::tempdir().unwrap();
    let root = tmp.path().join("here");
    let wrote_it = tmp.path().join("there");
    std::fs::create_dir_all(&root).unwrap();
    std::fs::create_dir_all(&wrote_it).unwrap();
    let path = root.join(LOCK_FILE);

    // Inside the project reading the record, so containment waves it
    // through, and outside the one that wrote it, so the record never
    // stated it as anywhere of its own.
    let inside = root.join("vendor/somebody-elses/link");
    recording(&path, "skill:gh:claude", &inside, Some(&wrote_it));
    let refused = load(&path).unwrap_err();
    assert!(
        matches!(
            &refused,
            CoreError::LockOutsideProject { key, recorded, root: named, .. }
                if key == "skill:gh:claude" && recorded == &inside && named == &wrote_it
        ),
        "{refused:?}"
    );

    // The root itself states no remainder at all, and rejoined it would
    // name the reading project's whole directory as a place this scope
    // owns.
    recording(&path, "skill:gh:claude", &wrote_it, Some(&wrote_it));
    let refused = load(&path).unwrap_err();
    assert!(
        matches!(
            &refused,
            CoreError::LockOutsideProject { key, recorded, root: named, .. }
                if key == "skill:gh:claude" && recorded == &wrote_it && named == &wrote_it
        ),
        "{refused:?}"
    );
}

/// A record rooted at nothing takes every position with it, and the
/// rejoin is what refuses them.
///
/// The empty prefix matches every path and hands it back whole, so each
/// position arrives at the rejoin exactly as the record spelled it. What
/// settles it is where that lands: a position naming another tree is
/// outside the root reading and refused, naming itself.
#[test]
fn a_position_that_rejoins_outside_the_reading_root_is_refused() {
    let tmp = tempfile::tempdir().unwrap();
    let root = tmp.path().join("here");
    std::fs::create_dir_all(&root).unwrap();
    let path = root.join(LOCK_FILE);
    let elsewhere = tmp.path().join("there/.agents/skills/gh");
    recording(&path, "skill:gh:claude", &elsewhere, Some(Path::new("")));

    let refused = load(&path).unwrap_err();
    assert!(
        matches!(
            &refused,
            CoreError::LockOutsideProject { key, recorded, .. }
                if key == "skill:gh:claude" && recorded == &elsewhere
        ),
        "{refused:?}"
    );
}

/// The reading root gets the same refusal, and reaches it the same way: a
/// relative lock path whose parent does not exist resolves to nothing, so
/// the raw spelling comes back through [`project_root_at`]. Rebasing onto
/// it would hand out positions read against whatever directory the process
/// happens to sit in later, and containment would pass every one of them.
#[test]
fn a_lock_read_at_a_relative_path_that_resolves_to_nothing_is_refused() {
    let tmp = tempfile::tempdir().unwrap();
    let wrote_it = tmp.path().join("wrote/here");
    let path = tmp.path().join(LOCK_FILE);
    recording(
        &path,
        "skill:gh:claude",
        &wrote_it.join(".agents/skills/gh"),
        Some(&wrote_it),
    );
    let text = std::fs::read_to_string(&path).unwrap();

    let refused =
        parse_text(Path::new("no-such-dir").join(LOCK_FILE).as_path(), &text).unwrap_err();
    assert!(
        matches!(
            &refused,
            CoreError::LockFromAnotherProject { recorded, root, .. }
                if recorded == &wrote_it && root == Path::new("no-such-dir")
        ),
        "{refused:?}"
    );
}

/// One directory reached through two spellings is still two prefixes.
///
/// A record written under `via`, a link to `real`, spells every position it
/// holds under `via` as well. Read at `real` the two roots resolve to one
/// directory, so a comparison asking that question skips the strip and
/// leaves every position spelled under `via` — outside the root reading,
/// and refused. What settles it is the spelling, because the spelling is
/// what comes off the front of each position.
#[test]
#[cfg(unix)]
fn a_record_rooted_through_a_link_resolves_onto_the_spelling_reading_it() {
    let tmp = tempfile::tempdir().unwrap();
    let real = tmp.path().join("real");
    std::fs::create_dir(&real).unwrap();
    let via = tmp.path().join("via");
    std::os::unix::fs::symlink(&real, &via).unwrap();
    assert_eq!(
        crate::paths::canonical(&via).unwrap(),
        crate::paths::canonical(&real).unwrap(),
        "the two spellings are one directory, which is what makes this the case"
    );

    // Written under `via`, positions and root alike, and read at `real`.
    recording(
        &real.join(LOCK_FILE),
        "skill:gh:claude",
        &via.join(".agents/skills/gh"),
        Some(&via),
    );
    let lock = load(&real.join(LOCK_FILE)).unwrap();
    assert_eq!(
        lock.entries["skill:gh:claude"]
            .emitted
            .as_ref()
            .unwrap()
            .paths,
        vec![
            crate::paths::canonical(&real)
                .unwrap()
                .join(".agents/skills/gh")
        ],
        "the position comes off `via` and lands under the spelling reading it"
    );
    assert_eq!(lock.root, Some(crate::paths::canonical(&real).unwrap()));
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

/// A record naming no project is refused rather than adopted: nothing knows
/// who wrote it, and reading it as this project's is the guess the refusal
/// exists to stop.
#[test]
fn a_project_lock_naming_no_project_is_refused() {
    let tmp = tempfile::tempdir().unwrap();
    let root = tmp.path().join("here");
    std::fs::create_dir(&root).unwrap();
    let path = root.join(LOCK_FILE);
    recording(
        &path,
        "skill:gh:claude",
        &root.join(".agents/skills/gh"),
        None,
    );

    assert!(matches!(
        load(&path),
        Err(CoreError::LockWithoutProject { .. })
    ));
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
        root: Some(nested),
        ..Lock::default()
    };

    assert!(matches!(
        save(&path, &lock),
        Err(CoreError::LockFromAnotherProject { .. })
    ));
    assert!(!path.exists(), "and nothing is left at the path");
}

/// A project lock may claim only what sits under its own root: the paths a
/// refresh reads back are the ones it takes off disk, and past the root
/// those belong to another project.
#[test]
fn a_project_lock_claiming_another_tree_is_refused() {
    let tmp = tempfile::tempdir().unwrap();
    let root = tmp.path().join("here");
    std::fs::create_dir(&root).unwrap();
    let path = root.join(LOCK_FILE);
    let elsewhere = tmp.path().join("there/.agents/skills/gh");
    recording(&path, "skill:gh:claude", &elsewhere, Some(&root));

    let refused = load(&path).unwrap_err();
    assert!(
        matches!(
            &refused,
            CoreError::LockOutsideProject { key, recorded, .. }
                if key == "skill:gh:claude" && recorded == &elsewhere
        ),
        "{refused:?}"
    );

    recording(
        &path,
        "skill:gh:claude",
        &root.join(".agents/skills/gh"),
        Some(&root),
    );
    assert_eq!(load(&path).unwrap().entries.len(), 1, "its own root loads");
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

    assert!(matches!(
        save(&path, &lock),
        Err(CoreError::LockOutsideProject { .. })
    ));
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
