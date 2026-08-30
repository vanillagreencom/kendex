//! What the record proves about a file, and what it refuses to prove.
//! The lookup itself lives in the parent; these are the arms that turn on
//! the record alone, against real files rather than a described machine.

use super::*;

/// Bytes to take an identity from — a wrapper someone wrote, which is the
/// kind of file a record has to be able to disown.
const WRAPPER: &[u8] = b"#!/bin/sh\nexec /opt/kendex/kendex \"$@\"\n";

/// A record this build cannot read is not a record it acts on. The file
/// carries two lines and both have to be what they claim: one absolute
/// path, and one SHA-256. A half-written record, a relative path, or a
/// digest that is not one reads as no record rather than as a record with
/// a field to work around.
#[test]
fn a_record_that_is_not_a_path_and_a_digest_is_no_record() {
    let dir = tempfile::tempdir().unwrap();
    let env = Env::host_rooted(dir.path());
    let file = env.installed_command_file();
    std::fs::create_dir_all(file.parent().unwrap()).unwrap();
    assert_eq!(recorded_command(&env), None, "nothing written at all");

    let digest = crate::hash::sha256_hex(WRAPPER);
    for written in [
        String::new(),
        "  \n".to_owned(),
        // The path alone: the whole of the record before the digest
        // existed, and a build that acted on it would replace by name.
        "/usr/local/bin/kendex\n".to_owned(),
        format!("bin/kendex\n{digest}\n"),
        format!("/usr/local/bin/kendex\n{}\n", &digest[..63]),
        format!("/usr/local/bin/kendex\n{}z\n", &digest[..63]),
        format!("/usr/local/bin/kendex\n{digest}{digest}\n"),
    ] {
        std::fs::write(&file, &written).unwrap();
        assert_eq!(recorded_command(&env), None, "{written:?}");
    }

    // The control: the same file, well formed, is read. Without it every
    // assertion above passes for a reader that returns `None` always.
    record_command(&env, Path::new("/usr/local/bin/kendex"), WRAPPER).unwrap();
    assert_eq!(
        recorded_command(&env),
        Some(InstalledCommand {
            path: PathBuf::from("/usr/local/bin/kendex"),
            digest,
        })
    );
}

/// Who to give the record back to is sudo's answer and nothing else's. A
/// run that is not elevated names nobody, and a half-set pair — one id
/// present, the other not — is not a person either; guessing the other
/// half would hand a file to whoever that id turns out to be.
#[test]
fn only_a_sudo_run_names_someone_to_hand_the_record_back_to() {
    let ids = |pairs: &[(&str, &str)]| {
        let held: Vec<(String, String)> = pairs
            .iter()
            .map(|(k, v)| ((*k).to_owned(), (*v).to_owned()))
            .collect();
        caller_ids(|name| {
            held.iter()
                .find(|(key, _)| key == name)
                .map(|(_, value)| value.clone())
        })
    };

    assert_eq!(
        ids(&[("SUDO_UID", "501"), ("SUDO_GID", "20")]),
        Some((501, 20))
    );
    assert_eq!(ids(&[]), None, "an ordinary run named someone");
    assert_eq!(
        ids(&[("SUDO_UID", "501")]),
        None,
        "half a pair named someone"
    );
    assert_eq!(
        ids(&[("SUDO_UID", "root"), ("SUDO_GID", "20")]),
        None,
        "a value that is not an id named someone"
    );
}
