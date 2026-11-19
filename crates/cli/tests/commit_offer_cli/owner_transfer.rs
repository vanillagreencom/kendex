//! Configuration-owner transfer uses the commit offer's existing setup consent.

use super::*;

const OLD: &str = "bot-instructions";
const NEW: &str = "github-repository-settings";

/// `configured_by` names the manifest table the package renders from, as
/// both shipped configuration packages declare `bot-instructions`.
#[allow(clippy::unwrap_used)]
fn package(project: &Path, name: &str, configured_by: Option<&str>) {
    let package = project.join("catalog/skills").join(name);
    fs::create_dir_all(&package).unwrap();
    let configured_by =
        configured_by.map_or(String::new(), |table| format!("  configured-by: {table}\n"));
    fs::write(package.join("SKILL.md"), format!(
        "---\nname: {name}\ndescription: fixture configuration\nrepo-effects:\n{configured_by}  summary: fixture {name} effect\n  writes: ['.github/copilot-instructions.md', '{name}.effect']\n  installer: scripts/effect render\n  uninstaller: scripts/effect retire\n  checker: scripts/effect check\n---\n"
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
        package(&project, OLD, None);
        git(&project, &["add", "-A"]);
        git(&project, &["commit", "-q", "-m", "old installer"]);
        let initial = kendex(
            &home,
            &project,
            &["apply", "--yes", "--commit", "--allow-repo-effects"],
        );
        assert!(initial.status.success(), "{}", said(&initial));
        assert!(armed(&project, OLD));

        package(&project, NEW, None);
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
    /// No `--allow-repo-effects`: the armed old owner keeps the files. The
    /// action's only consent for the new owner's setup comes after the
    /// offer, at a terminal, or is not given, as here with nobody there, so
    /// the offer commits nothing and names that setup. A later action that
    /// did not install the new owner commits as before.
    Declined,
    /// The same, from the requirer written into `kendex.toml` by hand and
    /// applied.
    DeclinedApply,
    /// The same add at a terminal with no commit choice, saying yes to the
    /// setup the walkthrough asks for after the offer: the offer sets
    /// nothing up and commits nothing, and the setup runs once.
    DeclinedAtTerminal,
    /// The same add with `--commit` at a terminal in a linked work tree
    /// that carries neither record, saying yes to the old owner's setup
    /// beside the main checkout's and then to the new owner's in the
    /// walkthrough: the old owner armed before the offer still leaves the
    /// new one's setup to the walkthrough, so the offer commits nothing.
    LinkedAtTerminal,
    /// The same add at a terminal with no commit choice and neither owner
    /// installed before, saying yes to the walkthrough's setup of both:
    /// the old owner not set up here is not offered a setup that would let
    /// the offer commit before the new owner's setup.
    FreshAtTerminal,
    /// The `Declined` add where the new owner names a configuring table
    /// the manifest lacks: its setup would render nothing, so the offer
    /// commits.
    Unconfigured,
    /// An apply with `--commit` at a terminal of the requirer of both
    /// owners, neither installed before, each naming a configuring table
    /// that only the working tree's manifest carries, saying yes to the
    /// walkthrough's setup of both: that setup reads the table the commit
    /// leaves out, so the offer commits nothing.
    TableOnDiskAtTerminal,
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
        matches!(
            self,
            Arrival::DeclinedApply
                | Arrival::ConsentedApply
                | Arrival::RefusedApply
                | Arrival::TableOnDiskAtTerminal
        )
    }

    /// Run with `--commit` and without `--allow-repo-effects`, with nobody
    /// at a terminal, and the offer holds the commit.
    fn declined(self) -> bool {
        matches!(self, Arrival::Declined | Arrival::DeclinedApply)
    }

    fn at_terminal(self) -> bool {
        matches!(
            self,
            Arrival::DeclinedAtTerminal
                | Arrival::LinkedAtTerminal
                | Arrival::FreshAtTerminal
                | Arrival::TableOnDiskAtTerminal
        )
    }

    /// Run with `--commit`.
    fn commit_flag(self) -> bool {
        !matches!(self, Arrival::DeclinedAtTerminal | Arrival::FreshAtTerminal)
    }

    /// Run with `--allow-repo-effects`.
    fn allowed(self) -> bool {
        !self.declined() && !self.at_terminal() && !matches!(self, Arrival::Unconfigured)
    }

    /// The offer refuses the commit `--commit` chose, which exits 1.
    fn refuses_commit(self) -> bool {
        self.declined()
            || matches!(
                self,
                Arrival::LinkedAtTerminal | Arrival::TableOnDiskAtTerminal
            )
    }

    /// The action runs in a linked work tree of the main checkout.
    fn linked(self) -> bool {
        matches!(self, Arrival::ConsentedLinked | Arrival::LinkedAtTerminal)
    }

    /// The manifest table the new owner renders from.
    fn configured_by(self) -> Option<&'static str> {
        matches!(self, Arrival::Unconfigured | Arrival::TableOnDiskAtTerminal).then_some(OLD)
    }

    /// The manifest table the old owner renders from.
    fn old_configured_by(self) -> Option<&'static str> {
        matches!(self, Arrival::TableOnDiskAtTerminal).then_some(OLD)
    }

    /// The questions asked at the terminal, in order, and the answers.
    fn steps(self) -> Vec<(String, &'static str)> {
        let walkthrough = (format!("make {NEW}'s repository changes?"), "y");
        match self {
            Arrival::DeclinedAtTerminal => vec![walkthrough],
            Arrival::LinkedAtTerminal => vec![
                (format!("set {OLD} up in this work tree too?"), "y"),
                walkthrough,
            ],
            Arrival::FreshAtTerminal | Arrival::TableOnDiskAtTerminal => {
                vec![("make the repository changes of 2 packages?".to_owned(), "y")]
            }
            Arrival::Declined
            | Arrival::DeclinedApply
            | Arrival::Consented
            | Arrival::ConsentedLinked
            | Arrival::ConsentedFresh
            | Arrival::ConsentedBeside
            | Arrival::Refused
            | Arrival::ConsentedApply
            | Arrival::RefusedApply
            | Arrival::RefusedOwner
            | Arrival::Unconfigured => Vec::new(),
        }
    }

    /// The action's offer commits.
    fn commits(self) -> bool {
        !self.declined() && !self.at_terminal() && !matches!(self, Arrival::RefusedOwner)
    }

    /// Neither owner is installed before the action.
    fn fresh(self) -> bool {
        matches!(
            self,
            Arrival::ConsentedFresh
                | Arrival::RefusedOwner
                | Arrival::FreshAtTerminal
                | Arrival::TableOnDiskAtTerminal
        )
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
                | Arrival::DeclinedAtTerminal
                | Arrival::LinkedAtTerminal
                | Arrival::FreshAtTerminal
                | Arrival::TableOnDiskAtTerminal
        )
    }

    /// The armed old owner keeps the files.
    fn kept(self) -> bool {
        self.declined()
            || matches!(
                self,
                Arrival::Refused | Arrival::RefusedApply | Arrival::Unconfigured
            )
    }

    /// The old owner's render names the new owner's pending setup.
    fn names_pending(self) -> bool {
        self.kept() || matches!(self, Arrival::DeclinedAtTerminal)
    }
}

/// The KEN-2358 reproduction: an armed old owner, then an add of a package
/// that requires the new one. Without the setup's say-so the old owner
/// keeps rendering, the commit is held on the setup, its check still fails
/// drift under `verify`, a refresh names the pending setup, and a later
/// apply commits. At a terminal the setup the walkthrough asks for runs
/// once, after an offer that set nothing up and committed nothing, in a
/// linked work tree whose old owner was set up beside the main checkout's
/// before the offer, and with no owner installed before too. A new owner
/// with no configuring table in the manifest holds nothing, so the offer
/// commits. With `--allow-repo-effects`
/// and a commit choice, the setup runs once, disclosed once, before the offer,
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
        Arrival::DeclinedApply,
        Arrival::DeclinedAtTerminal,
        Arrival::LinkedAtTerminal,
        Arrival::FreshAtTerminal,
        Arrival::Unconfigured,
        Arrival::TableOnDiskAtTerminal,
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
    package(&main, OLD, arrival.old_configured_by());
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

    package(&main, NEW, arrival.configured_by());
    let required = match arrival {
        Arrival::ConsentedFresh | Arrival::FreshAtTerminal | Arrival::TableOnDiskAtTerminal => {
            format!("{NEW}, {OLD}")
        }
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
        | Arrival::DeclinedApply
        | Arrival::DeclinedAtTerminal
        | Arrival::LinkedAtTerminal
        | Arrival::Unconfigured
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
    if matches!(arrival, Arrival::TableOnDiskAtTerminal) {
        let manifest = main.join("kendex.toml");
        let mut text = fs::read_to_string(&manifest).unwrap();
        text.push_str("\n[bot-instructions]\nschema = 1\n");
        fs::write(&manifest, text).unwrap();
    }
    let project = match arrival.linked() {
        true => {
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
        false => main.clone(),
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
        true => vec!["apply", "--yes"],
        false => vec![
            "add",
            "--yes",
            "--throwaway",
            "catalog",
            "--skill",
            "requirer",
        ],
    };
    if arrival.commit_flag() {
        args.push("--commit");
    }
    if arrival.allowed() {
        args.push("--allow-repo-effects");
    }
    let output = match arrival.at_terminal() {
        true => {
            let mut command = kendex_command(&home, &project, &args);
            command.env("KENDEX_UI", "plain");
            let steps = arrival.steps();
            let steps: Vec<(&str, &str)> = steps
                .iter()
                .map(|(question, answer)| (question.as_str(), *answer))
                .collect();
            crate::pty::conversation(command, &steps, crate::pty::Stderr::Terminal)
        }
        false => kendex(&home, &project, &args),
    };
    let text = said(&output);
    let moved = arrival.moved();
    assert_eq!(
        output.status.code(),
        Some(if arrival.refused() || arrival.refuses_commit() {
            1
        } else {
            0
        }),
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
        arrival.names_pending(),
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
    // a refused setup is not run again, and a setup after the offer is the
    // action's last write.
    let writes = if arrival.at_terminal() || arrival.refused() {
        1
    } else if moved {
        2
    } else {
        0
    };
    assert_eq!(
        renders(&project, NEW) - rendered_before,
        writes,
        "{arrival:?}\n{text}"
    );
    // A predecessor that was never armed here is never set up before the
    // offer. The walkthrough after it asks for every effect the add brings.
    if arrival.fresh() && !arrival.at_terminal() {
        assert_eq!(
            renders(&project, OLD),
            old_rendered_before,
            "{arrival:?}\n{text}"
        );
    }
    match arrival.commits() {
        true => assert_committed(arrival, &project, &text),
        false => assert_eq!(head_subject(&project), "requirer", "{arrival:?}\n{text}"),
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

    // A later apply did not install the new owner, so nothing holds its
    // commit over that setup: the old owner's render of a drifted file is
    // committed.
    git(&project, &["add", "-A"]);
    git(&project, &["commit", "-q", "-m", "declined"]);
    fs::write(project.join(".github/copilot-instructions.md"), "drift").unwrap();
    git(&project, &["commit", "-q", "-am", "drift"]);
    let applied = kendex(&home, &project, &["apply", "--yes", "--commit"]);
    let text = said(&applied);
    assert_eq!(applied.status.code(), Some(0), "{text}");
    assert_ne!(head_subject(&project), "drift", "{text}");
    let committed = git(&project, &["show", "--name-only", "--format=", "HEAD"]);
    assert!(
        committed
            .lines()
            .any(|line| line == ".github/copilot-instructions.md"),
        "{committed}\n{text}"
    );
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
