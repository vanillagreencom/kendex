use super::*;

/// What the card is owed, per state. Every arm that is not the app's own
/// to carry says something, and no arm invents a name or a command: the
/// managed one repeats the installer's, the privileged one the single
/// fixed command that supplies what is missing, and the unknown one
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
    assert_eq!(
        CommandNotice::for_card(&CommandBeside::NeedsPrivilege(
            "/usr/local/bin/kendex".into()
        )),
        Some(CommandNotice::NeedsPrivilege {
            path: "/usr/local/bin/kendex".to_owned(),
            command: ELEVATED_UPDATE.to_owned(),
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
