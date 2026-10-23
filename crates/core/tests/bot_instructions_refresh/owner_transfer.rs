//! Explicit setup transfers one locally armed configuration effect, keeping
//! the predecessor installed and compensating a partially failed installer.

use super::*;
use std::os::unix::fs::PermissionsExt;

const OLD: &str = "bot-instructions";
const NEW: &str = "github-repository-settings";

#[allow(clippy::unwrap_used)]
fn install(f: &Fixture, name: &str) -> kendex_core::repo_effects::DeclaredEffects {
    let package = f.root.join(".agents/skills").join(name);
    fs::create_dir_all(package.join("scripts")).unwrap();
    fs::write(
        package.join("SKILL.md"),
        format!("---\nname: {name}\nrepo-effects:\n  summary: Fixture configuration\n  writes: [configuration, {name}.effect]\n  installer: scripts/effect install\n  uninstaller: scripts/effect retire\n  checker: scripts/effect check\n---\n"),
    ).unwrap();
    let script = package.join("scripts/effect");
    fs::write(&script, format!(
        "#!/bin/sh\ncase \"$1\" in\ninstall)\n printf '%s' '{name}' > configuration\n printf '%s' '{name}' > {name}.effect\n if [ '{name}' = '{NEW}' ] && [ -f fail-install ]; then exit 7; fi ;;\nretire) rm -f configuration {name}.effect ;;\ncheck) test \"$(cat configuration)\" = '{name}' ;;\nesac\n"
    )).unwrap();
    fs::set_permissions(&script, fs::Permissions::from_mode(0o755)).unwrap();
    record_named_install(&f.env, &f.root, HarnessId::Codex, name, package);
    kendex_core::engine::installed_declaration(&f.env, &f.scope, name)
        .unwrap()
        .unwrap()
}

#[allow(clippy::unwrap_used)]
fn assert_owner(f: &Fixture, name: &str, armed: bool) {
    let declared = kendex_core::engine::installed_declaration(&f.env, &f.scope, name)
        .unwrap()
        .unwrap();
    assert_eq!(
        kendex_core::repo_effects::armed_here(&f.scope, &declared).unwrap(),
        armed,
        "{name}"
    );
    assert!(declared.root.join("SKILL.md").is_file());
    assert!(
        !kendex_core::repo_effects::recorded_roots(&f.env, &f.scope, name)
            .unwrap()
            .is_empty()
    );
}

/// Both rows start by actually arming A, then install B alongside it. The
/// failed B row writes both shared and B-only files before exiting nonzero.
#[test]
#[allow(clippy::unwrap_used)]
fn setup_moves_the_effect_and_record_to_the_selected_owner() {
    let _diagnostic = crate::diagnostic::Span::begin(concat!(
        module_path!(),
        "::setup_moves_the_effect_and_record_to_the_selected_owner"
    ));
    assert_transfer(false);
}

#[test]
#[allow(clippy::unwrap_used)]
fn a_failed_transfer_restores_the_previous_effect_and_record() {
    let _diagnostic = crate::diagnostic::Span::begin(concat!(
        module_path!(),
        "::a_failed_transfer_restores_the_previous_effect_and_record"
    ));
    assert_transfer(true);
}

#[allow(clippy::unwrap_used)]
fn assert_transfer(fail: bool) {
    let f = fixture_with_arming("[install]\nharnesses = [\"codex\"]\n", false);
    let previous = install(&f, OLD);
    kendex_core::repo_effects::setup::apply(&f.env, &f.scope, &previous).unwrap();
    let selected = install(&f, NEW);
    if fail {
        fs::write(f.root.join("fail-install"), "").unwrap();
    }
    let result = kendex_core::repo_effects::setup::apply(&f.env, &f.scope, &selected);
    let owner = if fail { OLD } else { NEW };
    assert_eq!(
        fs::read_to_string(f.root.join("configuration")).unwrap(),
        owner
    );
    assert_eq!(f.root.join(format!("{OLD}.effect")).exists(), fail);
    assert_eq!(f.root.join(format!("{NEW}.effect")).exists(), !fail);
    assert_owner(&f, OLD, fail);
    assert_owner(&f, NEW, !fail);
    if fail {
        let error = result.unwrap_err();
        let kendex_core::repo_effects::ArmError::Transfer {
            previous,
            selected,
            step,
            cause,
            recovery,
        } = error
        else {
            panic!("expected transfer failure");
        };
        assert_eq!(previous, OLD);
        assert_eq!(selected, NEW);
        assert_eq!(
            step,
            kendex_core::repo_effects::setup::TransferStep::Install
        );
        assert!(matches!(
            *cause,
            kendex_core::repo_effects::ArmError::Failed { code: 7, .. }
        ));
        assert!(recovery.is_empty());
    } else {
        result.unwrap();
    }
}
