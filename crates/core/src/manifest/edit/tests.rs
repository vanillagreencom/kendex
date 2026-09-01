//! What a fold leaves behind, spelled out on documents rather than on
//! manifests: every case here is a shape somebody can legally write in
//! kendex.toml, and the assertion is on the bytes.

use super::merged;
use crate::manifest::{InstallDefaults, Manifest};

/// A fold with `held` derived the way `manifest::save` derives it: the
/// manifest this very document reads back as, spelled by the serializer
/// that spelled the target.
#[allow(clippy::unwrap_used)]
fn fold(current: &str, desired: &str) -> String {
    let held: Manifest = toml::from_str(current).unwrap();
    let held = toml::to_string_pretty(&held).unwrap();
    merged(current, &held, desired).unwrap()
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
    assert!(merged("not = [valid", "schema = 6\n", "schema = 6\n").is_err());
}

/// A hook as the serializer spells one — taken from the serializer, not
/// written out here. A fixture that spells the fields by hand certifies
/// whatever the serializer did on the day it was written and drifts the
/// next time a field gains or loses a skip, which is how five cases came
/// to assert an `enabled = true` the fold does not write.
#[allow(clippy::unwrap_used)]
fn hook(event: &str, command: &str) -> String {
    let manifest: Manifest = toml::from_str(&format!(
        "schema = 6\n\n[[custom-hooks]]\nevent = \"{event}\"\ncommand = \"{command}\"\n"
    ))
    .unwrap();
    let text = toml::to_string_pretty(&manifest).unwrap();
    const HEADER: &str = "[[custom-hooks]]\n";
    let block = &text[text.find(HEADER).unwrap() + HEADER.len()..];
    block[..block.find("\n[").map_or(block.len(), |cut| cut + 1)].to_owned()
}

/// An inline `custom-hooks` array is edited inline. The comment above it
/// is written once, where it was, and not once per entry the serializer
/// would have generated.
#[test]
fn an_inline_hook_array_is_edited_inline() {
    let current = "schema = 6\n\n# my hooks\ncustom-hooks = [{ event = \"Stop\", command = \"./done.sh\" }]\n";
    let changed = format!(
        "schema = 6\n\n[[custom-hooks]]\n{}",
        hook("Stop", "./finished.sh")
    );
    assert_eq!(
        fold(current, &changed),
        "schema = 6\n\n# my hooks\ncustom-hooks = [{ event = \"Stop\", command = \"./finished.sh\" }]\n"
    );

    let gained = format!(
        "schema = 6\n\n[[custom-hooks]]\n{}\n[[custom-hooks]]\n{}",
        hook("Stop", "./done.sh"),
        hook("PreToolUse", "./guard.sh")
    );
    assert_eq!(
        fold(current, &gained),
        "schema = 6\n\n# my hooks\ncustom-hooks = [{ event = \"Stop\", command = \"./done.sh\" }, { event = \"PreToolUse\", command = \"./guard.sh\" }]\n"
    );
}

/// An empty inline array gaining its first entry stays an inline array,
/// with no header generated out of the key's own decoration.
#[test]
fn an_empty_inline_array_gains_its_first_entry_inline() {
    let current = "schema = 6\n\n# my hooks\ncustom-hooks = []\n";
    let desired = format!(
        "schema = 6\n\n[[custom-hooks]]\n{}",
        hook("Stop", "./done.sh")
    );
    assert_eq!(
        fold(current, &desired),
        "schema = 6\n\n# my hooks\ncustom-hooks = [{ event = \"Stop\", command = \"./done.sh\" }]\n"
    );
}

/// A multi-line array gains an element without losing the layout or the
/// comment written inside it. Gaining is all this case ever exercised,
/// which is how the positional-pairing class survived one level down: the
/// cases below cover losing and re-sorting.
#[test]
fn a_multiline_array_keeps_its_shape_and_its_inner_comment() {
    let current = "schema = 6\n\n[install]\nharnesses = [\n  # the one I use\n  \"claude\",\n]\n";
    let desired =
        "schema = 6\n\n[install]\nharnesses = [\"claude\", \"codex\"]\nmethod = \"symlink\"\n";
    assert_eq!(
        fold(current, desired),
        "schema = 6\n\n[install]\nharnesses = [\n  # the one I use\n  \"claude\",\n  \"codex\",\n]\nmethod = \"symlink\"\n"
    );
}

/// Removing a hook takes that hook's comment and leaves every other
/// comment over the hook it describes. By position the survivors would
/// shift up under comments that belong to what was removed.
#[test]
fn removing_a_hook_leaves_every_comment_over_its_own_hook() {
    let two = "schema = 6\n\n# guards every bash call\n[[custom-hooks]]\nevent = \"PreToolUse\"\ncommand = \"./guard.sh\"\n\n# says we are done\n[[custom-hooks]]\nevent = \"Stop\"\ncommand = \"./done.sh\"\n";
    let keep_second = format!(
        "schema = 6\n\n[[custom-hooks]]\n{}",
        hook("Stop", "./done.sh")
    );
    assert_eq!(
        fold(two, &keep_second),
        format!(
            "schema = 6\n\n# says we are done\n[[custom-hooks]]\n{}",
            hook("Stop", "./done.sh")
        )
    );

    let three = "schema = 6\n\n# first\n[[custom-hooks]]\nevent = \"Stop\"\ncommand = \"./a.sh\"\n\n# second\n[[custom-hooks]]\nevent = \"Stop\"\ncommand = \"./b.sh\"\n\n# third\n[[custom-hooks]]\nevent = \"Stop\"\ncommand = \"./c.sh\"\n";
    let drop_middle = format!(
        "schema = 6\n\n[[custom-hooks]]\n{}\n[[custom-hooks]]\n{}",
        hook("Stop", "./a.sh"),
        hook("Stop", "./c.sh")
    );
    assert_eq!(
        fold(three, &drop_middle),
        format!(
            "schema = 6\n\n# first\n[[custom-hooks]]\n{}\n# third\n[[custom-hooks]]\n{}",
            hook("Stop", "./a.sh"),
            hook("Stop", "./c.sh")
        )
    );
}

/// Reordering hooks moves each comment with the hook it was written
/// against, and the entries take the places the array already held.
#[test]
fn reordering_hooks_carries_every_comment_with_its_hook() {
    let three = "schema = 6\n\n# one\n[[custom-hooks]]\nevent = \"Stop\"\ncommand = \"./a.sh\"\n\n# two\n[[custom-hooks]]\nevent = \"Stop\"\ncommand = \"./b.sh\"\n\n# three\n[[custom-hooks]]\nevent = \"Stop\"\ncommand = \"./c.sh\"\n";
    let reversed = format!(
        "schema = 6\n\n[[custom-hooks]]\n{}\n[[custom-hooks]]\n{}\n[[custom-hooks]]\n{}",
        hook("Stop", "./c.sh"),
        hook("Stop", "./b.sh"),
        hook("Stop", "./a.sh")
    );
    assert_eq!(
        fold(three, &reversed),
        format!(
            "schema = 6\n\n# three\n[[custom-hooks]]\n{}\n# two\n[[custom-hooks]]\n{}\n# one\n[[custom-hooks]]\n{}",
            hook("Stop", "./c.sh"),
            hook("Stop", "./b.sh"),
            hook("Stop", "./a.sh")
        )
    );
}

/// A key the manifest model does not carry is not the model's to drop. It
/// stays exactly where it was written while the keys around it change.
#[test]
fn a_key_the_model_does_not_hold_is_left_alone() {
    let current =
        "schema = 6\n\n[skills.gh]\nsource = \"cat\"\nnote = \"why I keep this\"\nenabled = true\n";
    let desired = "schema = 6\n\n[skills.gh]\nsource = \"local\"\nenabled = true\n";
    assert_eq!(
        fold(current, desired),
        "schema = 6\n\n[skills.gh]\nsource = \"local\"\nnote = \"why I keep this\"\nenabled = true\n"
    );
}

/// A hand-written `enabled = true` inside a hook survives an edit to the
/// hook beside it. The target here is the real serializer's, not a
/// fixture's, because what a declaration field spells out is exactly the
/// question: a field the serialization leaves out must not read as a field
/// the manifest dropped.
#[test]
#[allow(clippy::unwrap_used)]
fn a_hand_written_enabled_flag_survives_a_hook_edit() {
    let current = "schema = 6\n\n[[custom-hooks]]\nevent = \"Stop\"\ncommand = \"./done.sh\"\nenabled = true   # still on\n";
    let mut manifest: Manifest = toml::from_str(current).unwrap();
    manifest.custom_hooks[0].command = "./finished.sh".to_owned();
    let desired = toml::to_string_pretty(&manifest).unwrap();
    assert_eq!(
        fold(current, &desired),
        "schema = 6\n\n[[custom-hooks]]\nevent = \"Stop\"\ncommand = \"./finished.sh\"\nenabled = true   # still on\n"
    );
}

/// A list written in two places with another table between them keeps
/// those places. Filling the array's entries into the first slots would
/// pull a surviving hook above a table that has nothing to do with it.
#[test]
fn a_split_hook_list_keeps_the_places_it_was_written_in() {
    let split = "schema = 6\n\n# first\n[[custom-hooks]]\nevent = \"Stop\"\ncommand = \"./a.sh\"\n\n[install]\nmethod = \"copy\"\n\n# second\n[[custom-hooks]]\nevent = \"Stop\"\ncommand = \"./b.sh\"\n";
    let keep_second = format!(
        "schema = 6\n\n[[custom-hooks]]\n{}\n[install]\nmethod = \"copy\"\n",
        hook("Stop", "./b.sh")
    );
    // Spelled out rather than built from `hook()` again: the helper is
    // already the target handed to the fold, and a helper on both sides
    // of one assertion cannot see itself drift.
    assert_eq!(
        fold(split, &keep_second),
        "schema = 6\n\n[install]\nmethod = \"copy\"\n\n# second\n[[custom-hooks]]\nevent = \"Stop\"\ncommand = \"./b.sh\"\n"
    );
}

/// The four things a declaration's `enabled` flag has to do. Every target
/// here comes from the real serializer, because what the serialization
/// spells out is the whole question: a flag reads as true when it is
/// absent, so writing it out puts a key in somebody's file that says
/// nothing the file did not already say.
#[allow(clippy::unwrap_used)]
fn rebound(current: &str, enabled: bool) -> String {
    let mut manifest: Manifest = toml::from_str(current).unwrap();
    let skill = manifest.skills.get_mut("gh").unwrap();
    skill.source = "local".to_owned();
    skill.enabled = enabled;
    let desired = toml::to_string_pretty(&manifest).unwrap();
    fold(current, &desired)
}

/// A declaration that left the flag out still leaves it out. This is the
/// Done-when: a write touches the keys the operation names and no others.
#[test]
fn a_declaration_that_omits_enabled_keeps_omitting_it() {
    let current = "schema = 6\n\n# mine\n[skills.gh]\nsource = \"cat\"\n";
    assert_eq!(
        rebound(current, true),
        "schema = 6\n\n# mine\n[skills.gh]\nsource = \"local\"\n"
    );
}

/// A flag somebody typed by hand stays, comment and spacing included. The
/// serialization leaves it out, and a key the serialization leaves out is
/// never read as a key the manifest dropped.
#[test]
fn a_hand_written_enabled_flag_stays_where_it_was_typed() {
    let current = "schema = 6\n\n[skills.gh]\nsource = \"cat\"\nenabled = true   # on purpose\n";
    assert_eq!(
        rebound(current, true),
        "schema = 6\n\n[skills.gh]\nsource = \"local\"\nenabled = true   # on purpose\n"
    );
}

/// A declaration switched off stays switched off: `false` is not the
/// default, so the serialization says it and the fold leaves it be.
#[test]
fn a_disabled_declaration_keeps_its_flag() {
    let current = "schema = 6\n\n[skills.gh]\nsource = \"cat\"\nenabled = false\n";
    assert_eq!(
        rebound(current, false),
        "schema = 6\n\n[skills.gh]\nsource = \"local\"\nenabled = false\n"
    );
}

/// Switching a disabled declaration back on deletes the line rather than
/// writing `enabled = true` over it. The flag is a key the manifest really
/// did hold and really did drop, so the sweep takes it — which is what
/// keeps the sweep from being a rule that only ever preserves.
#[test]
fn re_enabling_a_declaration_deletes_the_flag() {
    let current = "schema = 6\n\n[skills.gh]\nsource = \"cat\"\nenabled = false\n";
    assert_eq!(
        rebound(current, true),
        "schema = 6\n\n[skills.gh]\nsource = \"local\"\n"
    );
}

/// A list somebody annotated, in the spelling that annotates one: the
/// comment sits after the value, on its line. TOML stores each of those
/// against the value below it, so nothing here works by keeping an
/// entry's own decoration.
const ANNOTATED: &str = "schema = 6\n\n[suppressed]\nskill = [\n  \"alpha\",  # pulled in by gh\n  \"beta\",   # pulled in by fmt\n  \"gamma\",  # pulled in by rev\n]\n";

#[allow(clippy::unwrap_used)]
fn suppressing(names: &[&str]) -> String {
    let desired = format!(
        "schema = 6\n\n[suppressed]\nskill = [{}]\n",
        names
            .iter()
            .map(|name| format!("\"{name}\""))
            .collect::<Vec<_>>()
            .join(", ")
    );
    fold(ANNOTATED, &desired)
}

/// Losing the first entry takes that entry's own annotation and leaves
/// every other one where it was written.
#[test]
fn losing_the_first_entry_leaves_the_rest_annotated() {
    assert_eq!(
        suppressing(&["beta", "gamma"]),
        "schema = 6\n\n[suppressed]\nskill = [\n  \"beta\",   # pulled in by fmt\n  \"gamma\",  # pulled in by rev\n]\n"
    );
}

/// Losing a middle entry closes the gap without sliding the annotations
/// up with it — by position, `gamma` would inherit what was written about
/// `beta`.
#[test]
fn losing_a_middle_entry_does_not_slide_the_annotations() {
    assert_eq!(
        suppressing(&["alpha", "gamma"]),
        "schema = 6\n\n[suppressed]\nskill = [\n  \"alpha\",  # pulled in by gh\n  \"gamma\",  # pulled in by rev\n]\n"
    );
}

/// Losing the LAST entry is the case that stays broken longest: what was
/// written about the entry above it is stored inside the entry that goes,
/// so a fold that drops entries by their own bytes deletes an annotation
/// about something still in the list.
#[test]
fn losing_the_last_entry_keeps_the_annotation_above_it() {
    assert_eq!(
        suppressing(&["alpha", "beta"]),
        "schema = 6\n\n[suppressed]\nskill = [\n  \"alpha\",  # pulled in by gh\n  \"beta\",   # pulled in by fmt\n]\n"
    );
}

/// `Manifest::suppress` sorts the list on every removal, so an ordinary
/// `kendex remove` re-sorts a list somebody annotated. Each annotation
/// moves with the skill it was written about.
#[test]
fn re_sorting_a_list_moves_each_annotation_with_its_own_value() {
    assert_eq!(
        suppressing(&["gamma", "alpha", "beta"]),
        "schema = 6\n\n[suppressed]\nskill = [\n  \"gamma\",  # pulled in by rev\n  \"alpha\",  # pulled in by gh\n  \"beta\",   # pulled in by fmt\n]\n"
    );
}

/// The security-shaped instance: a denial somebody annotated must not end
/// up over a tool it no longer denies.
#[test]
fn dropping_a_denied_tool_takes_its_own_annotation() {
    let current = "schema = 6\n\n[agent-frontmatter.claude.rev]\ndeny-tools = [\n  \"Bash\",     # never lets it shell out\n  \"WebFetch\", # never lets it push\n]\n";
    let desired = "schema = 6\n\n[agent-frontmatter.claude.rev]\ndeny-tools = [\"WebFetch\"]\n";
    assert_eq!(
        fold(current, desired),
        "schema = 6\n\n[agent-frontmatter.claude.rev]\ndeny-tools = [\n  \"WebFetch\", # never lets it push\n]\n"
    );
}

/// A key gained inside an inline table lands before the closing brace,
/// not before the comma above it. The spacing an inline table keeps at its
/// brace belongs to the brace, and each spelling keeps its own.
#[test]
#[allow(clippy::unwrap_used)]
fn a_key_gained_inside_an_inline_table_reads_as_one() {
    for (current, expected) in [
        (
            "schema = 6\n\ncustom-hooks = [{ event = \"Stop\", command = \"./done.sh\" }]\n",
            "schema = 6\n\ncustom-hooks = [{ event = \"Stop\", command = \"./done.sh\", matcher = \"Bash\" }]\n",
        ),
        (
            "schema = 6\n\ncustom-hooks = [{event = \"Stop\", command = \"./done.sh\"}]\n",
            "schema = 6\n\ncustom-hooks = [{event = \"Stop\", command = \"./done.sh\", matcher = \"Bash\"}]\n",
        ),
    ] {
        let mut manifest: Manifest = toml::from_str(current).unwrap();
        manifest.custom_hooks[0].matcher = Some("Bash".to_owned());
        let desired = toml::to_string_pretty(&manifest).unwrap();
        assert_eq!(fold(current, &desired), expected);
    }
}

/// A list somebody wrote, folded against exactly what it already says.
/// The whole file has to come back byte for byte: a manifest write folds
/// every array in the file, so a run of bytes this cannot reproduce turns
/// each `kendex add` into a reformat of arrays nobody touched.
#[allow(clippy::unwrap_used)]
fn refolded(list: &str) -> String {
    rewritten(&format!("schema = 6\n\n[suppressed]\nskill = {list}\n"))
}

/// The file a write leaves behind when the manifest it carries is the one
/// this file already reads as. `save` builds exactly these two documents
/// and writes only where the bytes moved, so anything but the input back
/// is a key some operation landed without naming it.
#[allow(clippy::unwrap_used)]
fn rewritten(current: &str) -> String {
    let held: Manifest = toml::from_str(current).unwrap();
    let held = toml::to_string_pretty(&held).unwrap();
    merged(current, &held, &held).unwrap()
}

/// Every way a person can hold the bytes between the last value and the
/// bracket. TOML keeps them in the array's trailing text only when the
/// list ends with a comma; without one they are the last value's suffix,
/// and an array with no values keeps the whole span in its trailing.
#[test]
fn the_bytes_before_the_bracket_survive_however_they_are_kept() {
    for list in [
        // No trailing comma: the line break before `]` is the last
        // value's suffix, and nothing else in the file knows about it.
        "[\n  \"alpha\",\n  \"beta\"\n]",
        // The same, held on one line by spaces.
        "[ \"alpha\" ]",
        // An annotation written before the comma rather than after it,
        // which is the other place a suffix can hold a person's words.
        "[\n  \"alpha\" # the main one\n  ,\n  \"beta\",\n]",
        // No values at all, so there is no prefix to read the opening
        // line from and no suffix to read the closing one.
        "[\n]",
        "[\n  # none yet\n]",
        // The shapes that were already covered, so a fix for the ones
        // above cannot pay for itself here.
        "[\n  \"alpha\",\n]",
        "[\"alpha\", \"beta\"]",
    ] {
        assert_eq!(
            refolded(list),
            format!("schema = 6\n\n[suppressed]\nskill = {list}\n"),
            "folding {list} against itself must change nothing"
        );
    }
}

/// Emptying a list reaches its own end state in one write. A second fold
/// that moved another byte would mean the first left the file in a shape
/// kendex does not itself write, which invariant 11 does not allow.
#[test]
#[allow(clippy::unwrap_used)]
fn emptying_a_list_settles_in_one_write() {
    let current = "schema = 6\n\n[suppressed]\nskill = [\n  \"alpha\",\n]\n";
    let empty = "schema = 6\n\n[suppressed]\nskill = []\n";
    let once = fold(current, empty);
    assert_eq!(once, "schema = 6\n\n[suppressed]\nskill = [\n]\n");
    let held: Manifest = toml::from_str(&once).unwrap();
    let held = toml::to_string_pretty(&held).unwrap();
    assert_eq!(merged(&once, &held, empty).unwrap(), once);
}

/// An entry gained in the middle of a one-line list is separated once,
/// and takes nothing from the entry it displaced. Appending takes the
/// separator the same way and leaves none before the bracket.
#[test]
fn a_gained_entry_is_separated_once_wherever_it_lands() {
    let current = "schema = 6\n\n[suppressed]\nskill = [\"alpha\", \"zulu\"]\n";
    for names in [["alpha", "mike", "zulu"], ["alpha", "zulu", "mike"]] {
        let desired = format!(
            "schema = 6\n\n[suppressed]\nskill = [{}]\n",
            names
                .iter()
                .map(|name| format!("\"{name}\""))
                .collect::<Vec<_>>()
                .join(", ")
        );
        assert_eq!(fold(current, &desired), desired);
    }
}

/// A declaration that left a field out gets it back from nobody. Both
/// shapes here are the only ones in which their field's skip is reachable
/// at all: `[install]`'s own skip hides the harnesses question whenever
/// install is wholly default, and a plugin declares nothing else.
#[test]
fn a_write_names_no_field_a_declaration_left_out() {
    for current in [
        "schema = 6\n\n# how things install here\n[install]\nmethod = \"copy\"\n",
        "schema = 6\n\n[plugins.\"fmt@mkt\"]\nenabled = true\n",
    ] {
        assert_eq!(rewritten(current), current);
    }
}

/// A boundary, pinned rather than fixed. `Manifest::install` skips at its
/// default, so a manifest whose install is default spells no `[install]`
/// at all — and the sweep reads a table `held` names and the target does
/// not as a table the manifest dropped. Everything written against it
/// goes: the comment above the header, and a note left inside it.
///
/// Nothing reaches this today. An install goes from non-default to
/// default only if a write clears every harness or resets the method, and
/// nothing in the tree does either: the engine only adds harnesses, the
/// editor only refills them, and nothing writes the method at all. The
/// day something does, this case turns red here instead of quietly in
/// somebody's file.
#[test]
#[allow(clippy::unwrap_used)]
fn clearing_install_would_take_the_table_written_around_it() {
    let current = "schema = 6\n\n# how things install here\n[install]\nmethod = \"copy\"\nnote = \"why I chose copy\"\n";
    let mut manifest: Manifest = toml::from_str(current).unwrap();
    manifest.install = InstallDefaults::default();
    let desired = toml::to_string_pretty(&manifest).unwrap();
    assert_eq!(
        fold(current, &desired),
        "schema = 6\n",
        "the whole table goes, comment and note with it — the day a writer \
         can reach this, that is what it costs"
    );
}

/// What pairing by position costs, and what it buys, on one list. Nothing
/// identifies a value that changed — a changed value is a different value
/// — so it pairs by where it sat, lands on the slot it replaced, and
/// keeps what was written there.
///
/// Renaming every entry is the half that earns it: each stays an edit of
/// its own line rather than three drops and three appends, and each
/// annotation stays where the person put it. Replacing one entry with
/// another in the same write is the same mechanism read the other way,
/// and it costs: the new value stands under a note about the old one.
/// Neither is a defect the fold can tell apart from the other, so the
/// behaviour is pinned here rather than described.
#[test]
fn a_value_paired_by_position_keeps_the_note_written_in_its_slot() {
    assert_eq!(
        suppressing(&["one", "two", "three"]),
        "schema = 6\n\n[suppressed]\nskill = [\n  \"one\",  # pulled in by gh\n  \"two\",   # pulled in by fmt\n  \"three\",  # pulled in by rev\n]\n",
        "an edit of every entry is an edit of every line"
    );
    assert_eq!(
        suppressing(&["alpha", "delta", "gamma"]),
        "schema = 6\n\n[suppressed]\nskill = [\n  \"alpha\",  # pulled in by gh\n  \"delta\",   # pulled in by fmt\n  \"gamma\",  # pulled in by rev\n]\n",
        "and the price of it: delta stands under what was written about beta"
    );
}

/// The other reading of the same pairing, measured rather than argued.
/// Identity places every target entry it can before position places any,
/// so a list holding one value twice hands the earlier slot to the copy
/// that survived; the entry edited out of that slot finds it taken, lands
/// as one the list did not have, and the annotation on the slot nobody
/// claimed goes with nobody.
///
/// It is not a defect the fold can see: a value edited in place and a
/// value that was always there are the same bytes. Pinned here so the
/// sentence in `identity` has the case it describes under it, and so the
/// day the pairing changes this reads red rather than surprising
/// somebody.
#[test]
fn a_repeated_value_leaves_an_edited_neighbour_unpaired() {
    let current = "schema = 6\n\n[suppressed]\nskill = [\n  \"a\",  # first a\n  \"a\",  # second a\n  \"b\",  # only b\n]\n";
    let desired = "schema = 6\n\n[suppressed]\nskill = [\"pi\", \"a\", \"b\"]\n";
    assert_eq!(
        fold(current, desired),
        "schema = 6\n\n[suppressed]\nskill = [\n  \"pi\",\n  \"a\",  # first a\n  \"b\",  # only b\n]\n",
        "the surviving copy keeps the earlier slot, and second a's line goes"
    );
}

/// The editor's path, which is where a hand-written manifest is actually
/// edited. `hook::name_custom_hooks` stamps a derived name onto every
/// hook the editor saves, so the target carries names the file does not,
/// and pairing on names alone places nothing at all — the whole list falls
/// to position, and dropping the first hook seats the survivor under the
/// dropped hook's comment.
///
/// The names are stamped by the real function rather than written here:
/// what the target looks like on that path is the thing under test.
#[test]
#[allow(clippy::unwrap_used)]
fn a_hook_the_editor_has_just_named_pairs_with_the_one_it_names() {
    let current = "schema = 6\n\n# guards every bash call\n[[custom-hooks]]\nevent = \"PreToolUse\"\ncommand = \"./guard.sh\"\n\n# says we are done\n[[custom-hooks]]\nevent = \"Stop\"\ncommand = \"./done.sh\"\n";
    let mut manifest: Manifest = toml::from_str(current).unwrap();
    manifest.custom_hooks.remove(0);
    assert!(
        crate::hook::name_custom_hooks(&mut manifest),
        "the editor names what it saves, and this case is nothing without it"
    );
    let desired = toml::to_string_pretty(&manifest).unwrap();

    assert_eq!(
        fold(current, &desired),
        format!(
            "schema = 6\n\n# says we are done\n[[custom-hooks]]\nevent = \"Stop\"\ncommand = \"./done.sh\"\nname = \"{}\"\n",
            manifest.custom_hooks[0].name.as_deref().unwrap()
        ),
        "the hook that survived keeps its own comment, not the deleted one's, \
         and the name it gained lands under the keys already written"
    );
}
