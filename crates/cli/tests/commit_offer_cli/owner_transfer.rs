//! Configuration-owner transfer uses the commit offer's existing setup consent.

use super::*;

const OLD: &str = "bot-instructions";
const NEW: &str = "github-repository-settings";

#[allow(clippy::unwrap_used)]
fn package(project: &Path, name: &str) {
    let package = project.join("catalog/skills").join(name);
    fs::create_dir_all(&package).unwrap();
    fs::write(package.join("SKILL.md"), format!(
        "---\nname: {name}\ndescription: fixture configuration\nrepo-effects:\n  summary: fixture {name} effect\n  writes: ['.github/copilot-instructions.md', '{name}.effect']\n  installer: scripts/effect render\n  uninstaller: scripts/effect retire\n  checker: scripts/effect check\n---\n"
    )).unwrap();
    // A write appends to `../renders-<name>`, beside every checkout the
    // fixtures make, and `../refuse-<name>` makes the write refuse.
    executable(
        &package.join("scripts/effect"),
        &format!(
            "#!/bin/sh\ncase \"$1\" in\ncheck) test \"$(cat .github/copilot-instructions.md)\" = '{name}' ;;\nretire) rm -f .github/copilot-instructions.md {name}.effect ;;\nrender)\n if [ \"${{2-}}\" = --discover ]; then\n  printf 'would write .github/copilot-instructions.md\\nwould write {name}.effect\\n'\n else\n  echo render >> ../renders-{name}\n  if [ -f ../refuse-{name} ]; then echo 'fixture refusal' >&2; exit 1; fi\n  mkdir -p .github\n  printf '%s' '{name}' > .github/copilot-instructions.md\n  printf '%s' '{name}' > {name}.effect\n  printf 'wrote .github/copilot-instructions.md\\nwrote {name}.effect\\n'\n fi ;;\nesac\n"
        ),
    );
}

/// How many times `name`'s installer wrote beside `checkout`.
#[allow(clippy::unwrap_used)]
fn renders(checkout: &Path, name: &str) -> usize {
    fs::read_to_string(checkout.parent().unwrap().join(format!("renders-{name}")))
        .map_or(0, |text| text.lines().count())
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

/// Where the action that brings a package requiring the new owner runs,
/// and what it is given.
#[derive(Clone, Copy, Debug)]
enum Arrival {
    /// No `--allow-repo-effects`: the armed old owner keeps the files.
    Declined,
    /// `--allow-repo-effects`: the setup moves the files before the offer.
    Consented,
    /// The same, in a linked work tree that carries neither record.
    ConsentedLinked,
    /// The same, with neither owner installed before the add, which brings
    /// both: only the new owner is set up, so the old one's installer,
    /// which refuses here, never runs and only one record stands.
    ConsentedFresh,
    /// The same, beside a second package whose effect is not set up: the
    /// offer sets that one up under the add's yes and commits.
    ConsentedBeside,
    /// The same, with the new owner's installer refusing.
    Refused,
    /// `apply --allow-repo-effects` of the requirer written into
    /// `kendex.toml` by hand: the same setup before the offer as an add's.
    ConsentedApply,
    /// The same apply, with the new owner's installer refusing.
    RefusedApply,
    /// No owner installed before the add, which brings the new one alone,
    /// so it holds the commit, and its installer refuses: the offer runs
    /// that setup no second time and commits nothing.
    RefusedOwner,
}

impl Arrival {
    fn applied(self) -> bool {
        matches!(self, Arrival::ConsentedApply | Arrival::RefusedApply)
    }

    /// Neither owner is installed before the action.
    fn fresh(self) -> bool {
        matches!(self, Arrival::ConsentedFresh | Arrival::RefusedOwner)
    }

    /// The new owner's installer refuses.
    fn refused(self) -> bool {
        matches!(
            self,
            Arrival::Refused | Arrival::RefusedApply | Arrival::RefusedOwner
        )
    }

    /// The new owner is set up and renders.
    fn moved(self) -> bool {
        matches!(
            self,
            Arrival::Consented
                | Arrival::ConsentedLinked
                | Arrival::ConsentedFresh
                | Arrival::ConsentedBeside
                | Arrival::ConsentedApply
        )
    }

    /// The armed old owner keeps the files.
    fn kept(self) -> bool {
        matches!(
            self,
            Arrival::Declined | Arrival::Refused | Arrival::RefusedApply
        )
    }
}

/// The KEN-2358 reproduction: an armed old owner, then an add of a package
/// that requires the new one. Without the setup's say-so the old owner
/// keeps rendering, its check still fails drift under `verify`, and a
/// refresh names the pending setup. With `--allow-repo-effects` and a
/// commit choice, the setup runs once, disclosed once, before the offer,
/// so the new owner's render is in the action's own commit, in a linked
/// work tree too, with no owner installed before, beside another held
/// package, and from a declaration written by hand and applied. A refused
/// setup leaves the old owner and still closes the action with its ledger,
/// and an add with its registration; where the refused package holds the
/// commit, the offer does not run it again. Every row that commits commits
/// what it installed and what the owner it leaves rendered.
#[test]
#[allow(clippy::unwrap_used)]
fn a_dependency_only_arrival_leaves_the_armed_owner_until_its_setup() {
    for arrival in [
        Arrival::Declined,
        Arrival::Consented,
        Arrival::ConsentedLinked,
        Arrival::ConsentedFresh,
        Arrival::ConsentedBeside,
        Arrival::Refused,
        Arrival::ConsentedApply,
        Arrival::RefusedApply,
        Arrival::RefusedOwner,
    ] {
        assert_arrival(arrival);
    }
}

#[allow(clippy::unwrap_used)]
fn assert_arrival(arrival: Arrival) {
    const PENDING: &str = "github-repository-settings: installed as a dependency;";
    let tmp = tempfile::tempdir().unwrap();
    let home = rooted(&tmp);
    let main = unarmed_consumer(&tmp);
    package(&main, OLD);
    git(&main, &["add", "-A"]);
    git(&main, &["commit", "-q", "-m", "old installer"]);
    let initial = match arrival.fresh() {
        true => kendex(&home, &main, &["remove", OLD, "--commit"]),
        false => kendex(
            &home,
            &main,
            &["apply", "--yes", "--commit", "--allow-repo-effects"],
        ),
    };
    assert!(initial.status.success(), "{}", said(&initial));
    assert_eq!(armed(&main, OLD), !arrival.fresh());
    assert_eq!(
        main.join(".claude/skills/bot-instructions/SKILL.md")
            .is_file(),
        !arrival.fresh()
    );

    package(&main, NEW);
    let required = match arrival {
        Arrival::ConsentedFresh => format!("{NEW}, {OLD}"),
        Arrival::ConsentedBeside => {
            let other = main.join("catalog/skills/workfx");
            fs::create_dir_all(&other).unwrap();
            fs::write(
                other.join("SKILL.md"),
                "---\nname: workfx\ndescription: fixture work tree effect\nrepo-effects:\n  summary: fixture workfx effect\n  writes: ['workfx.effect']\n  installer: scripts/effect\n---\n",
            )
            .unwrap();
            executable(
                &other.join("scripts/effect"),
                "#!/bin/sh\nprintf x > workfx.effect\necho 'wrote workfx.effect'\n",
            );
            format!("{NEW}, workfx")
        }
        Arrival::Declined
        | Arrival::Consented
        | Arrival::ConsentedLinked
        | Arrival::Refused
        | Arrival::ConsentedApply
        | Arrival::RefusedApply
        | Arrival::RefusedOwner => NEW.to_owned(),
    };
    let requirer = main.join("catalog/skills/requirer");
    fs::create_dir_all(&requirer).unwrap();
    fs::write(
        requirer.join("SKILL.md"),
        format!("---\nname: requirer\ndescription: fixture requirer\ndependencies:\n  required: [{required}]\n---\n"),
    )
    .unwrap();
    if arrival.applied() {
        let manifest = main.join("kendex.toml");
        let mut text = fs::read_to_string(&manifest).unwrap();
        text.push_str("\n[skills.requirer]\nsource = \"cat\"\n");
        fs::write(&manifest, text).unwrap();
    }
    git(&main, &["add", "-A"]);
    git(&main, &["commit", "-q", "-m", "requirer"]);
    let project = match arrival {
        Arrival::ConsentedLinked => {
            let linked = main.parent().unwrap().join("linked");
            git(
                &main,
                &[
                    "worktree",
                    "add",
                    "-q",
                    "-b",
                    "linked",
                    linked.to_str().unwrap(),
                ],
            );
            linked
        }
        Arrival::Declined
        | Arrival::Consented
        | Arrival::ConsentedFresh
        | Arrival::ConsentedBeside
        | Arrival::Refused
        | Arrival::ConsentedApply
        | Arrival::RefusedApply
        | Arrival::RefusedOwner => main.clone(),
    };
    let refusing = if matches!(arrival, Arrival::ConsentedFresh) {
        Some(OLD)
    } else if arrival.refused() {
        Some(NEW)
    } else {
        None
    };
    if let Some(name) = refusing {
        fs::write(project.parent().unwrap().join(format!("refuse-{name}")), "").unwrap();
    }
    let rendered_before = renders(&project, NEW);
    let old_rendered_before = renders(&project, OLD);
    let mut args = match arrival.applied() {
        true => vec!["apply", "--yes", "--commit"],
        false => vec![
            "add",
            "--yes",
            "--throwaway",
            "--commit",
            "catalog",
            "--skill",
            "requirer",
        ],
    };
    let consent = !matches!(arrival, Arrival::Declined);
    if consent {
        args.push("--allow-repo-effects");
    }
    let output = kendex(&home, &project, &args);
    let text = said(&output);
    let moved = arrival.moved();
    assert_eq!(
        output.status.code(),
        Some(if arrival.refused() { 1 } else { 0 }),
        "{arrival:?}\n{text}"
    );
    let owner = match (moved, arrival.kept()) {
        (true, _) => Some(NEW),
        (false, true) => Some(OLD),
        (false, false) => None,
    };
    assert_eq!(
        fs::read_to_string(project.join(".github/copilot-instructions.md")).ok(),
        owner.map(str::to_owned),
        "{arrival:?}\n{text}"
    );
    assert_eq!(armed(&project, NEW), moved, "{arrival:?}\n{text}");
    assert_eq!(armed(&project, OLD), arrival.kept(), "{arrival:?}\n{text}");
    assert_eq!(
        text.contains(PENDING),
        arrival.kept(),
        "{arrival:?}\n{text}"
    );
    // The package's own summary is in every disclosure block, so it counts
    // the blocks the action printed: one, before the setup or the decline.
    assert_eq!(
        text.matches(&format!("fixture {NEW} effect")).count(),
        1,
        "{arrival:?}\n{text}"
    );
    // One setup, then the action's own render through the owner it leaves;
    // a refused setup is not run again.
    let writes = match (moved, arrival.refused()) {
        (true, _) => 2,
        (false, true) => 1,
        (false, false) => 0,
    };
    assert_eq!(
        renders(&project, NEW) - rendered_before,
        writes,
        "{arrival:?}\n{text}"
    );
    // A predecessor that was never armed here is never set up.
    if arrival.fresh() {
        assert_eq!(
            renders(&project, OLD),
            old_rendered_before,
            "{arrival:?}\n{text}"
        );
    }
    if let Arrival::RefusedOwner = arrival {
        assert_eq!(head_subject(&project), "requirer", "{text}");
    } else {
        assert_committed(arrival, &project, &text);
    }
    if arrival.refused() {
        assert!(text.contains("fixture refusal"), "{text}");
        // The closing ledger line is the action's result for its scope.
        let verb = if arrival.applied() {
            "applied"
        } else {
            "added"
        };
        let ledger = format!("{}: {verb} ", project.display());
        assert!(text.lines().any(|line| line.starts_with(&ledger)), "{text}");
        // An apply run inside the project registers nothing.
        if !arrival.applied() {
            assert!(
                kendex_core::settings::load(&kendex_core::env::Env::host_rooted(&home))
                    .unwrap()
                    .projects
                    .contains(&project),
                "{text}"
            );
        }
    }
    if !matches!(arrival, Arrival::Declined) {
        return;
    }

    fs::write(project.join(".github/copilot-instructions.md"), "drift").unwrap();
    let verified = kendex(&home, &project, &["verify", "--scope", "project"]);
    assert_eq!(verified.status.code(), Some(1), "{}", said(&verified));

    let refreshed = kendex(
        &home,
        &project,
        &["refresh", "--yes", "--scope", "project", "--leave"],
    );
    let text = said(&refreshed);
    assert!(refreshed.status.success(), "{text}");
    assert!(text.contains(PENDING), "{text}");
    assert!(!armed(&project, NEW), "{text}");
}

/// What the action's own commit carries, and that what it installed and
/// what the owner it leaves rendered are all in it.
#[allow(clippy::unwrap_used)]
fn assert_committed(arrival: Arrival, project: &Path, text: &str) {
    let committed = git(project, &["show", "--name-only", "--format=", "HEAD"]);
    let carried = |path: &str| committed.lines().any(|line| line == path);
    // An add writes the declaration; an apply reads the one committed.
    assert_eq!(
        carried("kendex.toml"),
        !arrival.applied(),
        "{arrival:?}\n{committed}\n{text}"
    );
    assert!(
        carried(".claude/skills/requirer/SKILL.md"),
        "{arrival:?}\n{committed}\n{text}"
    );
    assert_eq!(
        carried(&format!("{NEW}.effect")),
        arrival.moved(),
        "{arrival:?}\n{committed}\n{text}"
    );
    assert_eq!(
        carried(".claude/skills/workfx/SKILL.md"),
        matches!(arrival, Arrival::ConsentedBeside),
        "{arrival:?}\n{committed}\n{text}"
    );
    let successor = format!("{NEW}.effect");
    assert_eq!(
        git(
            project,
            &[
                "status",
                "--porcelain",
                "--",
                ".claude",
                ".github",
                ".kendex-lock.json",
                ".kendex-generated.json",
                &successor,
            ]
        ),
        "",
        "{arrival:?}\n{committed}\n{text}"
    );
}
