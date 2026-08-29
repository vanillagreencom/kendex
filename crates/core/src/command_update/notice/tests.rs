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
