//! The desktop's account of what a package does to the repository, and
//! the yes that is separate from installing it.
//!
//! An install from the window is one command that plans and writes. The
//! effect a package declares must come back out of it unrun, with what a
//! person needs in order to decide — and arming is a second command, so
//! a window that closes the dialog leaves the repository as it was.
//!
//! What either half of the module does to a third party's own output is
//! `repo_effects_escaping.rs`.
#![cfg(unix)]

#[path = "repo_effects/fixture.rs"]
mod fixture;
use fixture::*;

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
        written.contains(&kendex_core::paths::slashed(&hooks.join("pre-commit")).as_str()),
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
    // The installer's own last word is what the window shows — its
    // success wording, not the substring its failures share with it:
    // every "NOT armed" line the installer can print contains "armed".
    assert!(
        said.stdout
            .last()
            .is_some_and(|line| line.contains("pre-commit and commit-msg armed in")),
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

/// Arm the repository from the window, the way an install's second yes
/// does, and prove the hooks are live.
#[allow(clippy::unwrap_used)]
fn arm(f: &Fixture) {
    let installed = install_skills(f, &["growth-guards"], None);
    let [offer] = installed.repo_effects.shown.as_slice() else {
        panic!("one offer: {:?}", installed.repo_effects);
    };
    kendex_app::repo_effects::apply(&f.env, &f.scope, &offer.declared).unwrap();
    assert!(
        f.project.join(".git/hooks/kendex-guards").is_file(),
        "the yes did not arm the hooks"
    );
}

/// A commit in the project, with no kendex in the picture — what a shim
/// pointing at a script that is gone costs.
fn commit(f: &Fixture, message: &str) -> std::process::Output {
    #[allow(clippy::unwrap_used)]
    {
        fs::write(f.project.join("late.txt"), message).unwrap();
        own_git(&["commit", "--quiet", "-a", "-m", message], &f.project)
            .output()
            .unwrap()
    }
}

/// Removing the package from the window disarms the repository first, and
/// the action's own result says what ran.
///
/// The terminal has done this since the uninstaller was declared; the
/// window called `apply::execute` on the plan and dropped the report, so
/// the scripts went and the shims stayed — and every commit in that
/// repository failed closed until somebody found two files under
/// `.git/hooks` by hand.
#[test]
#[allow(clippy::unwrap_used)]
fn removing_a_package_disarms_the_repository_and_says_so() {
    let f = fixture();
    arm(&f);
    git(&f.project, &["add", "."]);

    let view = kendex_app::audit::remove(&f.env, &f.scope, ItemKind::Skill, "growth-guards")
        .unwrap_or_else(|error| panic!("remove: {error}"));

    assert!(
        !f.project.join(".git/hooks/kendex-guards").exists(),
        "the removal left the shim behind"
    );
    assert!(
        view.undone
            .iter()
            .any(|line| line == "growth-guards: running scripts/install-git-hooks --uninstall"),
        "{:?}",
        view.undone
    );
    git(&f.project, &["add", "-A"]);
    let after = commit(&f, "after removal");
    assert!(
        after.status.success(),
        "the repository could not commit: {}",
        String::from_utf8_lossy(&after.stderr)
    );
}

/// Unsubscribing takes the source's packages with it, so it disarms them
/// the same way and hands the account back for the window to show.
#[test]
#[allow(clippy::unwrap_used)]
fn unsubscribing_disarms_the_packages_that_leave_with_the_source() {
    let f = fixture();
    arm(&f);
    git(&f.project, &["add", "."]);

    let undone = kendex_app::unsubscribe::unsubscribe(&f.env, &f.scope, "cat", false, false)
        .unwrap_or_else(|error| panic!("unsubscribe: {error}"));

    assert!(
        !f.project.join(".git/hooks/kendex-guards").exists(),
        "the unsubscribe left the shim behind"
    );
    assert!(
        undone
            .undone
            .iter()
            .any(|line| line.starts_with("growth-guards: running")),
        "{undone:?}"
    );
}

/// A whole-scope apply takes a package away when the manifest no longer
/// declares it — the shape a hand edit and the built-in editor both
/// arrive at — and that removal disarms first too.
#[test]
#[allow(clippy::unwrap_used)]
fn applying_a_manifest_without_the_package_disarms_first() {
    let f = fixture();
    arm(&f);
    let manifest = f.project.join("kendex.toml");
    let text = fs::read_to_string(&manifest).unwrap();
    assert!(text.contains("[skills.growth-guards]"), "{text}");
    fs::write(
        &manifest,
        text.replace("[skills.growth-guards]\nsource = \"cat\"\n", ""),
    )
    .unwrap();

    let view = kendex_app::audit::apply_scope(&f.env, &f.scope, true)
        .unwrap_or_else(|error| panic!("apply_scope: {error}"));

    assert!(
        !f.project.join(".git/hooks/kendex-guards").exists(),
        "the apply left the shim behind"
    );
    assert!(
        view.undone
            .iter()
            .any(|line| line.starts_with("growth-guards: running")),
        "{:?}",
        view.undone
    );
}

/// An uninstaller that refuses stops the removal with the package's files
/// still in place, and the refusal carries the package's own words.
///
/// The other order is the state this exists to prevent: files gone, shims
/// still delegating to them, and nobody able to commit.
#[test]
#[allow(clippy::unwrap_used)]
fn a_refusing_uninstaller_stops_the_removal() {
    let f = fixture();
    arm(&f);
    // The installed copy's script, wrapped: everything passes through
    // except the uninstall, which refuses.
    let installer = f
        .project
        .join(".agents/skills/growth-guards/scripts/install-git-hooks");
    let real = installer.with_file_name("install-git-hooks.real");
    fs::rename(&installer, &real).unwrap();
    fs::write(
        &installer,
        "#!/usr/bin/env bash\ncase \" $* \" in *\" --uninstall \"*) \
         echo 'refusing to disarm' >&2; exit 1;; esac\n\
         exec \"$(dirname \"$0\")/install-git-hooks.real\" \"$@\"\n",
    )
    .unwrap();
    fs::set_permissions(&installer, fs::Permissions::from_mode(0o755)).unwrap();

    let error = match kendex_app::audit::remove(&f.env, &f.scope, ItemKind::Skill, "growth-guards")
    {
        Err(error) => error,
        Ok(_) => panic!("the removal went ahead"),
    };

    assert!(error.contains("refusing to disarm"), "{error}");
    assert!(error.contains("its files stay in place"), "{error}");
    assert!(
        installer.is_file(),
        "the package's files went despite the refusal"
    );
    assert!(
        f.project.join(".git/hooks/kendex-guards").is_file(),
        "the shim went with a removal that refused"
    );
}

/// A package that declares no uninstaller is removed with that said, and
/// nothing is run.
#[test]
#[allow(clippy::unwrap_used)]
fn a_package_with_no_uninstaller_is_removed_with_that_said() {
    let f = fixture();
    install_skills(&f, &["noisy"], None);

    let view = kendex_app::audit::remove(&f.env, &f.scope, ItemKind::Skill, "noisy")
        .unwrap_or_else(|error| panic!("remove: {error}"));

    assert!(
        view.undone
            .iter()
            .any(|line| line.contains("noisy: declares no uninstaller")),
        "{:?}",
        view.undone
    );
}

/// An inert package's removal has nothing to account for, so the window is
/// told nothing — a line per removal would bury the one that matters.
#[test]
#[allow(clippy::unwrap_used)]
fn removing_an_inert_package_says_nothing() {
    let f = fixture();
    install_skills(&f, &["deploy"], None);

    let view = kendex_app::audit::remove(&f.env, &f.scope, ItemKind::Skill, "deploy")
        .unwrap_or_else(|error| panic!("remove: {error}"));

    assert!(view.undone.is_empty(), "{:?}", view.undone);
}

/// A write that must take nothing away refuses when it would, rather than
/// running an uninstaller whose account nobody would see.
#[test]
#[allow(clippy::unwrap_used)]
fn a_write_that_must_remove_nothing_refuses_when_it_would() {
    let f = fixture();
    arm(&f);
    // The report a whole-scope apply builds once the manifest no longer
    // declares the package: a real removal, with the effect leaving.
    let manifest = f.project.join("kendex.toml");
    let text = fs::read_to_string(&manifest).unwrap();
    fs::write(
        &manifest,
        text.replace("[skills.growth-guards]\nsource = \"cat\"\n", ""),
    )
    .unwrap();
    let report = kendex_core::engine::plan_apply(
        &f.env,
        &f.scope,
        &kendex_core::engine::PlanOptions {
            remove_orphans: true,
            ..Default::default()
        },
    )
    .unwrap();
    assert!(
        !report.repo_effects_leaving.is_empty(),
        "the fixture built a report with nothing leaving"
    );

    let refused = kendex_app::repo_effects::write_nothing_leaving(&f.env, &report).unwrap_err();

    assert!(refused.contains("growth-guards"), "{refused}");
    assert!(refused.contains("Audit page"), "{refused}");
    assert!(
        f.project.join(".git/hooks/kendex-guards").is_file(),
        "the refusal ran the uninstaller anyway"
    );
}

/// A chatty package cannot bury the notice its neighbour is owed.
///
/// The account interleaves kendex's own lines with unbounded output from
/// each departing package, in name order. A budget spent across the whole
/// list lets the first package's chatter push the second's notice off the
/// end — and "declares no uninstaller — what it changed stays" is the only
/// place kendex says an effect was left standing and names the manual
/// remedy. A verbose uninstaller does that by accident; an installed
/// package can do it on purpose.
#[test]
#[allow(clippy::unwrap_used)]
fn a_chatty_package_cannot_bury_a_neighbour_s_stand_down() {
    let f = fixture();
    let catalog = f.env.home.join("catalog");
    // Sorted first, so its output is emitted before the other's notice.
    let loud = catalog.join("skills/aaa-loud/scripts");
    fs::create_dir_all(&loud).unwrap();
    fs::write(
        catalog.join("skills/aaa-loud/SKILL.md"),
        "---\nname: aaa-loud\ndescription: says a great deal on the way out\n\
         repo-effects:\n  summary: \"talks\"\n  uninstaller: \"scripts/out\"\n---\nBody.\n",
    )
    .unwrap();
    fs::write(
        loud.join("out"),
        "#!/bin/sh\ni=0\nwhile [ $i -lt 200 ]; do echo \"chatter $i\"; i=$((i+1)); done\n",
    )
    .unwrap();
    fs::set_permissions(loud.join("out"), fs::Permissions::from_mode(0o755)).unwrap();
    // Sorted second, and it declares no uninstaller — so its one line is
    // the only word anybody gets about what it left behind.
    fs::create_dir_all(catalog.join("skills/zzz-quiet")).unwrap();
    fs::write(
        catalog.join("skills/zzz-quiet/SKILL.md"),
        "---\nname: zzz-quiet\ndescription: leaves something standing\n\
         repo-effects:\n  summary: \"changes the repository\"\n  \
         removal: \"undo it by hand\"\n---\nBody.\n",
    )
    .unwrap();
    install_skills(&f, &["aaa-loud", "zzz-quiet"], None);

    // Both leave together: the manifest stops declaring either.
    let manifest = f.project.join("kendex.toml");
    let text = fs::read_to_string(&manifest).unwrap();
    let kept: String = text
        .split("\n[")
        .enumerate()
        .filter(|(n, block)| {
            *n == 0
                || !(block.starts_with("skills.aaa-loud]")
                    || block.starts_with("skills.zzz-quiet]"))
        })
        .map(|(n, block)| match n {
            0 => block.to_owned(),
            _ => format!("\n[{block}"),
        })
        .collect();
    fs::write(&manifest, kept).unwrap();

    let view = kendex_app::audit::apply_scope(&f.env, &f.scope, true)
        .unwrap_or_else(|error| panic!("apply_scope: {error}"));

    let said = view.undone.join("\n");
    assert!(
        said.contains("zzz-quiet: declares no uninstaller"),
        "the chatty package buried its neighbour's stand-down:\n{said}"
    );
    assert!(said.contains("to undo: undo it by hand"), "{said}");
    // And the chatter itself is still bounded, with the count said rather
    // than the tail dropped in silence.
    assert!(
        view.undone.len() < 40,
        "the account carried {} lines",
        view.undone.len()
    );
    assert!(said.contains("more lines from that package"), "{said}");
}

/// A project registered beside the fixture's own, carrying a manifest that
/// will not parse — so the whole-machine listing every source action ends
/// with fails, after the write.
#[allow(clippy::unwrap_used)]
fn a_second_project_that_cannot_be_listed(f: &Fixture) {
    let broken = f.env.home.join("dev/broken");
    fs::create_dir_all(&broken).unwrap();
    fs::write(broken.join("kendex.toml"), "schema = 6\n[sources.x\n").unwrap();
    let settings = f.env.settings_file();
    fs::create_dir_all(settings.parent().unwrap()).unwrap();
    fs::write(
        &settings,
        format!(
            "schema = 1\nprojects = [{}, {}]\n",
            toml::Value::from(kendex_core::paths::slashed(&f.project)),
            toml::Value::from(kendex_core::paths::slashed(&broken)),
        ),
    )
    .unwrap();
}

/// A read that fails after the write still says what the write ran.
///
/// By the time a source action reads back what stands, the uninstallers
/// have run and the plan is committed. A `?` on that read used to discard
/// the account with the answer it was riding on, leaving the person a
/// listing error over a repository that had just been disarmed — this
/// issue's own failure mode, reached through the error path.
#[test]
#[allow(clippy::unwrap_used)]
fn a_listing_that_fails_after_the_write_still_says_what_ran() {
    let f = fixture();
    arm(&f);
    // The package stops rendering, so the plan drops its lock entry and
    // runs its uninstaller whatever the verb was asked to do.
    fs::write(
        f.env
            .home
            .join("catalog/skills/growth-guards/SKILL.md.disabled"),
        "---\nname: growth-guards\ndescription: gates the commits\n---\n",
    )
    .unwrap();
    a_second_project_that_cannot_be_listed(&f);

    let refused = kendex_app::sources::install_bundle(
        &f.env,
        &f.scope,
        "cat".to_owned(),
        "guards".to_owned(),
        false,
    )
    .unwrap_err();

    assert!(
        !f.project.join(".git/hooks/kendex-guards").exists(),
        "the fixture did not actually remove the package"
    );
    assert!(
        refused.contains("growth-guards: running scripts/install-git-hooks --uninstall"),
        "the account was dropped with the failed listing: {refused}"
    );
    assert!(refused.contains("invalid TOML"), "{refused}");
}
