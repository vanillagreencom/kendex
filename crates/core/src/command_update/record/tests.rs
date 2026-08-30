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
