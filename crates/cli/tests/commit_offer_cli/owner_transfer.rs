//! Configuration-owner transfer uses the commit offer's existing setup consent.

use super::*;

const OLD: &str = "bot-instructions";
const NEW: &str = "github-repository-settings";

#[allow(clippy::unwrap_used)]
fn package(project: &Path, name: &str) {
    let package = project.join("catalog/skills").join(name);
    fs::create_dir_all(&package).unwrap();
    fs::write(package.join("SKILL.md"), format!(
        "---\nname: {name}\ndescription: fixture configuration\nrepo-effects:\n  summary: fixture configuration\n  writes: ['.github/copilot-instructions.md', '{name}.effect']\n  installer: scripts/effect render\n  uninstaller: scripts/effect retire\n  checker: scripts/effect check\n---\n"
    )).unwrap();
    executable(
        &package.join("scripts/effect"),
        &format!(
            "#!/bin/sh\ncase \"$1\" in\ncheck) test \"$(cat .github/copilot-instructions.md)\" = '{name}' ;;\nretire) rm -f .github/copilot-instructions.md {name}.effect ;;\nrender)\n if [ \"${{2-}}\" = --dry-run ]; then\n  printf 'would write .github/copilot-instructions.md\\nwould write {name}.effect\\n'\n else\n  mkdir -p .github\n  printf '%s' '{name}' > .github/copilot-instructions.md\n  printf '%s' '{name}' > {name}.effect\n  printf 'wrote .github/copilot-instructions.md\\nwrote {name}.effect\\n'\n fi ;;\nesac\n"
        ),
    );
}

#[allow(clippy::unwrap_used)]
fn armed(project: &Path, name: &str) -> bool {
    let repo = kendex_core::guard::Repo::at(project).unwrap();
    kendex_core::repo_effects::armed::recorded(
        kendex_core::repo_effects::armed::record_dir(&repo, false),
        name,
    )
    .unwrap()
}

#[test]
#[allow(clippy::unwrap_used)]
fn existing_setup_consent_transfers_the_configuration_effect() {
    for consent in [false, true] {
        let tmp = tempfile::tempdir().unwrap();
        let home = rooted(&tmp);
        let project = unarmed_consumer(&tmp);
        package(&project, OLD);
        git(&project, &["add", "-A"]);
        git(&project, &["commit", "-q", "-m", "old installer"]);
        let initial = kendex(
            &home,
            &project,
            &["apply", "--yes", "--commit", "--allow-repo-effects"],
        );
        assert!(initial.status.success(), "{}", said(&initial));
        assert!(armed(&project, OLD));

        package(&project, NEW);
        let manifest = project.join("kendex.toml");
        let mut text = fs::read_to_string(&manifest).unwrap();
        text.push_str("\n[skills.github-repository-settings]\nsource = \"cat\"\n");
        fs::write(&manifest, text).unwrap();
        git(&project, &["add", "-A"]);
        git(&project, &["commit", "-q", "-m", "select new owner"]);
        let mut args = vec!["apply", "--yes", "--commit"];
        if consent {
            args.push("--allow-repo-effects");
        }
        let output = kendex(&home, &project, &args);
        assert_eq!(
            output.status.code(),
            Some(if consent { 0 } else { 1 }),
            "{}",
            said(&output)
        );
        assert_eq!(
            fs::read_to_string(project.join(".github/copilot-instructions.md")).unwrap(),
            if consent { NEW } else { OLD }
        );
        assert_eq!(project.join(format!("{OLD}.effect")).exists(), !consent);
        assert_eq!(project.join(format!("{NEW}.effect")).exists(), consent);
        assert_eq!(armed(&project, OLD), !consent);
        assert_eq!(armed(&project, NEW), consent);
        assert!(
            project
                .join(".claude/skills/bot-instructions/SKILL.md")
                .is_file()
        );
    }
}
