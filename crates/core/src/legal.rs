//! The terms record: which version of the published Terms of Service and
//! Privacy Policy this machine accepted, and when.
//!
//! One record for both shells. The app's first-run screen and the CLI's
//! first-run line write the same field in the same settings file, so a
//! person who accepted in one is not asked again by the other. Nothing
//! else in kendex reads it: no command, page or install refuses because
//! the record is absent — the acceptance is the step, not a gate on the
//! work.
//!
//! The version is what makes the record evidentiary. It names the exact
//! documents accepted, which is why `docs/legal/terms.md` and
//! `docs/legal/privacy.md` state it in their own bytes and
//! `documents_state_the_version_this_build_asks_about` holds the three to
//! one number.

use serde::{Deserialize, Serialize};
use specta::Type;

use crate::clock::timestamp;
use crate::env::Env;
use crate::error::Result;
use crate::settings::{self, AppSettings};

/// Where the documents are published. The app links them beside its accept
/// button and the CLI prints them; both read here, because a second
/// spelling of a URL is a link that rots on its own.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Type)]
#[serde(rename_all = "camelCase")]
pub struct Legal {
    /// The version of the two documents this build asks about. Bumped only
    /// when what a person agreed to changes: a re-prompt for a correction
    /// nobody needs to read is how people learn to click past the one that
    /// matters.
    pub version: u32,
    pub terms_url: &'static str,
    pub privacy_url: &'static str,
}

pub const LEGAL: Legal = Legal {
    version: 1,
    terms_url: "https://kendex.ai/legal/terms",
    privacy_url: "https://kendex.ai/legal/privacy",
};

/// What this machine accepted. Written once per version — a second accept
/// of a version already recorded leaves the first date standing, because
/// the date is when the person agreed and no later run changes that.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, Type)]
#[serde(rename_all = "kebab-case")]
pub struct TermsAcceptance {
    pub version: u32,
    /// ISO-8601 UTC, from [`crate::clock::timestamp`].
    pub accepted_at: String,
}

/// Whether the person still has to be asked.
///
/// A record from a later version than this build asks about is left alone:
/// an older kendex run beside a newer one has nothing to add, and asking
/// again would overwrite the newer record with an older number.
pub fn asks_again(accepted: Option<&TermsAcceptance>) -> bool {
    accepted.is_none_or(|record| record.version < LEGAL.version)
}

/// Record acceptance of the current version, and hand back the settings it
/// wrote. Under the settings write lock like every other targeted change,
/// so the app accepting and a `kendex` command running in a terminal at
/// the same moment cannot lose each other's file.
///
/// A run acting as root records nothing and says so. The settings file and
/// its lock are resolved from the environment the run was handed, so a
/// privileged write leaves them owned by root in a directory the person's
/// own account named — and every unprivileged settings write after it
/// fails, for good, naming nothing. [`crate::privilege`] holds the whole
/// reasoning, and the command record refuses on it too.
pub fn accept(env: &Env) -> Result<(AppSettings, crate::base::Base)> {
    accept_as(env, crate::privilege::acting_as_root())
}

/// The same, told who is making it, so a suite drives either arm whatever
/// uid it is running under. Every caller outside a test comes through
/// [`accept`], which asks the process.
///
/// Guarded here and nowhere below, ahead of the write lock: a root run
/// creates neither the lock file nor the directory holding it.
fn accept_as(env: &Env, root: bool) -> Result<(AppSettings, crate::base::Base)> {
    if root {
        return Err(crate::error::CoreError::WouldWriteAsRoot);
    }
    settings::mutate(env, |settings| {
        if asks_again(settings.terms.as_ref()) {
            settings.terms = Some(TermsAcceptance {
                version: LEGAL.version,
                accepted_at: timestamp(),
            });
        }
        Ok(())
    })
}

/// The version a published document declares, from its `Version N.` line.
///
/// Read rather than assumed: the number in the record is only worth
/// something if it names bytes someone can go and read.
pub fn stated_version(document: &str) -> Option<u32> {
    document
        .lines()
        .find_map(|line| line.strip_prefix("Version "))
        .and_then(|rest| rest.split('.').next())
        .and_then(|digits| digits.parse().ok())
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::env::FakeOs;
    use std::path::{Path, PathBuf};

    fn env_in(dir: &Path) -> Env {
        Env::fake(dir, FakeOs::Linux)
    }

    fn recorded(env: &Env) -> Option<TermsAcceptance> {
        settings::load(env).unwrap().terms
    }

    fn document(name: &str) -> String {
        let path = PathBuf::from(env!("CARGO_MANIFEST_DIR"))
            .join("../../docs/legal")
            .join(name);
        std::fs::read_to_string(&path).unwrap_or_else(|e| panic!("{}: {e}", path.display()))
    }

    /// The whole rule the two first-run surfaces share, over every shape a
    /// settings file can hold: nothing recorded and a record left by an
    /// older version ask; the current version and a newer one do not.
    #[test]
    fn a_record_older_than_this_build_asks_again_and_a_current_one_does_not() {
        let rows: [(Option<u32>, bool); 4] = [
            (None, true),
            (Some(LEGAL.version - 1), true),
            (Some(LEGAL.version), false),
            (Some(LEGAL.version + 1), false),
        ];
        for (version, asks) in rows {
            let record = version.map(|version| TermsAcceptance {
                version,
                accepted_at: "2026-09-06T00:00:00Z".to_owned(),
            });
            assert_eq!(asks_again(record.as_ref()), asks, "recorded {version:?}");
        }
    }

    /// Accepting writes the version this build asks about, once.
    ///
    /// The second half is the must-fail one, and the seeded date is what
    /// makes it bite: `timestamp` has second resolution, so two accepts a
    /// few microseconds apart produce the same string and would agree
    /// whether or not the guard is there. A date from years ago cannot.
    /// The date is when the person agreed, and no later run moves it.
    #[test]
    fn acceptance_is_recorded_once_with_its_version() {
        let tmp = tempfile::tempdir().unwrap();
        let env = env_in(tmp.path());
        assert!(asks_again(recorded(&env).as_ref()));

        accept(&env).unwrap();
        let first = recorded(&env).expect("accept records");
        assert_eq!(first.version, LEGAL.version);
        assert!(!asks_again(Some(&first)));

        let agreed = "2020-01-01T00:00:00Z";
        settings::mutate(&env, |settings| {
            settings.terms = Some(TermsAcceptance {
                version: LEGAL.version,
                accepted_at: agreed.to_owned(),
            });
            Ok(())
        })
        .unwrap();

        accept(&env).unwrap();
        assert_eq!(
            recorded(&env),
            Some(TermsAcceptance {
                version: LEGAL.version,
                accepted_at: agreed.to_owned(),
            })
        );
    }

    /// A record left by an older version is replaced by this one, rather
    /// than kept beside it: one record, naming the documents in force.
    #[test]
    fn accepting_a_later_version_replaces_the_older_record() {
        let tmp = tempfile::tempdir().unwrap();
        let env = env_in(tmp.path());
        settings::mutate(&env, |settings| {
            settings.terms = Some(TermsAcceptance {
                version: LEGAL.version - 1,
                accepted_at: "2020-01-01T00:00:00Z".to_owned(),
            });
            Ok(())
        })
        .unwrap();

        accept(&env).unwrap();
        let record = recorded(&env).expect("accept records");
        assert_eq!(record.version, LEGAL.version);
        assert_ne!(record.accepted_at, "2020-01-01T00:00:00Z");
    }

    /// A root run records nothing and creates nothing — not the settings
    /// file, not its lock, not the directory holding them. Writing would
    /// leave those owned by root under a path the invoking account named,
    /// and every unprivileged settings write after it would fail for good
    /// with nothing on screen naming the cause. The command record refuses
    /// on the same reasoning; `crate::privilege` holds it.
    #[test]
    fn a_run_acting_as_root_records_nothing_and_says_so() {
        let dir = tempfile::tempdir().unwrap();
        // The home an elevated run would be pointed at: this account's,
        // kept across the privilege change by the sudoers policy.
        let theirs = dir.path().join("home");
        let env = env_in(&theirs);
        let settings_file = env.settings_file();

        assert!(matches!(
            accept_as(&env, true),
            Err(crate::error::CoreError::WouldWriteAsRoot)
        ));
        assert!(
            !settings_file.exists(),
            "{} was written by a root run",
            settings_file.display()
        );
        let holding = settings_file.parent().unwrap();
        assert!(
            !holding.exists(),
            "{} was created by a root run",
            holding.display()
        );

        // The same call from the person's own account does the work, so
        // the refusal above is the uid and not a fixture that could never
        // have written anywhere.
        accept_as(&env, false).unwrap();
        assert_eq!(
            recorded(&env).map(|record| record.version),
            Some(LEGAL.version)
        );
    }

    /// The published documents name the version the record stores. Without
    /// this the number is a number: the bytes it points at could say
    /// anything.
    #[test]
    fn documents_state_the_version_this_build_asks_about() {
        for name in ["terms.md", "privacy.md"] {
            assert_eq!(
                stated_version(&document(name)),
                Some(LEGAL.version),
                "{name}"
            );
        }
    }

    /// The reader that claim rests on, over the shapes it must tell apart —
    /// a document declaring another version must not read as this one.
    #[test]
    fn the_version_line_is_read_and_not_assumed() {
        let rows: [(&str, Option<u32>); 4] = [
            ("# Terms\n\nVersion 1. Effective today.\n", Some(1)),
            ("# Terms\n\nVersion 2. Effective today.\n", Some(2)),
            ("# Terms\n\nEffective today.\n", None),
            ("# Terms\n\nVersion one. Effective today.\n", None),
        ];
        for (document, version) in rows {
            assert_eq!(stated_version(document), version, "{document:?}");
        }
    }
}
