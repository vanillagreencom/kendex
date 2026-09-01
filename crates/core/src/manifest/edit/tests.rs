//! What a fold leaves behind, spelled out on documents rather than on
//! manifests: every case here is a shape somebody can legally write in
//! kendex.toml, and the assertion is on the bytes.

use super::merged;

#[allow(clippy::unwrap_used)]
fn fold(current: &str, desired: &str) -> String {
    merged(current, desired).unwrap()
}

/// The whole point: a document whose values already say what kendex holds
/// comes back byte-identical, comments and spelling included.
#[test]
fn a_document_that_already_agrees_is_returned_unchanged() {
    let current = "# my setup\nschema  =  6\n\n# where it comes from\n[sources.cat]\npath = 'x'   # local\nenabled = true\n\n[skills.gh]\nsource = \"cat\"\n";
    let desired = "schema = 6\n\n[sources.cat]\npath = \"x\"\nenabled = true\n\n[skills.gh]\nsource = \"cat\"\n";
    assert_eq!(fold(current, desired), current);
}

/// A gained table lands after the tables already there, with the blank
/// line the serializer puts before it, and nothing above it moves.
#[test]
fn a_gained_table_is_appended_and_leaves_the_rest_alone() {
    let current = "# mine\nschema = 6\n\n[skills.gh]\nsource = \"cat\"   # keep\n";
    let desired = "schema = 6\n\n[skills.gh]\nsource = \"cat\"\n\n[skills.fmt]\nsource = \"cat\"\n";
    assert_eq!(
        fold(current, desired),
        "# mine\nschema = 6\n\n[skills.gh]\nsource = \"cat\"   # keep\n\n[skills.fmt]\nsource = \"cat\"\n"
    );
}

/// A gained key lands inside the table it belongs to, under the keys
/// already there — not at the end of the file, where it would read as a
/// key of whichever table happens to be last.
#[test]
fn a_gained_key_lands_inside_its_own_table() {
    let current = "schema = 6\n\n[sources.cat]\n# the catalog\npath = \"x\"\n\n[install]\nmethod = \"copy\"\n";
    let desired = "schema = 6\n\n[sources.cat]\npath = \"x\"\nrev = \"main\"\n\n[install]\nmethod = \"copy\"\n";
    assert_eq!(
        fold(current, desired),
        "schema = 6\n\n[sources.cat]\n# the catalog\npath = \"x\"\nrev = \"main\"\n\n[install]\nmethod = \"copy\"\n"
    );
}

/// A changed value keeps the whitespace and the trailing comment that sat
/// with it; every other line is untouched.
#[test]
fn a_changed_value_keeps_its_own_decoration() {
    let current = "schema = 6\n\n[install]\nmethod   =   \"copy\"   # for now\n";
    let desired = "schema = 6\n\n[install]\nmethod = \"symlink\"\n";
    assert_eq!(
        fold(current, desired),
        "schema = 6\n\n[install]\nmethod   =   \"symlink\"   # for now\n"
    );
}

/// A dropped table takes the comments written against it and nothing else.
#[test]
fn a_dropped_table_takes_only_its_own_lines() {
    let current = "schema = 6\n\n# gh, for github\n[skills.gh]\nsource = \"cat\"\n\n# formatting\n[skills.fmt]\nsource = \"cat\"\n";
    let desired = "schema = 6\n\n[skills.fmt]\nsource = \"cat\"\n";
    assert_eq!(
        fold(current, desired),
        "schema = 6\n\n# formatting\n[skills.fmt]\nsource = \"cat\"\n"
    );
}

/// Inline tables and dotted keys are how a person may have spelled the
/// same declarations. A fold that agrees with them rewrites neither, and
/// one that disagrees edits inside the spelling it found.
#[test]
fn inline_and_dotted_spellings_are_kept() {
    let current = "schema = 6\nsources.cat = { path = \"x\", enabled = true }\n\n[skills]\ngh = { source = \"cat\" }\n";
    let desired = "schema = 6\n\n[sources.cat]\npath = \"x\"\nenabled = true\n\n[skills.gh]\nsource = \"cat\"\n";
    assert_eq!(fold(current, desired), current);

    let changed = "schema = 6\n\n[sources.cat]\npath = \"y\"\nenabled = true\n\n[skills.gh]\nsource = \"cat\"\n";
    assert_eq!(
        fold(current, changed),
        "schema = 6\nsources.cat = { path = \"y\", enabled = true }\n\n[skills]\ngh = { source = \"cat\" }\n"
    );
}

/// An array of tables written inline stays inline while it agrees, and an
/// entry's untouched keys survive an edit to a neighbouring key.
#[test]
fn a_table_array_is_edited_entry_by_entry() {
    let current = "schema = 6\n\n[[custom-hooks]]\n# runs before every bash call\nevent = \"PreToolUse\"\ncommand = \"./guard.sh\"\n\n[[custom-hooks]]\nevent = \"Stop\"\ncommand = \"./done.sh\"\n";
    let desired = "schema = 6\n\n[[custom-hooks]]\nevent = \"PreToolUse\"\ncommand = \"./guard.sh\"\n\n[[custom-hooks]]\nevent = \"Stop\"\ncommand = \"./finished.sh\"\n";
    assert_eq!(
        fold(current, desired),
        "schema = 6\n\n[[custom-hooks]]\n# runs before every bash call\nevent = \"PreToolUse\"\ncommand = \"./guard.sh\"\n\n[[custom-hooks]]\nevent = \"Stop\"\ncommand = \"./finished.sh\"\n"
    );

    let inline = "schema = 6\ncustom-hooks = [{ event = \"Stop\", command = \"./done.sh\" }]\n";
    let same = "schema = 6\n\n[[custom-hooks]]\nevent = \"Stop\"\ncommand = \"./done.sh\"\n";
    assert_eq!(fold(inline, same), inline);
}

/// A file's own terminator is its own: a document ending without one gets
/// exactly the one its last line needs, and a document ending in a blank
/// line keeps it.
#[test]
fn the_files_own_terminator_survives() {
    let desired = "schema = 6\n\n[install]\nmethod = \"copy\"\n";
    assert_eq!(
        fold("schema = 6\n\n[install]\nmethod = \"copy\"", desired),
        desired
    );
    assert_eq!(
        fold("schema = 6\n\n[install]\nmethod = \"copy\"\n\n", desired),
        "schema = 6\n\n[install]\nmethod = \"copy\"\n\n"
    );
}

/// A file that is not TOML is refused, never rewritten — the caller turns
/// this into the same parse error a read would have raised.
#[test]
fn an_unparsable_document_is_refused() {
    assert!(merged("not = [valid", "schema = 6\n").is_err());
}
