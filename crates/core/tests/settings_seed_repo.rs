//! A refresh of this repository seeds nothing into its own settings file.
//!
//! `kendex.settings.toml` is tracked here, so a key seeding appends to it is
//! a diff no maintainer wrote, arriving on whatever run happens to be next.
//! Every `[env]` key the skills in this repository ship must therefore
//! already be answered in that file — or not be shipped for seeding at all,
//! which is the answer for a key whose template value is the same value the
//! shell reads when nothing assigns it.
//!
//! The subject is the merge alone. Comment refresh is the other half of a
//! real refresh and rewrites a seeded comment block on purpose, keyed to
//! ledger records that live in an untracked lock; what it does is a feature,
//! and what it would do here is not reproducible from tracked bytes.
#![cfg(unix)]

use std::path::{Path, PathBuf};

use kendex_core::settings_seed::{
    SETTINGS_FILE, SETTINGS_TEMPLATE, SeededEnv, extract_env_entries, merge,
};

fn root() -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR")).join("../..")
}

/// Every `[env]` entry the skills here ship, their directories walked in
/// name order — the order seeding resolves a key shipped by more than one
/// owner in.
#[allow(clippy::unwrap_used)]
fn shipped_entries() -> Vec<SeededEnv> {
    let mut skills: Vec<PathBuf> = std::fs::read_dir(root().join("skills"))
        .unwrap()
        .map(|entry| entry.unwrap().path())
        .collect();
    skills.sort();
    let mut entries = Vec::new();
    for skill in skills {
        let Ok(text) = std::fs::read_to_string(skill.join(SETTINGS_TEMPLATE)) else {
            continue;
        };
        let owner = skill.file_name().unwrap().to_string_lossy().into_owned();
        entries.extend(
            extract_env_entries(&text)
                .into_iter()
                .map(|entry| SeededEnv {
                    entry,
                    owner: owner.clone(),
                }),
        );
    }
    entries
}

#[test]
#[allow(clippy::unwrap_used)]
fn a_refresh_of_this_repository_adds_no_key_to_its_settings_file() {
    let entries = shipped_entries();
    // Without this, a walk that read no template at all would report the
    // clean answer and mean nothing by it.
    assert!(
        !entries.is_empty(),
        "the skills here ship templates to read"
    );
    let settings = std::fs::read_to_string(root().join(SETTINGS_FILE)).unwrap();
    let added = merge(Some(&settings), &entries)
        .map(|(_, added)| added)
        .unwrap_or_default();
    assert!(
        added.is_empty(),
        "a refresh would append {added:?} to {SETTINGS_FILE}: either this \
         repository answers each of those keys itself, or the skill shipping \
         one should not seed a value its own code already defaults to"
    );
}
