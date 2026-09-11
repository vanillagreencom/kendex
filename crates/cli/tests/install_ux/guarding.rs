//! Installing the commit guards, end to end on a throwaway repository.
//!
//! The package is the engine, so these run its real scripts: the fixture
//! catalog carries this repository's own copy of commit-guards, and the
//! journey is the one a consumer takes — add the package, arm the hooks,
//! commit the posture, clone it somewhere else, arm there, commit again.
//! The clone is where the design is proved or not: its gate has to work
//! with no kendex on PATH at all.

use std::fs;
use std::path::Path;

use crate::{World, git, read, said};

/// This repository's own copy of a package, dropped into the fixture
/// catalog where `kendex add` will find it.
#[allow(clippy::unwrap_used)]
pub fn offer(world: &World, skill: &str) {
    let source = std::path::PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .join("../../skills")
        .canonicalize()
        .unwrap();
    copy_tree(
        &source.join(skill),
        &world.catalog.join("skills").join(skill),
    );
}

#[allow(clippy::unwrap_used)]
fn copy_tree(from: &Path, to: &Path) {
    fs::create_dir_all(to).unwrap();
    for entry in fs::read_dir(from).unwrap().flatten() {
        let target = to.join(entry.file_name());
        match entry.file_type().unwrap().is_dir() {
            true => copy_tree(&entry.path(), &target),
            false => {
                fs::copy(entry.path(), &target).unwrap();
                let mode = fs::metadata(entry.path()).unwrap().permissions();
                fs::set_permissions(&target, mode).unwrap();
            }
        }
    }
}

/// git in a directory, with a PATH that holds no kendex — the state a
/// teammate's machine is in.
#[allow(clippy::unwrap_used)]
pub fn git_without_kendex(dir: &Path, args: &[&str]) -> std::process::Output {
    std::process::Command::new("git")
        .args(["-c", "user.email=t@t", "-c", "user.name=t"])
        .args(args)
        .current_dir(dir)
        .env_remove("GIT_DIR")
        .env_remove("GIT_WORK_TREE")
        .env_remove("GIT_INDEX_FILE")
        .env("PATH", std::env::var("PATH").unwrap_or_default())
        .output()
        .unwrap()
}

pub fn spoke(output: &std::process::Output) -> String {
    let mut text = String::from_utf8_lossy(&output.stdout).into_owned();
    text.push_str(&String::from_utf8_lossy(&output.stderr));
    text
}

/// Installing the package puts its scripts in the committed tree, arming
/// writes shims that point at that tree, and a clone of the result gates
/// commits once armed there — with no kendex binary in the picture.
#[test]
#[allow(clippy::unwrap_used)]
fn the_guards_travel_with_the_repository_and_gate_a_clone() {
    let world = World::new(&["claude"]);
    world.declare_catalog();
    offer(&world, "commit-guards");
    world.run(&["add", "cat", "--skill", "commit-guards", "-y"]);

    // The scripts land in the tree a commit carries.
    let scripts = world.at(".agents/skills/commit-guards/scripts");
    assert!(scripts.join("pre-commit").is_file());
    assert!(read(&scripts.join("install-git-hooks")).contains("install-git-hooks"));

    // Arming writes shims, never core.hooksPath.
    let armed = world.run(&["guard", "install"]);
    assert!(
        armed.contains("armed") || armed.contains("hooks"),
        "{armed}"
    );
    assert!(world.at(".git/hooks/kendex-guards").is_file());
    let hooks_path = git_without_kendex(&world.project, &["config", "--get", "core.hooksPath"]);
    assert_eq!(
        hooks_path.status.code(),
        Some(1),
        "core.hooksPath is untouched"
    );

    world.commit_all("feat: install the commit guards");

    let clone = world.tmp.path().join("elsewhere/fresh-checkout");
    fs::create_dir_all(clone.parent().unwrap()).unwrap();
    git(
        &world.project,
        &["clone", "--quiet", ".", &clone.display().to_string()],
    );

    // A clone carries the scripts and no hooks: git never clones those.
    assert!(
        clone
            .join(".agents/skills/commit-guards/scripts/pre-commit")
            .is_file()
    );
    assert!(!clone.join(".git/hooks/kendex-guards").exists());

    // Arming in the clone is the one act that needs a tool. After it, the
    // gate is committed shell and git, and nothing else.
    crate::run(&world.home, &clone, &["guard", "install"]);
    fs::write(clone.join("late.rs"), "// TO".to_owned() + "DO: not yet\n").unwrap();
    git_without_kendex(&clone, &["add", "-A"]);
    let blocked = git_without_kendex(&clone, &["commit", "-m", "feat: adds a marker"]);
    assert!(!blocked.status.success(), "{}", spoke(&blocked));
    assert!(spoke(&blocked).contains("todo-ban"), "{}", spoke(&blocked));
}

/// Removing the package leaves no shim behind. A shim whose scripts are
/// gone fails closed on every commit, so disarming has to happen while the
/// package is still there to disarm with.
#[test]
#[allow(clippy::unwrap_used)]
fn disarming_before_removal_leaves_the_repository_committable() {
    let world = World::new(&["claude"]);
    world.declare_catalog();
    offer(&world, "commit-guards");
    world.run(&["add", "cat", "--skill", "commit-guards", "-y"]);
    world.run(&["guard", "install"]);
    assert!(world.at(".git/hooks/kendex-guards").is_file());

    world.run(&["guard", "uninstall"]);
    assert!(!world.at(".git/hooks/kendex-guards").exists());
    let hook = world.at(".git/hooks/pre-commit");
    assert!(
        !hook.exists() || !read(&hook).contains("kendex-guards-hook"),
        "the delegating line is gone"
    );

    world.run(&["remove", "commit-guards"]);
    fs::write(world.at("late.txt"), "fine\n").unwrap();
    git_without_kendex(&world.project, &["add", "-A"]);
    let ok = git_without_kendex(&world.project, &["commit", "-m", "feat: after removal"]);
    assert!(ok.status.success(), "{}", spoke(&ok));
}

/// Every way an armed package leaves disarms the repository first, and the
/// run says what it ran: `remove` on a shared-tree install; `remove` on a
/// copy delivery, where the package sits in the tool's own directory and
/// the shared tree may not exist; `remove` on a package switched off (the
/// switch renames its declaration and disarms nothing, so the shims are
/// live and probing only `SKILL.md` would read it as declaring nothing); and
/// a whole-scope apply of a manifest edited by hand to leave the package
/// out. Afterwards the delegating line is gone and a commit with no kendex
/// in the picture succeeds, which is what a leftover would have cost. One
/// row per door.
#[test]
#[allow(
    clippy::unwrap_used,
    clippy::too_many_lines,
    reason = "one table: four doors out of one armed fixture, each row an install and a departure of its own"
)]
fn every_door_an_armed_package_leaves_by_disarms_the_repository_first() {
    type Leave = fn(&World) -> String;
    type Row = (&'static str, &'static [&'static str], &'static str, Leave);
    let rows: [Row; 4] = [
        (
            "remove, shared tree",
            &[
                "add",
                "cat",
                "--skill",
                "commit-guards",
                "-y",
                "--allow-repo-effects",
            ],
            ".agents/skills/commit-guards",
            |world| world.run(&["remove", "commit-guards"]),
        ),
        (
            "remove, copy delivery",
            &[
                "add",
                "cat",
                "--skill",
                "commit-guards",
                "-y",
                "--copy",
                "--allow-repo-effects",
            ],
            ".claude/skills/commit-guards",
            |world| world.run(&["remove", "commit-guards"]),
        ),
        (
            "remove, switched off",
            &[
                "add",
                "cat",
                "--skill",
                "commit-guards",
                "-y",
                "--allow-repo-effects",
            ],
            ".agents/skills/commit-guards",
            |world| {
                // Switch it off, the way the manifest says it: the declaration
                // is renamed and the shims are left exactly where they were.
                world.declare_no_items(&["claude"]);
                let off_manifest = format!(
                    "{}\n[skills.commit-guards]\nsource = \"cat\"\nenabled = false\n",
                    world.manifest()
                );
                fs::write(world.at("kendex.toml"), off_manifest).unwrap();
                let off = world.run(&["apply", "-y"]);
                let tree = world.at(".agents/skills/commit-guards");
                assert!(
                    tree.join("SKILL.md.disabled").is_file() && !tree.join("SKILL.md").exists(),
                    "the switch did not rename the declaration:\n{off}"
                );
                assert!(
                    world.at(".git/hooks/kendex-guards").is_file(),
                    "nothing disarms on the switch:\n{off}"
                );
                world.run(&["remove", "commit-guards"])
            },
        ),
        (
            "a manifest applied without the package",
            &[
                "add",
                "cat",
                "--skill",
                "commit-guards",
                "-y",
                "--allow-repo-effects",
            ],
            ".agents/skills/commit-guards",
            |world| {
                assert!(
                    world.manifest().contains("[skills.commit-guards]"),
                    "{}",
                    world.manifest()
                );
                // The manifest a hand edit arrives at: the source and the tools
                // the add wrote, and no package.
                world.declare_no_items(&["claude"]);
                world.run(&["apply", "-y"])
            },
        ),
    ];
    for (door, add, installed_at, leave) in rows {
        let world = World::new(&["claude"]);
        world.declare_catalog();
        offer(&world, "commit-guards");
        let added = world.run(add);
        assert!(
            world.at(installed_at).join("SKILL.md").is_file(),
            "{door}: the package did not install where expected:\n{added}"
        );
        assert!(
            world.at(".git/hooks/kendex-guards").is_file(),
            "{door}: {added}"
        );

        let out = leave(&world);

        assert!(
            out.contains("commit-guards: running scripts/install-git-hooks --uninstall"),
            "{door}: the run did not say what it ran:\n{out}"
        );
        assert!(
            !world.at(installed_at).exists(),
            "{door}: the package stayed:\n{out}"
        );
        assert!(
            !world.at(".git/hooks/kendex-guards").exists(),
            "{door}: the helper was left behind:\n{out}"
        );
        let hook = world.at(".git/hooks/pre-commit");
        assert!(
            !hook.exists() || !read(&hook).contains("kendex-guards-hook"),
            "{door}: the delegating line was left behind:\n{out}"
        );
        // What the leftover would have cost: a commit, with no kendex in the
        // picture.
        fs::write(world.at("late.txt"), "fine\n").unwrap();
        git_without_kendex(&world.project, &["add", "-A"]);
        let ok = git_without_kendex(&world.project, &["commit", "-m", "feat: after leaving"]);
        assert!(ok.status.success(), "{door}: {}", spoke(&ok));
    }
}

/// A project that is not a git work tree has nothing armed to undo, and
/// removing the package from it does not run an uninstaller that would
/// refuse the directory.
///
/// The disclosure already stands down there — an effect writing into `.git`
/// is not offered where the git directory cannot be resolved — so the
/// removal has to stand down the same way, or every removal from a plain
/// directory fails over hooks it never had.
#[test]
#[allow(clippy::unwrap_used)]
fn removing_from_a_plain_directory_runs_no_uninstaller() {
    let world = World::new(&["claude"]);
    world.declare_catalog();
    offer(&world, "commit-guards");
    fs::remove_dir_all(world.at(".git")).unwrap();
    let added = world.try_run(&["add", "cat", "--skill", "commit-guards", "-y"]);
    assert!(added.status.success(), "{}", spoke(&added));

    let removed = world.try_run(&["remove", "commit-guards"]);
    let out = spoke(&removed);
    assert!(removed.status.success(), "{out}");
    assert!(!out.contains("running scripts/install-git-hooks"), "{out}");
    assert!(out.contains("not inside a git work tree"), "{out}");
    assert!(
        !world.at(".agents/skills/commit-guards").exists(),
        "the package stayed:\n{out}"
    );
}

/// An uninstaller that fails stops the removal with the package still
/// installed: the other order trashes the scripts and leaves exactly the
/// stranded state this exists to prevent.
#[test]
#[allow(clippy::unwrap_used)]
fn a_failing_uninstaller_keeps_the_package_installed() {
    use std::os::unix::fs::PermissionsExt;
    let world = World::new(&["claude"]);
    world.declare_catalog();
    offer(&world, "commit-guards");
    // The catalog's installer, wrapped: everything passes through except
    // the uninstall, which refuses.
    let installer = world
        .catalog
        .join("skills/commit-guards/scripts/install-git-hooks");
    let real = installer.with_file_name("install-git-hooks.real");
    fs::rename(&installer, &real).unwrap();
    fs::write(
        &installer,
        "#!/usr/bin/env bash\ncase \" $* \" in *\" --uninstall \"*) echo 'refusing to disarm' >&2; exit 1;; esac\nexec \"$(dirname \"$0\")/install-git-hooks.real\" \"$@\"\n",
    )
    .unwrap();
    fs::set_permissions(&installer, fs::Permissions::from_mode(0o755)).unwrap();
    world.run(&[
        "add",
        "cat",
        "--skill",
        "commit-guards",
        "-y",
        "--allow-repo-effects",
    ]);
    assert!(world.at(".git/hooks/kendex-guards").is_file());

    let removed = world.try_run(&["remove", "commit-guards"]);
    let out = spoke(&removed);
    assert!(!removed.status.success(), "the removal went ahead:\n{out}");
    assert!(out.contains("refusing to disarm"), "{out}");
    assert!(out.contains("exited 1"), "{out}");
    assert!(out.contains("its files stay in place"), "{out}");
    assert!(
        world.at(".agents/skills/commit-guards").is_dir(),
        "the scripts were trashed:\n{out}"
    );
    assert!(
        world.manifest().contains("[skills.commit-guards]"),
        "the declaration went:\n{}",
        world.manifest()
    );
    assert!(
        world.at(".git/hooks/kendex-guards").is_file(),
        "the helper went while the uninstall refused:\n{out}"
    );
}

/// A repository kendex armed whose gate has since lost a lane fails
/// `verify` and is named by `refresh`, and the refresh arms nothing.
///
/// kendex's record of the arming is what licenses asking the package, and
/// the package's answer is the whole verdict. A refresh brings a package's
/// next version and not a new arming, so a lane that version declares and
/// the armed shims do not carry is exactly this state: a push gate that is
/// missing while every render reads OK. Failing closed and naming the
/// verb that re-arms is what the two verbs owe; re-arming on the old yes
/// is what `commands::repo_effects` refuses to do.
#[test]
#[allow(clippy::unwrap_used)]
fn a_lapsed_arming_fails_verify_and_is_named_by_refresh() {
    const ROW: &str = "✗ setup commit-guards: kendex armed it here and the package says its effect is not in force — kendex guard install arms it again";
    let world = World::new(&["claude"]);
    world.declare_catalog();
    offer(&world, "commit-guards");
    world.run(&[
        "add",
        "cat",
        "--skill",
        "commit-guards",
        "-y",
        "--allow-repo-effects",
    ]);
    let pre_push = world.at(".git/hooks/pre-push");
    assert!(
        read(&pre_push).contains("kendex-guards"),
        "the yes did not arm the push lane"
    );

    // Armed and whole: nothing to name on either verb.
    let clean = world.try_run(&["verify", "--scope", "project"]);
    assert!(clean.status.success(), "{}", spoke(&clean));
    assert!(!spoke(&clean).contains("✗ setup"), "{}", spoke(&clean));
    let quiet = world.run(&["refresh", "--scope", "project"]);
    assert!(!quiet.contains("✗ setup"), "{quiet}");

    // The control: the push lane's delegating line goes, which is the
    // state a lane armed before it existed is in.
    let armed_text = read(&pre_push);
    let without: String = armed_text
        .lines()
        .filter(|line| !line.contains("kendex-guards"))
        .map(|line| format!("{line}\n"))
        .collect();
    assert_ne!(without, armed_text, "no delegating line to remove");
    fs::write(&pre_push, without).unwrap();

    let red = world.try_run(&["verify", "--scope", "project"]);
    let out = spoke(&red);
    assert_eq!(red.status.code(), Some(1), "{out}");
    assert!(out.contains(ROW), "{out}");
    // The package's own words travel with the row: they name the lane.
    assert!(out.contains("pre-push"), "{out}");

    let named = world.run(&["refresh", "--scope", "project"]);
    assert!(named.contains(ROW), "{named}");
    assert!(
        !read(&pre_push).contains("kendex-guards"),
        "refresh armed the lane on its own:\n{named}"
    );
}

/// `kendex check` names an unarmed repository, in the package's own words,
/// and says nothing once it is armed.
#[test]
#[allow(clippy::unwrap_used)]
fn check_names_an_unarmed_repository() {
    let world = World::new(&["claude"]);
    world.declare_catalog();
    offer(&world, "commit-guards");
    world.run(&["add", "cat", "--skill", "commit-guards", "-y"]);

    let unarmed = said(&world.try_run(&["check"]));
    assert!(unarmed.contains("commit hooks"), "{unarmed}");

    world.run(&["guard", "install"]);
    let armed = said(&world.try_run(&["check"]));
    assert!(!armed.contains("commit hooks"), "{armed}");
}
