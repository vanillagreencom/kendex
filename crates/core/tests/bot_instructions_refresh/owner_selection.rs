//! Configuration-owner selection through installed declarations, consent,
//! reported ownership and the commit offer. The fixture effect implements
//! the public report protocol without importing either package's grammar.

use super::*;
use std::os::unix::fs::PermissionsExt;

const NEW: &str = "github-repository-settings";
const OLD: &str = "bot-instructions";

#[allow(clippy::unwrap_used)]
fn install(fixture: &Fixture, name: &str, armed: bool) -> PathBuf {
    let package = fixture.root.join(".agents/skills").join(name);
    fs::create_dir_all(package.join("scripts")).unwrap();
    fs::write(
        package.join("SKILL.md"),
        format!(
            "---\nname: {name}\nrepo-effects:\n  summary: Fixture configuration\n  writes: [{name}.md]\n  installer: scripts/effect render\n  checker: scripts/effect check\n---\n"
        ),
    )
    .unwrap();
    fs::write(
        package.join("scripts/effect"),
        format!(
            "#!/bin/sh\nprintf '%s\\n' '{name}' >> calls\ncase \"$1\" in\ncheck) exit 1 ;;\nrender)\n  if [ \"${{2-}}\" = --dry-run ]; then\n    printf 'would write {name}.md\\nwould write region {name}-shared.md\\t## Fixture\\n'\n  else\n    printf 'owned\\n' > {name}.md\n    printf 'wrote {name}.md\\nwrote region {name}-shared.md\\t## Fixture\\n'\n  fi ;;\nesac\n"
        ),
    )
    .unwrap();
    fs::set_permissions(
        package.join("scripts/effect"),
        fs::Permissions::from_mode(0o755),
    )
    .unwrap();
    record_named_install(
        &fixture.env,
        &fixture.root,
        HarnessId::Codex,
        name,
        package.clone(),
    );
    if armed {
        let repo = kendex_core::guard::Repo::at(&fixture.root).unwrap();
        kendex_core::repo_effects::armed::arm(
            kendex_core::repo_effects::armed::record_dir(&repo, false),
            name,
        )
        .unwrap();
    }
    package
}

#[derive(Clone, Copy)]
struct Selection {
    old: bool,
    new: bool,
    armed: bool,
    selected: &'static str,
}

const SELECTIONS: &[Selection] = &[
    Selection {
        old: true,
        new: false,
        armed: true,
        selected: OLD,
    },
    Selection {
        old: false,
        new: true,
        armed: true,
        selected: NEW,
    },
    Selection {
        old: true,
        new: true,
        armed: true,
        selected: NEW,
    },
    Selection {
        old: true,
        new: true,
        armed: false,
        selected: NEW,
    },
];

#[allow(clippy::unwrap_used)]
fn selected_fixture(row: Selection) -> Fixture {
    let fixture = fixture_with_arming("[install]\nharnesses = [\"codex\"]\n", false);
    if row.old {
        install(&fixture, OLD, true);
    } else {
        fs::remove_dir_all(fixture.root.join(CODEX_PACKAGE)).unwrap();
    }
    if row.new {
        install(&fixture, NEW, row.armed);
    }
    git(&fixture.root, &["add", "-A"]);
    fixture
}

/// One table covers the transition states for both automatic entry points.
/// Compiled-source controls remove preference and bypass consent separately;
/// this test must reject each control. The calls file also detects two runs.
#[test]
#[allow(clippy::unwrap_used)]
fn only_the_selected_armed_owner_reports_files_and_regions() {
    for &row in SELECTIONS {
        for write in [true, false] {
            assert_selection(row, write);
        }
    }
}

#[allow(clippy::unwrap_used)]
fn assert_selection(row: Selection, write: bool) {
    let fixture = selected_fixture(row);
    let mut generated = GeneratedPaths::default();
    if write {
        let rendered = bot_instructions::render(&fixture.env, &fixture.scope).unwrap();
        assert_eq!(
            rendered.skipped().map(|skip| skip.declared.name.as_str()),
            (!row.armed).then_some(row.selected),
        );
        rendered.add_to(&mut generated);
    } else {
        bot_instructions::add_to_generated(&fixture.env, &fixture.scope, &mut generated).unwrap();
    }
    let calls = fs::read_to_string(fixture.root.join("calls")).unwrap_or_default();
    if !row.armed {
        assert_eq!(calls, "");
        assert!(generated.whole.is_empty());
        assert!(generated.regions.is_empty());
    } else {
        assert_eq!(calls, format!("{}\n", row.selected));
        assert_eq!(
            generated.whole,
            BTreeSet::from([fixture.root.join(format!("{}.md", row.selected))]),
        );
        assert_eq!(
            generated.regions,
            BTreeSet::from([commit_offer::OwnedRegion::new(
                fixture.root.join(format!("{}-shared.md", row.selected)),
                "## Fixture".to_owned(),
                fixture.root.join(".agents/skills").join(row.selected),
                "scripts/effect render".to_owned(),
            )
            .unwrap()]),
        );
    }
    for name in [OLD, NEW] {
        assert_eq!(
            fixture.root.join(format!("{name}.md")).exists(),
            write && row.armed && row.selected == name,
        );
    }
}

#[test]
#[allow(clippy::unwrap_used)]
fn packages_without_configuration_effects_do_not_gain_automatic_runs() {
    let fixture = selected_fixture(SELECTIONS[0]);
    let plain = install(&fixture, NEW, true);
    fs::write(
        plain.join("SKILL.md"),
        "---\nname: github-repository-settings\n---\n",
    )
    .unwrap();
    install(&fixture, "other-effect", true);
    bot_instructions::render(&fixture.env, &fixture.scope).unwrap();
    assert_eq!(
        fs::read_to_string(fixture.root.join("calls")).unwrap(),
        format!("{OLD}\n")
    );
    assert!(!fixture.root.join("other-effect.md").exists());
}

/// Failed effects and invalid ownership reports cannot grant commit paths.
#[test]
#[allow(clippy::unwrap_used)]
fn selected_owner_failures_keep_write_and_discovery_failed() {
    for body in [
        "printf 'wrote fixture.md\\n'; exit 1\n",
        "printf 'wrote ../outside.md\\nwould write ../outside.md\\n'\n",
        "printf 'wrote region shared.md\\nwould write region shared.md\\n'\n",
    ] {
        for write in [true, false] {
            let fixture = selected_fixture(SELECTIONS[2]);
            fs::write(
                fixture
                    .root
                    .join(".agents/skills")
                    .join(NEW)
                    .join("scripts/effect"),
                format!("#!/bin/sh\nprintf 'ran\\n' > selected-ran\n{body}"),
            )
            .unwrap();
            let mut generated = GeneratedPaths::default();
            let result = if write {
                bot_instructions::render(&fixture.env, &fixture.scope)
                    .map(|paths| paths.add_to(&mut generated))
            } else {
                bot_instructions::add_to_generated(&fixture.env, &fixture.scope, &mut generated)
            };
            assert!(matches!(
                result,
                Err(kendex_core::error::CoreError::BotInstructionsRender { .. })
            ));
            assert!(generated.whole.is_empty());
            assert!(generated.regions.is_empty());
            assert!(!fixture.root.join("calls").exists());
            assert_eq!(
                fs::read(fixture.root.join("selected-ran")).unwrap(),
                b"ran\n"
            );
        }
    }
}

/// The old checker must not hold or run beside the selected owner's check.
#[test]
#[allow(clippy::unwrap_used)]
fn the_commit_offer_checks_only_the_selected_configuration_owner() {
    for &row in SELECTIONS {
        let fixture = selected_fixture(row);
        commit_fixture(&fixture.root);
        let mut generated = GeneratedPaths::default();
        for name in [OLD, NEW] {
            let declaration = fixture
                .root
                .join(".agents/skills")
                .join(name)
                .join("SKILL.md");
            if declaration.exists() {
                let text = fs::read_to_string(&declaration).unwrap();
                fs::write(&declaration, format!("{text}\nchanged\n")).unwrap();
                generated.whole.insert(declaration);
            }
        }
        let scan = offer_scan(&fixture, &generated);
        let held = commit_offer::stale(
            &fixture.env,
            &fixture.scope,
            &scan,
            &generated,
            &scan.carried(),
        )
        .unwrap();
        assert_eq!(
            held.iter()
                .map(|held| held.disclosure.name.as_str())
                .collect::<Vec<_>>(),
            [row.selected]
        );
        assert_eq!(
            held[0].why,
            if row.armed {
                Staleness::OutOfDate(Vec::new())
            } else {
                Staleness::NotSetUp
            }
        );
        assert_eq!(
            fs::read_to_string(fixture.root.join("calls")).unwrap_or_default(),
            if row.armed {
                format!("{}\n", row.selected)
            } else {
                String::new()
            },
        );
    }
}

#[test]
#[allow(clippy::unwrap_used)]
fn linked_worktree_consent_stays_with_the_selected_owner() {
    let fixture = selected_fixture(SELECTIONS[2]);
    commit_fixture(&fixture.root);
    let linked = fixture.root.parent().unwrap().join("linked");
    git(
        &fixture.root,
        &[
            "worktree",
            "add",
            "--quiet",
            "-b",
            "second",
            linked.to_str().unwrap(),
        ],
    );
    let linked = linked.canonicalize().unwrap();
    for name in [OLD, NEW] {
        record_named_install(
            &fixture.env,
            &linked,
            HarnessId::Codex,
            name,
            linked.join(".agents/skills").join(name),
        );
    }
    let rendered = bot_instructions::render(
        &fixture.env,
        &Scope::Project {
            root: linked.clone(),
        },
    )
    .unwrap();
    let skip = rendered.skipped().unwrap();
    assert_eq!(skip.declared.name, NEW);
    assert_eq!(skip.set_up_in.as_ref(), Some(&fixture.root));
    assert!(!linked.join("calls").exists());
}

#[test]
#[allow(clippy::unwrap_used)]
fn a_one_run_licence_uses_the_selected_owner_without_arming_it() {
    let fixture = selected_fixture(SELECTIONS[3]);
    assert_eq!(
        bot_instructions::render_once(&fixture.env, &fixture.scope)
            .unwrap()
            .unwrap()
            .code,
        0
    );
    assert_eq!(
        fs::read_to_string(fixture.root.join("calls")).unwrap(),
        format!("{NEW}\n")
    );
    let selected = kendex_core::engine::installed_declaration(&fixture.env, &fixture.scope, NEW)
        .unwrap()
        .unwrap();
    assert!(!kendex_core::repo_effects::armed_here(&fixture.scope, &selected).unwrap());
}
