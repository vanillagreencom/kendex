use super::*;

/// What the card is owed, per state. Every arm that is not the app's own
/// to carry says something, and no arm invents a name or a command: the
/// managed one repeats the installer's, the privileged one names the
/// installer that can write where the app cannot, and the unknown one
/// neither.
#[test]
fn the_card_is_told_what_each_state_owes_a_person() {
    assert_eq!(
        CommandNotice::for_card(&CommandBeside::Ours("/x/kendex".into())),
        None
    );
    assert_eq!(CommandNotice::for_card(&CommandBeside::Absent), None);
    assert_eq!(
        CommandNotice::for_card(&CommandBeside::NotOurs(InstallChannel::Unknown)),
        Some(CommandNotice::Unknown)
    );
    assert_eq!(
        CommandNotice::for_card(&CommandBeside::NotOurs(InstallChannel::Managed {
            manager: "Homebrew".to_owned(),
            command: "brew upgrade kendex-cli".to_owned(),
        })),
        Some(CommandNotice::Managed {
            manager: "Homebrew".to_owned(),
            command: "brew upgrade kendex-cli".to_owned(),
        })
    );
    // Told there is an installer, because which arm this state takes is
    // the platform's answer and this row is about the installer one. The
    // other is its own case below.
    assert_eq!(
        CommandNotice::for_card_where(
            &CommandBeside::NeedsPrivilege("/usr/local/bin/kendex".into()),
            true
        ),
        Some(CommandNotice::NeedsPrivilege {
            path: "/usr/local/bin/kendex".to_owned(),
            command: INSTALLER_RERUN.to_owned(),
        })
    );
}

/// One machine's answer, and the half that follows from it: `Ours` is the
/// only one this app carries across, so it is the only one that moves.
fn beside(state: &CommandBeside) -> (Option<CommandNotice>, CommandHalf) {
    let half = match state {
        CommandBeside::Ours(_) => CommandHalf::Moved,
        _ => CommandHalf::Untouched,
    };
    (CommandNotice::for_card(state), half)
}

/// Every disposition a card can be drawn from, so the table below asks the
/// whole input space rather than the two pairs the app-side cases reach.
fn every_state() -> Vec<CommandBeside> {
    vec![
        CommandBeside::Ours("/home/pat/.local/bin/kendex".into()),
        CommandBeside::Absent,
        CommandBeside::NotOurs(InstallChannel::Unknown),
        CommandBeside::NotOurs(InstallChannel::Managed {
            manager: "Homebrew".to_owned(),
            command: "brew upgrade kendex-cli".to_owned(),
        }),
        CommandBeside::NeedsPrivilege("/usr/local/bin/kendex".into()),
    ]
}

/// A card that still describes what is there says nothing, whatever it
/// described. This is the pair almost every real machine presses Update
/// now on — a Homebrew command named on the card and still named on the
/// lookup — and a sentence here would be an alarm about nothing.
#[test]
fn a_card_that_still_describes_the_command_says_nothing() {
    for state in every_state() {
        let (card, half) = beside(&state);
        assert_eq!(
            CommandNotice::not_as_shown("5.1.0", half, card.as_ref(), card.as_ref()),
            None,
            "{state:?}"
        );
    }
}

/// Every card whose disposition moved, and the sentence each is owed. What
/// separates them is what became of the command, not what the card said:
/// one this app carried across, one left where it is on the old release,
/// and one that is not on the machine at all — which the pair before this
/// change called left behind, about a file nobody has.
#[test]
fn a_card_whose_command_moved_is_told_what_became_of_it() {
    for state in every_state() {
        for other in every_state() {
            let (card, _) = beside(&other);
            let (found, half) = beside(&state);
            if found == card {
                continue;
            }
            let told = CommandNotice::not_as_shown("5.1.0", half, found.as_ref(), card.as_ref())
                .unwrap_or_else(|| panic!("{other:?} became {state:?} and nothing was said"));
            assert!(told.contains("kendex 5.1.0 is installed"), "{told}");
            let expected = match (&state, half) {
                (_, CommandHalf::Moved) => "carried across rather than left",
                (CommandBeside::Absent, _) => "not beside this app any more",
                _ => "left on the release it is on",
            };
            assert!(
                told.contains(expected),
                "{other:?} became {state:?}: {told}"
            );
        }
    }
}

/// Two `NeedsPrivilege` naming different files are two different
/// sentences, because that arm prints the path: a person told about
/// `/usr/local/bin/kendex` was pointed at one file, and a command left
/// behind somewhere else is not the one they read about. `Ours` is the
/// contrast and the reason this needs saying at all — it prints nothing,
/// so two of those at different paths stay silent.
#[test]
fn one_privileged_command_is_not_another_at_a_different_path() {
    let (here, half) = beside(&CommandBeside::NeedsPrivilege(
        "/usr/local/bin/kendex".into(),
    ));
    let (there, _) = beside(&CommandBeside::NeedsPrivilege("/opt/kendex/kendex".into()));
    assert_ne!(
        here, there,
        "the card prints the path, so the path is part of what was said"
    );

    let told = CommandNotice::not_as_shown("5.1.0", half, there.as_ref(), here.as_ref())
        .expect("a card naming one file, and a command left at another");
    assert!(told.contains("left on the release it is on"), "{told}");

    let (one, moved) = beside(&CommandBeside::Ours("/home/pat/.local/bin/kendex".into()));
    let (other, _) = beside(&CommandBeside::Ours("/usr/bin/kendex".into()));
    assert_eq!(
        CommandNotice::not_as_shown("5.1.0", moved, other.as_ref(), one.as_ref()),
        None,
        "a command this app carries across names no path on the card"
    );
}

/// The command the privileged arm offers is the same command whatever
/// file the card is about, and none of that file's name is in it.
///
/// This is the arm a person is invited to run with privilege, and a path
/// this process read is a path an unprivileged account can arrange: it
/// picks the directory the write probe failed in, and it can put anything
/// at the name once it has. So what is offered has to be text no input
/// here can move.
///
/// Beside the table rather than in it, for the reason the case above is:
/// `every_state` holds one state per disposition, and the fact here needs
/// two of one disposition that differ only in path. What that case asks is
/// the complement of this one — it asks that two such notices differ,
/// because the arm prints the path; this asks that the command they offer
/// does not.
///
/// Told there is an installer, because this is the installer arm: which
/// one a `NeedsPrivilege` takes is the platform's answer, and asking the
/// platform here would make the case pass or panic by where it ran.
#[test]
fn the_privileged_arm_offers_a_command_no_path_reaches() {
    let offered = |path: &str| match CommandNotice::for_card_where(
        &CommandBeside::NeedsPrivilege(path.into()),
        true,
    ) {
        Some(CommandNotice::NeedsPrivilege { command, .. }) => command,
        other => panic!("a command kendex cannot write is not {other:?}"),
    };
    let system = offered("/usr/local/bin/kendex");
    let owned = offered("/home/someone/.local/bin/kendex");
    assert_eq!(system, owned);
    // Each command against the directory of the path it was built from,
    // so both assertions red on an interpolation and neither passes for
    // want of a fixture that could have carried it.
    for (path, command) in [
        ("/usr/local/bin", &system),
        ("/home/someone/.local/bin", &owned),
    ] {
        assert!(
            !command.contains(path),
            "the offered command carries {path}: {command}"
        );
        // A root shell handed a bare name resolves it against sudo's own
        // `secure_path`, which is the other half of the same defect.
        assert!(
            !command.contains("sudo"),
            "the offered command elevates: {command}"
        );
    }
}

/// The privileged arm on a platform with no installer. `install.sh` names
/// the systems it takes and refuses the rest, so a pipeline offered where
/// it is refused is an instruction nobody can follow — and this arm is
/// reachable there: a `kendex.exe` ships in every release, and one dropped
/// somewhere the app cannot write is recorded by its own first run.
///
/// It still names the file, because that is what the notice is about. What
/// it offers instead is the page, which is the whole of what a person can
/// do here.
#[test]
fn a_platform_with_no_installer_is_offered_a_download_not_a_pipeline() {
    let beside = CommandBeside::NeedsPrivilege("C:/Program Files/kendex/kendex.exe".into());
    let Some(CommandNotice::NeedsDownload { path, page }) =
        CommandNotice::for_card_where(&beside, false)
    else {
        panic!(
            "a command no installer can reach was told {:?}",
            CommandNotice::for_card_where(&beside, false)
        );
    };
    assert!(path.contains("kendex.exe"), "the file is not named: {path}");
    for shell in ["curl", "|", "sh", "sudo"] {
        assert!(
            !page.contains(shell),
            "the page carries {shell}, which is a command and not a page: {page}"
        );
    }
    assert!(page.starts_with("https://"), "not a page: {page}");
    // The wiring, not only the arms: `for_card` has to ask the platform.
    // Driving the seam alone would not notice if it stopped, and this
    // holds from either side — a build that always says installer is
    // wrong on Windows, one that never does is wrong everywhere else.
    assert_eq!(
        CommandNotice::for_card(&beside),
        CommandNotice::for_card_where(&beside, !cfg!(windows)),
        "for_card did not answer with the arm this platform warrants"
    );
}

/// The page the card names is the one `README.md` publishes. It is a fact
/// with two spellings and no compiler between them, so the README is read
/// rather than trusted — the pin the invocation beside it already carries.
///
/// Read through the card rather than the constant, so an arm that stopped
/// offering the page fails here too.
#[test]
#[allow(clippy::unwrap_used)]
fn the_download_page_is_the_one_the_readme_publishes() {
    let readme = std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join("../../README.md");
    let published = std::fs::read_to_string(&readme).unwrap();
    let Some(CommandNotice::NeedsDownload { page, .. }) = CommandNotice::for_card_where(
        &CommandBeside::NeedsPrivilege("C:/Program Files/kendex/kendex.exe".into()),
        false,
    ) else {
        panic!("the arm with no installer offers no page");
    };
    assert!(
        published.contains(&format!("({page})")),
        "README.md publishes no link to {page}"
    );
}
