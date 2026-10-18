//! The desktop's existing setup action reaches the shared core transfer.

use super::*;

#[test]
#[allow(clippy::unwrap_used)]
fn the_existing_setup_action_moves_the_configuration_owner() {
    let f = fixture();
    let catalog = f.env.home.join("catalog/skills");
    for name in ["bot-instructions", "github-repository-settings"] {
        let package = catalog.join(name);
        fs::create_dir_all(package.join("scripts")).unwrap();
        fs::write(package.join("SKILL.md"), format!(
            "---\nname: {name}\ndescription: fixture configuration\nrepo-effects:\n  summary: fixture configuration\n  writes: [configuration, {name}.effect]\n  installer: scripts/effect install\n  uninstaller: scripts/effect retire\n---\n"
        )).unwrap();
        let script = package.join("scripts/effect");
        fs::write(&script, format!(
            "#!/bin/sh\ncase \"$1\" in\ninstall) printf '%s' '{name}' > configuration; touch {name}.effect ;;\nretire) rm -f configuration {name}.effect ;;\nesac\n"
        )).unwrap();
        fs::set_permissions(script, fs::Permissions::from_mode(0o755)).unwrap();
    }
    install_skills(&f, &["bot-instructions"], None);
    let declaration = |name| {
        kendex_core::engine::installed_declaration(&f.env, &f.scope, name)
            .unwrap()
            .unwrap()
    };
    let previous = declaration("bot-instructions");
    kendex_app::repo_effects::apply(&f.env, &f.scope, &previous).unwrap();
    install_skills(&f, &["github-repository-settings"], None);
    let selected = declaration("github-repository-settings");
    assert!(kendex_core::repo_effects::armed_here(&f.scope, &previous).unwrap());
    assert!(!kendex_core::repo_effects::armed_here(&f.scope, &selected).unwrap());
    assert_eq!(
        fs::read_to_string(f.project.join("configuration")).unwrap(),
        "bot-instructions"
    );

    kendex_app::repo_effects::apply(&f.env, &f.scope, &selected).unwrap();
    assert_eq!(
        fs::read_to_string(f.project.join("configuration")).unwrap(),
        "github-repository-settings"
    );
    assert!(!f.project.join("bot-instructions.effect").exists());
    assert!(
        f.project
            .join("github-repository-settings.effect")
            .is_file()
    );
    assert!(!kendex_core::repo_effects::armed_here(&f.scope, &previous).unwrap());
    assert!(kendex_core::repo_effects::armed_here(&f.scope, &selected).unwrap());
    assert!(previous.root.join("SKILL.md").is_file());
}
