//! What a package's own output is allowed to do to the window.
//!
//! Both halves of `repo_effects` hand a third party's bytes to a surface
//! that renders them without attribution: an installer's last stdout
//! line becomes a toast the moment somebody authorizes a disclosure, and
//! a departing package's lines become the account of what its removal
//! ran. A bidi override or a line phrased in kendex's voice reads as
//! kendex talking in either. Both directions are held here together,
//! because one door hardened is a rule that holds only where it was
//! last reviewed.
#![cfg(unix)]

#[path = "repo_effects/fixture.rs"]
mod fixture;
use fixture::*;

/// A departing package's own output reaches the window escaped.
///
/// The lines land in a toast carrying no attribution, so a package that
/// writes a bidi override or a line phrased in kendex's voice would be
/// read as kendex talking. The terminal escapes them; this proves the
/// window does too, which is what makes the three places claiming both
/// surfaces show the same lines true.
#[test]
#[allow(clippy::unwrap_used)]
fn a_departing_package_s_output_reaches_the_window_escaped() {
    let f = fixture();
    let scripts = f.project.join(".agents/skills/loud/scripts");
    let catalog_scripts = f.env.home.join("catalog/skills/loud/scripts");
    fs::create_dir_all(&catalog_scripts).unwrap();
    fs::write(
        f.env.home.join("catalog/skills/loud/SKILL.md"),
        "---\nname: loud\ndescription: writes a deceptive line\n\
         repo-effects:\n  summary: \"says something on the way out\"\n  \
         uninstaller: \"scripts/out\"\n---\nBody.\n",
    )
    .unwrap();
    // U+202E, the override that reverses everything printed after it.
    fs::write(
        catalog_scripts.join("out"),
        "#!/bin/sh\nprintf 'loud: \\342\\200\\256done\\n'\n",
    )
    .unwrap();
    fs::set_permissions(
        catalog_scripts.join("out"),
        fs::Permissions::from_mode(0o755),
    )
    .unwrap();
    install_skills(&f, &["loud"], None);
    assert!(scripts.join("out").is_file(), "the fixture did not install");

    let view = kendex_app::audit::remove(&f.env, &f.scope, ItemKind::Skill, "loud")
        .unwrap_or_else(|error| panic!("remove: {error}"));

    let said = view.undone.join("\n");
    assert!(said.contains("loud: running"), "{said:?}");
    assert!(
        !said.contains('\u{202E}'),
        "the override reached the window raw: {said:?}"
    );
    assert!(said.contains("\\u{202e}"), "{said:?}");
}
/// The arriving half of this module escapes what a package says, like the
/// departing half.
///
/// The window renders an installer's last stdout line as a bare toast the
/// moment somebody authorizes a disclosure, so a bidi override or a line
/// phrased in kendex's voice reads there as kendex's verdict on the thing
/// they just approved. Both directions are held by a fixture rather than
/// by whichever one was last reviewed.
#[test]
#[allow(clippy::unwrap_used)]
fn an_installer_s_output_reaches_the_window_escaped() {
    let f = fixture();
    let catalog = f.env.home.join("catalog");
    let scripts = catalog.join("skills/sneaky/scripts");
    fs::create_dir_all(&scripts).unwrap();
    fs::write(
        catalog.join("skills/sneaky/SKILL.md"),
        "---\nname: sneaky\ndescription: writes a deceptive line\n\
         repo-effects:\n  summary: \"arms something\"\n  \
         installer: \"scripts/arm\"\n---\nBody.\n",
    )
    .unwrap();
    // U+202E on stdout, and again on the channel a failure would use.
    fs::write(
        scripts.join("arm"),
        "#!/bin/sh\nprintf 'sneaky: \\342\\200\\256armed\\n'\n\
         printf 'sneaky: \\342\\200\\256warned\\n' >&2\n",
    )
    .unwrap();
    fs::set_permissions(scripts.join("arm"), fs::Permissions::from_mode(0o755)).unwrap();
    let installed = install_skills(&f, &["sneaky"], None);
    let [offer] = installed.repo_effects.shown.as_slice() else {
        panic!("one offer: {:?}", installed.repo_effects);
    };

    let said = kendex_app::repo_effects::apply(&f.env, &f.scope, &offer.declared).unwrap();

    let spoke = format!("{:?}{:?}", said.stdout, said.stderr);
    assert!(
        !said
            .stdout
            .iter()
            .chain(&said.stderr)
            .any(|line| line.contains('\u{202E}')),
        "the override reached the window raw: {spoke}"
    );
    assert!(spoke.contains("\\u{202e}"), "{spoke}");

    // And the failure branch, which folds the same two streams into the
    // error a person reads: an installer that exits nonzero still gets
    // its words shown rather than rendered.
    let refusing = f.project.join(".agents/skills/sneaky/scripts/arm");
    fs::write(
        &refusing,
        "#!/bin/sh\nprintf 'sneaky: \\342\\200\\256refused\\n' >&2\nexit 1\n",
    )
    .unwrap();
    fs::set_permissions(&refusing, fs::Permissions::from_mode(0o755)).unwrap();

    let failed = kendex_app::repo_effects::apply(&f.env, &f.scope, &offer.declared).unwrap_err();

    assert!(
        !failed.contains('\u{202E}'),
        "the override reached the window raw: {failed}"
    );
    assert!(failed.contains("\\u{202e}refused"), "{failed}");
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
