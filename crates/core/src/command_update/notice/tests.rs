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
            command: "sudo '/usr/local/bin/kendex' update".to_owned(),
        })
    );
}

/// The command names the file the card just named.
///
/// `sudo` resolves a bare name against `secure_path`, so `sudo kendex` is
/// either not found or a different kendex — a card offering one command
/// that does not reach the file it just named.
#[test]
fn the_elevated_command_names_the_file_it_updates() {
    let said = elevated_update(Path::new("/opt/kendex/bin/kendex"));

    assert_eq!(said, "sudo '/opt/kendex/bin/kendex' update");
    assert!(!said.contains("sudo kendex"), "{said}");
    // Nothing of this person's environment is handed to the root process:
    // the record it would reach is opened by a name they control.
    assert!(!said.contains("HOME"), "{said}");
}

/// A path is quoted, not merely shown: this is a line somebody pastes into
/// a root shell, and a space in it would otherwise split into two words.
#[test]
fn a_path_with_a_space_is_one_word_to_a_shell() {
    let said = elevated_update(Path::new("/opt/my tools/kendex"));

    assert!(said.contains("'/opt/my tools/kendex'"), "{said}");
}
