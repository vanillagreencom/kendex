//! The desktop's account of what a package does to the repository, and the
//! yes that is separate from installing it.
//!
//! An install from the window is one command that plans and writes. The
//! effect a package declares must come back out of it unrun, with what a
//! person needs in order to decide — and arming is a second command, so a
//! window that closes the dialog leaves the repository as it was.
#![cfg(unix)]

#[path = "../../test_util.rs"]
mod test_util;
use test_util::source_path;

use std::fs;
use std::os::unix::fs::PermissionsExt;
use std::path::{Path, PathBuf};

use kendex_app::marketplaces::install::{InstallItem, Installed, install};
use kendex_core::env::{Env, FakeOs};
use kendex_core::model::{ItemKind, Scope};

struct Fixture {
    _tmp: tempfile::TempDir,
    env: Env,
    scope: Scope,
    project: PathBuf,
}

#[allow(clippy::unwrap_used)]
fn git(dir: &Path, args: &[&str]) {
    let output = std::process::Command::new("git")
        .args(["-c", "user.email=t@t", "-c", "user.name=t"])
        .args(args)
        .current_dir(dir)
        .env_remove("GIT_DIR")
        .env_remove("GIT_WORK_TREE")
        .env_remove("GIT_INDEX_FILE")
        .output()
        .unwrap();
    assert!(
        output.status.success(),
        "git {args:?}: {}",
        String::from_utf8_lossy(&output.stderr)
    );
}

#[allow(clippy::unwrap_used)]
fn copy_tree(from: &Path, to: &Path) {
    fs::create_dir_all(to).unwrap();
    for entry in fs::read_dir(from).unwrap() {
        let entry = entry.unwrap();
        let target = to.join(entry.file_name());
        if entry.file_type().unwrap().is_dir() {
            copy_tree(&entry.path(), &target);
        } else {
            fs::copy(entry.path(), &target).unwrap();
        }
    }
}

/// A git project subscribed to a catalog that offers the repository's own
/// growth-guards and size-ratchet packages beside an inert one, plus a
/// bundle carrying growth-guards, with Claude on the machine.
#[allow(clippy::unwrap_used)]
fn fixture() -> Fixture {
    let tmp = tempfile::tempdir().unwrap();
    let home = tmp.path().canonicalize().unwrap();
    let project = home.join("dev/app");
    let catalog = home.join("catalog");
    let shipped = PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .join("../../skills")
        .canonicalize()
        .unwrap();
    for skill in ["growth-guards", "size-ratchet"] {
        copy_tree(&shipped.join(skill), &catalog.join("skills").join(skill));
    }
    fs::create_dir_all(catalog.join("skills/deploy")).unwrap();
    fs::write(
        catalog.join("skills/deploy/SKILL.md"),
        "---\nname: deploy\ndescription: ship the service\n---\nRun the deploy.\n",
    )
    .unwrap();
    // A package whose installer exits clean and writes to both channels —
    // the shipped shape of growth-guards skipping its work: the summary on
    // stdout, the reason and the remedy on stderr.
    let noisy = catalog.join("skills/noisy/scripts");
    fs::create_dir_all(&noisy).unwrap();
    fs::write(
        catalog.join("skills/noisy/SKILL.md"),
        "---\nname: noisy\ndescription: says something on both channels\n\
         repo-effects:\n  summary: \"arms nothing here\"\n  \
         installer: \"scripts/arm\"\n---\nBody.\n",
    )
    .unwrap();
    fs::write(
        noisy.join("arm"),
        "#!/bin/sh\necho 'core.hooksPath is set; unset it and run this again' >&2\n\
         echo 'hooks: skipped'\n",
    )
    .unwrap();
    fs::set_permissions(noisy.join("arm"), fs::Permissions::from_mode(0o755)).unwrap();
    fs::write(
        catalog.join("kendex.toml"),
        "[bundles.guards]\ndescription = \"the commit gate\"\nskills = [\"growth-guards\"]\n",
    )
    .unwrap();
    fs::create_dir_all(home.join(".claude")).unwrap();
    fs::create_dir_all(project.join(".agents")).unwrap();
    git(&project, &["init", "--quiet", "-b", "main"]);
    fs::write(project.join("README.md"), "the app\n").unwrap();
    git(&project, &["add", "."]);
    git(&project, &["commit", "--quiet", "-m", "start"]);
    fs::write(
        project.join("kendex.toml"),
        format!("schema = 6\n\n[sources.cat]\n{}\n", source_path(&catalog)),
    )
    .unwrap();
    Fixture {
        env: Env::fake(&home, FakeOs::Linux),
        scope: Scope::Project {
            root: project.clone(),
        },
        project,
        _tmp: tmp,
    }
}

fn install_skills(f: &Fixture, names: &[&str], bundle: Option<&str>) -> Installed {
    install(
        &f.env,
        f.scope.clone(),
        "cat".to_owned(),
        names
            .iter()
            .map(|name| InstallItem {
                kind: ItemKind::Skill,
                name: (*name).to_owned(),
            })
            .collect(),
        bundle.map(str::to_owned),
        None,
        false,
        None,
        None,
    )
    .unwrap_or_else(|error| panic!("install {names:?} {bundle:?}: {error}"))
}

fn companion<'a>(
    offer: &'a kendex_core::repo_effects::Disclosure,
    name: &str,
) -> &'a kendex_core::repo_effects::Companion {
    offer
        .companions
        .iter()
        .find(|c| c.name == name)
        .unwrap_or_else(|| panic!("no companion {name}: {:?}", offer.companions))
}

/// Installing writes the package and hands back its account — what
/// changes, where it writes, which companions are here, how to undo it —
/// with the repository untouched. The separate yes is what arms it.
#[test]
#[allow(clippy::unwrap_used)]
fn the_effect_comes_back_unrun_and_a_separate_yes_arms_it() {
    let f = fixture();
    let installed = install_skills(&f, &["growth-guards"], None);

    assert!(
        f.project
            .join(".agents/skills/growth-guards/scripts/install-git-hooks")
            .is_file(),
        "the package did not install"
    );
    assert!(
        !f.project.join(".git/hooks/kendex-guards").exists(),
        "the install armed the hooks with nobody asked"
    );
    assert!(
        installed.repo_effects.withheld.is_empty(),
        "{:?}",
        installed.repo_effects.withheld
    );
    let [offer] = installed.repo_effects.shown.as_slice() else {
        panic!("one offer: {:?}", installed.repo_effects);
    };
    assert_eq!(offer.name, "growth-guards");
    assert!(offer.summary.contains("every commit"));
    let hooks = f.project.join(".git/hooks");
    let written: Vec<&str> = offer.writes.iter().map(|w| w.path.as_str()).collect();
    assert!(
        written.contains(&hooks.join("pre-commit").to_str().unwrap()),
        "{written:?}"
    );
    assert!(offer.writes.iter().all(|w| w.shared), "{:?}", offer.writes);
    assert!(!companion(offer, "size-ratchet").installed);
    // The declared uninstaller, resolved where it really sits and quoted
    // as a command — not the package's removal prose, which says to run it.
    assert_eq!(
        offer.undo.as_deref(),
        Some(
            "run `'.agents/skills/growth-guards/scripts/install-git-hooks' '--uninstall'` \
             from the repository root"
        )
    );

    let said = kendex_app::repo_effects::apply(&f.env, &f.scope, &offer.declared).unwrap();
    assert!(
        f.project.join(".git/hooks/kendex-guards").is_file(),
        "the yes did not arm the hooks"
    );
    // The installer's own last word is what the window shows.
    assert!(
        said.stdout
            .last()
            .is_some_and(|line| line.contains("armed")),
        "{said:?}"
    );
}

/// A clean exit is not a silent one. An installer that skipped its work
/// says why on stderr, and stdout alone is the half of that account which
/// does not say what to do about it.
#[test]
#[allow(clippy::unwrap_used)]
fn a_clean_exit_carries_both_channels() {
    let f = fixture();
    let installed = install_skills(&f, &["noisy"], None);
    let [offer] = installed.repo_effects.shown.as_slice() else {
        panic!("one offer: {:?}", installed.repo_effects);
    };

    let said = kendex_app::repo_effects::apply(&f.env, &f.scope, &offer.declared).unwrap();
    assert_eq!(said.stdout, vec!["hooks: skipped".to_owned()]);
    assert_eq!(
        said.stderr,
        vec!["core.hooksPath is set; unset it and run this again".to_owned()]
    );
}

/// The yes is for the package the window was shown, not for whatever root
/// comes back with it. Arming confines a program to the root it is handed,
/// so a root the caller chose would confine nothing.
#[test]
#[allow(clippy::unwrap_used)]
fn a_root_this_scope_never_installed_is_refused() {
    let f = fixture();
    let installed = install_skills(&f, &["growth-guards"], None);
    let [offer] = installed.repo_effects.shown.as_slice() else {
        panic!("one offer: {:?}", installed.repo_effects);
    };

    let forged = kendex_core::repo_effects::DeclaredEffects {
        root: PathBuf::from("/"),
        effects: kendex_core::repo_effects::RepoEffects {
            installer: Some("bin/sh -c id".to_owned()),
            ..offer.declared.effects.clone()
        },
        ..offer.declared.clone()
    };
    let error = kendex_app::repo_effects::apply(&f.env, &f.scope, &forged).unwrap_err();
    assert!(
        error.contains("no record of installing it there"),
        "{error}"
    );
    assert!(
        !f.project.join(".git/hooks/kendex-guards").exists(),
        "the forged root armed the hooks"
    );
}

/// A companion already in the scope is reported as installed — the one
/// fact about companions kendex answers rather than the package.
#[test]
fn a_companion_already_here_reads_as_installed() {
    let f = fixture();
    let first = install_skills(&f, &["size-ratchet"], None);
    assert!(first.repo_effects.is_empty(), "{:?}", first.repo_effects);
    let installed = install_skills(&f, &["growth-guards"], None);
    let [offer] = installed.repo_effects.shown.as_slice() else {
        panic!("one offer: {:?}", installed.repo_effects);
    };
    assert!(companion(offer, "size-ratchet").installed);
    assert!(!companion(offer, "preflight").installed);
}

/// A set that carries a declaring package brings the same offer, on both
/// of the app's bundle routes.
#[test]
fn a_bundle_carrying_the_package_brings_its_offer() {
    let f = fixture();
    let installed = install_skills(&f, &[], Some("guards"));
    assert_eq!(
        installed.repo_effects.shown.len(),
        1,
        "{:?}",
        installed.repo_effects
    );
    assert_eq!(installed.repo_effects.shown[0].name, "growth-guards");

    let g = fixture();
    let installed = kendex_app::sources::install_bundle(
        &g.env,
        &g.scope,
        "cat".to_owned(),
        "guards".to_owned(),
        false,
    )
    .unwrap_or_else(|error| panic!("bundle_install: {error}"));
    assert_eq!(
        installed.repo_effects.shown.len(),
        1,
        "{:?}",
        installed.repo_effects
    );
    assert!(
        !g.project.join(".git/hooks/kendex-guards").exists(),
        "the bundle install armed the hooks with nobody asked"
    );
}

/// A package with no declaration adds nothing to the install: no offer,
/// no notice, and the window has nothing to open.
#[test]
fn an_inert_package_brings_no_offer() {
    let f = fixture();
    let installed = install_skills(&f, &["deploy"], None);
    assert!(
        installed.repo_effects.is_empty(),
        "{:?}",
        installed.repo_effects
    );
    assert!(installed.packages.iter().any(|p| p.name == "deploy"));
}
