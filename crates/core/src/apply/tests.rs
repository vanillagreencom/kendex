use super::*;
use crate::env::FakeOs;
use std::path::{Path, PathBuf};

fn env_in(dir: &Path) -> Env {
    Env::fake(dir, FakeOs::Linux)
}

fn write_plan(scope: Scope, path: PathBuf, content: &str, pre: Pre) -> Plan {
    plan(
        scope,
        vec![PlannedOp {
            description: format!("write {}", path.display()).into(),
            op: Op::WriteFile {
                path,
                bytes: content.as_bytes().to_vec(),
                pre,
            },
        }],
    )
}

/// Through the constructor the product builds every plan with: it is what
/// fixes each path at the place it lands, which the transaction then holds
/// it to.
fn plan(scope: Scope, ops: Vec<PlannedOp>) -> Plan {
    Plan::landed(scope, ops).expect("a plan whose targets stay in their scope")
}

/// A refusal part-way through takes the ops before it back with it: the
/// first op's bytes are restored, and the bytes the refusal protected are
/// left exactly as the outside writer left them.
#[test]
fn a_refusal_part_way_through_rolls_back_what_ran_before_it() {
    let tmp = tempfile::tempdir().unwrap();
    let env = env_in(tmp.path());
    let target = tmp.path().join("a/file.md");
    fs::create_dir_all(target.parent().unwrap()).unwrap();
    fs::write(&target, "before").unwrap();
    let second = tmp.path().join("b/new.md");

    let plan = plan(
        Scope::Global,
        vec![
            PlannedOp {
                description: "first".into(),
                op: Op::WriteFile {
                    path: target.clone(),
                    bytes: b"after".to_vec(),
                    pre: Pre::Any,
                },
            },
            PlannedOp {
                description: "second".into(),
                op: Op::WriteFile {
                    path: second.clone(),
                    bytes: b"new".to_vec(),
                    pre: Pre::Absent,
                },
            },
        ],
    );

    // Somebody else's file arrives at the second op's path between the
    // plan and the apply, so its precondition refuses.
    fs::create_dir_all(second.parent().unwrap()).unwrap();
    fs::write(&second, "not kendex's").unwrap();

    let error = execute(&env, &plan).unwrap_err();
    assert!(matches!(error, CoreError::RolledBack { .. }));
    assert_eq!(fs::read_to_string(&target).unwrap(), "before");
    assert_eq!(fs::read_to_string(&second).unwrap(), "not kendex's");

    // With the way clear the same plan applies whole.
    fs::remove_dir_all(second.parent().unwrap()).unwrap();
    let outcome = execute(&env, &plan).unwrap();
    assert_eq!(outcome.applied, 2);
    assert_eq!(fs::read_to_string(&target).unwrap(), "after");
    assert_eq!(fs::read_to_string(&second).unwrap(), "new");
}

/// An edit reads its file strictly, so bytes that are not UTF-8 refuse
/// rather than being decoded lossily and written back. A lossy read puts
/// U+FFFD where somebody's bytes were and then saves the replacement over
/// them, which is not an edit failing — it is an edit succeeding at
/// destroying the file.
#[test]
fn an_edit_over_bytes_that_are_not_utf8_refuses_and_leaves_them() {
    let tmp = tempfile::tempdir().unwrap();
    let env = env_in(tmp.path());
    let path = tmp.path().join("settings.json");
    let held = [b'a', 0xff, b'b'];
    fs::write(&path, held).unwrap();

    let op = Op::EditFile {
        path: path.clone(),
        edits: vec![crate::configedit::ConfigEdit::UpsertHook {
            event: "PreToolUse".to_owned(),
            matcher: None,
            command: "kendex hook".to_owned(),
            timeout: None,
        }],
        pre: Pre::Any,
    };
    let refused = op.run(&env).unwrap_err();
    assert!(
        matches!(&refused, CoreError::Io { source, .. }
            if source.kind() == std::io::ErrorKind::InvalidData),
        "{refused:?}"
    );
    assert_eq!(fs::read(&path).unwrap(), held, "the bytes are as they were");
}

/// A refused write makes nothing on its way to refusing.
///
/// The order is load-bearing, not tidy: `mutated_before_failure` reads a
/// `PlanStale` as proof the op ran nothing, so a directory chain the op
/// created before refusing is journaled absent, left out of the restore
/// set, and survives the rollback. What is left is the empty `.claude/`
/// that harness and project detection read as an installation.
#[test]
fn a_refused_write_makes_no_directory_and_a_passing_one_does() {
    let tmp = tempfile::tempdir().unwrap();
    let env = env_in(tmp.path());
    let root = tmp.path().join(".claude");
    let target = root.join("skills/ship/SKILL.md");

    // Nothing is at the path, so a precondition binding to bytes refuses.
    let refused = execute(
        &env,
        &write_plan(
            Scope::Global,
            target.clone(),
            "body",
            Pre::HashIs {
                hash: "not the bytes at that path".to_owned(),
            },
        ),
    )
    .unwrap_err();
    assert!(matches!(refused, CoreError::RolledBack { .. }));
    assert!(
        !root.exists(),
        "a refused write left the chain it would have needed"
    );

    // The same write with a precondition that holds does make it.
    let outcome = execute(
        &env,
        &write_plan(Scope::Global, target.clone(), "body", Pre::Absent),
    )
    .unwrap();
    assert_eq!(outcome.applied, 1);
    assert_eq!(fs::read_to_string(&target).unwrap(), "body");
}

#[test]
fn stale_precondition_aborts_and_rolls_back() {
    let tmp = tempfile::tempdir().unwrap();
    let env = env_in(tmp.path());
    let target = tmp.path().join("file.md");
    fs::write(&target, "changed since plan").unwrap();

    let plan = write_plan(Scope::Global, target.clone(), "overwrite", Pre::Absent);
    let error = execute(&env, &plan).unwrap_err();
    assert!(matches!(error, CoreError::RolledBack { .. }));
    assert_eq!(fs::read_to_string(&target).unwrap(), "changed since plan");
}

#[test]
fn interrupted_apply_recovers_on_next_run() {
    let tmp = tempfile::tempdir().unwrap();
    let env = env_in(tmp.path());
    let target = tmp.path().join("file.md");
    fs::write(&target, "before").unwrap();

    // Simulate a crash: journal written, mutation done, journal never
    // cleared.
    let journal_dir = journal::journal_dir_for(&env.journal_dir(), &scope_key(&Scope::Global));
    journal::write(&journal_dir, std::slice::from_ref(&target)).unwrap();
    fs::write(&target, "torn write").unwrap();

    assert!(recover(&env, &Scope::Global).unwrap());
    assert_eq!(fs::read_to_string(&target).unwrap(), "before");
    assert!(!recover(&env, &Scope::Global).unwrap());
}

/// A concurrently spawned child holds a copy of every parent fd's open
/// file description between fork and exec — O_CLOEXEC closes at exec,
/// not at fork — so a release that relied on closing the fd left flock
/// held for the length of any other thread's spawn window, and this
/// process was refused its own lock back with no writer alive. The
/// try_clone here is that fork copy at the description level: dropping
/// the guard must release the lock while the copy still exists.
#[cfg(unix)]
#[test]
fn drop_releases_the_lock_while_a_description_copy_exists() {
    let tmp = tempfile::tempdir().unwrap();
    let env = env_in(tmp.path());
    let guard = lock_scope(&env, &Scope::Global).unwrap();
    let copy = guard._file.file().try_clone().unwrap();
    drop(guard);
    let relock = lock_scope(&env, &Scope::Global);
    drop(copy);
    relock.unwrap();
}

#[test]
fn second_writer_gets_a_busy_error() {
    let tmp = tempfile::tempdir().unwrap();
    let env = env_in(tmp.path());
    let _guard = lock_scope(&env, &Scope::Global).unwrap();
    assert!(matches!(
        lock_scope(&env, &Scope::Global),
        Err(CoreError::ScopeBusy { .. })
    ));
}

/// Two spellings of one project root are one scope: the lock key comes
/// from the canonical root, never from the caller's path text.
#[test]
fn scope_identity_survives_path_spelling() {
    let tmp = tempfile::tempdir().unwrap();
    let env = env_in(tmp.path());
    let root = tmp.path().join("proj");
    fs::create_dir_all(root.join("sub")).unwrap();
    let plain = Scope::Project { root: root.clone() };
    let dotted = Scope::Project {
        root: root.join("sub").join(".."),
    };
    assert_eq!(scope_key(&plain), scope_key(&dotted));
    let _guard = lock_scope(&env, &plain).unwrap();
    assert!(matches!(
        lock_scope(&env, &dotted),
        Err(CoreError::ScopeBusy { .. })
    ));
}

#[test]
fn trash_receives_removals() {
    let tmp = tempfile::tempdir().unwrap();
    let env = env_in(tmp.path());
    let victim = tmp.path().join("skill");
    fs::create_dir_all(&victim).unwrap();
    fs::write(victim.join("SKILL.md"), "content").unwrap();

    let plan = plan(
        Scope::Global,
        vec![PlannedOp {
            description: "remove skill".into(),
            op: Op::Trash {
                absent_is_done: true,
                path: victim.clone(),
                pre: Pre::Any,
            },
        }],
    );
    execute(&env, &plan).unwrap();
    assert!(!victim.exists());
    let trashed: Vec<_> = fs::read_dir(env.trash_dir()).unwrap().flatten().collect();
    assert_eq!(trashed.len(), 1);
    assert!(trashed[0].path().join("SKILL.md").is_file());
}

/// An installation whose harness copies are only partly present: the
/// plan named a copy that is no longer there. The removal reaches the
/// end state that copy was planned for, so the rest of it lands
/// instead of rolling back and leaving the item half-present with no
/// way forward.
#[test]
fn a_copy_already_gone_does_not_take_the_removal_with_it() {
    let tmp = tempfile::tempdir().unwrap();
    let env = env_in(tmp.path());
    let present = tmp.path().join("here/SKILL.md");
    fs::create_dir_all(present.parent().unwrap()).unwrap();
    fs::write(&present, "content").unwrap();

    let plan = plan(
        Scope::Global,
        vec![
            PlannedOp {
                description: "remove the copy that is gone".into(),
                op: Op::Trash {
                    absent_is_done: true,
                    path: tmp.path().join("gone"),
                    pre: Pre::HashIs {
                        hash: "whatever the plan saw".into(),
                    },
                },
            },
            PlannedOp {
                description: "remove the copy that is here".into(),
                op: Op::Trash {
                    absent_is_done: true,
                    path: present.clone(),
                    pre: Pre::Any,
                },
            },
        ],
    );

    assert_eq!(execute(&env, &plan).unwrap().applied, 2);
    assert!(!present.exists());
}

/// The other half a link needs: still here, and what it points at is
/// not. It goes to the trash like anything else — being unreadable
/// through is not being gone.
#[cfg(unix)]
#[test]
fn a_link_whose_target_is_gone_still_goes_to_the_trash() {
    let tmp = tempfile::tempdir().unwrap();
    let env = env_in(tmp.path());
    let link = tmp.path().join("skills/decider");
    let gone = tmp.path().join("shared/decider");
    fs::create_dir_all(link.parent().unwrap()).unwrap();
    std::os::unix::fs::symlink(&gone, &link).unwrap();

    let plan = plan(
        Scope::Global,
        vec![PlannedOp {
            description: "remove the link".into(),
            op: Op::Trash {
                absent_is_done: true,
                path: link.clone(),
                pre: Pre::SymlinkTo {
                    target: gone.clone(),
                },
            },
        }],
    );

    execute(&env, &plan).unwrap();
    assert!(!link.is_symlink());
    let held = fs::read_dir(env.trash_dir()).unwrap().flatten().next();
    assert_eq!(fs::read_link(held.unwrap().path()).unwrap(), gone);
}

/// The route the fix exists for, end to end: the artifact and the trash
/// on different filesystems, so rename(2) refuses and the move is made
/// by hand. /dev/shm is the second mount; a machine that does not have
/// it as one has nothing to prove here.
#[cfg(target_os = "linux")]
#[test]
fn a_link_crosses_a_filesystem_boundary_into_the_trash() {
    use std::os::unix::fs::MetadataExt as _;
    let tmp = tempfile::tempdir().unwrap();
    let env = env_in(tmp.path());
    let Ok(elsewhere) = tempfile::tempdir_in("/dev/shm") else {
        return;
    };
    let (Ok(here), Ok(there)) = (
        fs::metadata(tmp.path()).map(|m| m.dev()),
        fs::metadata(elsewhere.path()).map(|m| m.dev()),
    ) else {
        return;
    };
    if here == there {
        return;
    }
    let link = elsewhere.path().join("decider");
    let gone = elsewhere.path().join("shared/decider");
    std::os::unix::fs::symlink(&gone, &link).unwrap();

    let plan = plan(
        Scope::Global,
        vec![PlannedOp {
            description: "remove the link".into(),
            op: Op::Trash {
                absent_is_done: true,
                path: link.clone(),
                pre: Pre::SymlinkTo {
                    target: gone.clone(),
                },
            },
        }],
    );

    execute(&env, &plan).unwrap();
    assert!(!link.is_symlink());
    let held = fs::read_dir(env.trash_dir()).unwrap().flatten().next();
    assert_eq!(fs::read_link(held.unwrap().path()).unwrap(), gone);
}

/// A path the apply cannot read is not a path it may call removed: the
/// record would go while the files stayed installed. Only absence the
/// stat proves is the end state a removal asked for.
#[cfg(unix)]
#[test]
fn a_copy_that_cannot_be_read_stops_the_removal() {
    use std::os::unix::fs::PermissionsExt as _;
    let tmp = tempfile::tempdir().unwrap();
    let env = env_in(tmp.path());
    let sealed = tmp.path().join("sealed");
    let victim = sealed.join("SKILL.md");
    fs::create_dir_all(&sealed).unwrap();
    fs::write(&victim, "content").unwrap();
    fs::set_permissions(&sealed, fs::Permissions::from_mode(0o000)).unwrap();
    let unlock = || fs::set_permissions(&sealed, fs::Permissions::from_mode(0o700)).unwrap();
    if fs::symlink_metadata(&victim).is_ok() {
        // Permissions do not bind this user (root): the read cannot be
        // made to fail here.
        unlock();
        return;
    }

    let plan = plan(
        Scope::Global,
        vec![PlannedOp {
            description: "remove the copy nothing can read".into(),
            op: Op::Trash {
                absent_is_done: true,
                path: victim.clone(),
                pre: Pre::Any,
            },
        }],
    );

    // Unlocked before anything can panic: a sealed directory outlives the
    // TempDir that cannot remove it.
    let outcome = execute(&env, &plan);
    unlock();
    assert!(matches!(outcome.unwrap_err(), CoreError::RolledBack { .. }));
    assert_eq!(fs::read_to_string(&victim).unwrap(), "content");
}

/// The other half of the same rule: a copy that is still there, and
/// not the bytes the plan proved it could take, stops the apply.
#[test]
fn a_copy_that_changed_still_stops_the_removal() {
    let tmp = tempfile::tempdir().unwrap();
    let env = env_in(tmp.path());
    let edited = tmp.path().join("edited.md");
    fs::write(&edited, "not what the plan read").unwrap();

    let plan = plan(
        Scope::Global,
        vec![PlannedOp {
            description: "remove the edited copy".into(),
            op: Op::Trash {
                absent_is_done: true,
                path: edited.clone(),
                pre: Pre::HashIs {
                    hash: "what the plan read".into(),
                },
            },
        }],
    );

    let error = execute(&env, &plan).unwrap_err();
    assert!(matches!(error, CoreError::RolledBack { .. }));
    assert_eq!(
        fs::read_to_string(&edited).unwrap(),
        "not what the plan read"
    );
}
