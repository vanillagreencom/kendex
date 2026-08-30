//! What the templates in this repository would write into a consumer's
//! tracked `kendex.settings.toml`, asked of the merge that writes it.
//!
//! A template applies once, when its skill arrives, and writes only the
//! keys it marks `# required` — the ones the consumer has to decide.
//! Every later pass writes nothing, so a refresh leaves the file
//! byte-identical and a key the consumer deleted stays deleted.
//!
//! Arrival is the manifest gaining the declaration, which only `add`
//! does, so the merge is the whole of what reaches this file. A block
//! already in it is never revisited — nothing follows a template revision
//! in — so there is no second write to model here.
#![cfg(unix)]

use std::path::{Path, PathBuf};

use kendex_core::settings_seed::{
    SETTINGS_FILE, SETTINGS_TEMPLATE, SeededEnv, Seeding, env_blocked, extract_env_entries, merge,
};

fn root() -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR")).join("../..")
}

/// Every skill directory this repository ships a template from, by name.
///
/// Two roots, because seeding reads the template at the item's own path:
/// `skills/` for a package built here, and the rendered tree for an item
/// declared `source = "in-place"`, which has no copy under `skills/` at
/// all. A name in both is one tree's render of the other, so the source
/// wins and the key is counted once.
#[allow(clippy::unwrap_used)]
fn skill_dirs() -> Vec<(String, PathBuf)> {
    let mut found: std::collections::BTreeMap<String, PathBuf> = std::collections::BTreeMap::new();
    for (root, wins) in [
        (root().join(".agents/skills"), false),
        (root().join("skills"), true),
    ] {
        let Ok(listing) = std::fs::read_dir(&root) else {
            continue;
        };
        for entry in listing {
            let path = entry.unwrap().path();
            if !path.join(SETTINGS_TEMPLATE).is_file() {
                continue;
            }
            let name = path.file_name().unwrap().to_string_lossy().into_owned();
            if wins || !found.contains_key(&name) {
                found.insert(name, path);
            }
        }
    }
    found.into_iter().collect()
}

/// Every `[env]` entry those templates declare, in skill-name order — the
/// order seeding resolves a key shipped by more than one owner in.
fn shipped_entries() -> Vec<SeededEnv> {
    let mut entries = Vec::new();
    for (owner, path) in skill_dirs() {
        let Ok(text) = std::fs::read_to_string(path.join(SETTINGS_TEMPLATE)) else {
            continue;
        };
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

/// An empty table: somewhere to write, and nothing already answered, so
/// what comes back is what the templates would put in a consumer's file.
const EMPTY: &str = "[env]\n";

/// The keys an arrival writes are the marked ones, and no others. This is
/// the control on the two assertions below: it proves the walk found real
/// templates and that a merge over them can add something at all.
#[test]
fn an_arrival_writes_the_keys_the_templates_mark_required() {
    let entries = shipped_entries();
    assert!(
        !entries.is_empty(),
        "the skills here ship templates to read"
    );
    let arriving = Seeding::new(entries.iter().map(|seeded| seeded.owner.clone()), []);
    let (_, added) = merge(Some(EMPTY), &entries, &arriving).unwrap_or_default();
    let marked: Vec<&str> = entries
        .iter()
        .filter(|seeded| seeded.entry.required)
        .map(|seeded| seeded.entry.key.as_str())
        .collect();
    assert!(
        !marked.is_empty(),
        "some key here is one a consumer must decide"
    );
    assert_eq!(
        added, marked,
        "an arrival writes the marked keys and nothing else"
    );
}

/// A refresh is every pass after the arrival, and it writes nothing —
/// asked of an empty file, where anything it wanted to write would show.
#[test]
fn a_refresh_writes_nothing_whatever_the_file_is_missing() {
    let entries = shipped_entries();
    assert!(
        !entries.is_empty(),
        "the skills here ship templates to read"
    );
    let added = merge(Some(EMPTY), &entries, &Seeding::default()).map(|(_, added)| added);
    assert_eq!(
        added, None,
        "a refresh writes no key into a consumer's file"
    );
}

/// And so this repository's own tracked settings file, the one the
/// reproduction watched, is left exactly as it is.
#[test]
#[allow(clippy::unwrap_used)]
fn a_refresh_of_this_repository_leaves_its_settings_file_alone() {
    let entries = shipped_entries();
    let settings = std::fs::read_to_string(root().join(SETTINGS_FILE)).unwrap();
    // Without this, a file with nowhere to write would report the clean
    // answer: merge refuses such a file with the same `None` it spends on
    // having nothing to add.
    assert_eq!(
        env_blocked(&settings).map(|env| env.problem()),
        None,
        "{SETTINGS_FILE} opens a table a seed could be written into"
    );
    let added = merge(Some(&settings), &entries, &Seeding::default()).map(|(_, added)| added);
    assert_eq!(added, None, "a refresh adds no key to {SETTINGS_FILE}");
}
