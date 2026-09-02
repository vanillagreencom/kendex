//! What a fold leaves behind, spelled on documents rather than on manifests:
//! every case here is a shape somebody can legally write in kendex.toml, and
//! the assertion is on the bytes.

use crate::manifest::{CustomHook, Manifest, Method, SourceDecl};

/// A fold with `held` derived the way `save` derives it: the manifest this
/// very document reads back as, spelled by the serializer that spelled the
/// target.
#[allow(clippy::unwrap_used)]
fn fold(current: &str, desired: &str) -> String {
    let held: Manifest = toml::from_str(current).unwrap();
    let held = toml::to_string_pretty(&held).unwrap();
    super::folded(current, &held, desired).unwrap()
}

/// [`fold`] against the target `save` would build: the document read back
/// through the model, `change` applied, spelled by the real serializer. What
/// that serializer leaves out at a default is the whole subject of several
/// cases below, so none of them writes the target by hand.
#[allow(clippy::unwrap_used)]
fn folding(current: &str, change: impl FnOnce(&mut Manifest)) -> String {
    let mut manifest: Manifest = toml::from_str(current).unwrap();
    change(&mut manifest);
    fold(current, &toml::to_string_pretty(&manifest).unwrap())
}

/// A gained table lands after the tables already in the file, not where the
/// serializer's field order would put it. `[sources.*]` sorts before every
/// `[skills.*]` in the target, and this file has three of those, so a gained
/// source carrying the target's own position would be spliced between two
/// skills the write never named.
#[test]
fn a_gained_table_lands_after_the_tables_already_there() {
    let current = "schema = 6\n\n[skills.aa]\nsource = \"cat\"\n\n[skills.bb]\nsource = \"cat\"\n\n[skills.cc]\nsource = \"cat\"\n\n[sources.cat]\npath = \"x\"\n";
    assert_eq!(
        folding(current, |manifest| {
            manifest.sources.insert(
                "other".to_owned(),
                SourceDecl {
                    repo: None,
                    path: Some("y".to_owned()),
                    rev: None,
                    enabled: true,
                },
            );
        }),
        format!("{current}\n[sources.other]\npath = \"y\"\n")
    );
}

/// A write that names another key entirely leaves a hand-written list alone,
/// byte for byte, including a value the serializer omits because it is the
/// default. The omission is not a change: `held` never names `enabled`
/// either, so nothing reads it as one.
///
/// The list is spelled inline while the serializer spells it
/// `[[custom-hooks]]`, which is the shape that has to fold across the two
/// spellings rather than be rewritten into one of them. Two entries, each
/// with its own writing, so a rewrite shows up as more than a re-indent.
#[test]
fn an_unrelated_write_leaves_a_hand_written_list_alone() {
    let current = "schema = 6\n\n# both of the hooks we run\ncustom-hooks = [\n  { event = \"Stop\", command = \"./done.sh\", enabled = true },   # after every run\n  { event = \"PreToolUse\", command = \"./guard.sh\" },\n]\n\n[install]\nmethod = \"symlink\"\n";
    assert_eq!(
        folding(current, |manifest| {
            manifest.install.method = Method::Copy;
        }),
        current.replace("\"symlink\"", "\"copy\"")
    );
}

/// The spacing an inline table keeps before its closing brace belongs to the
/// brace, not to whichever key sits last. A gained key takes that place, so
/// the run moves with the brace instead of being stranded before the comma.
#[test]
fn a_gained_key_leaves_the_closing_brace_where_it_was() {
    let current = "schema = 6\nsources.cat = { path = \"x\" }\n";
    assert_eq!(
        folding(current, |manifest| {
            if let Some(source) = manifest.sources.get_mut("cat") {
                source.rev = Some("main".to_owned());
            }
        }),
        "schema = 6\nsources.cat = { path = \"x\", rev = \"main\" }\n"
    );
}

/// A list that loses an entry still folds entry by entry, so the surviving
/// hook keeps the comment written above it and the `note` the model does not
/// carry — and stands once, not twice. Each entry carries its own comment, so
/// a survivor seated in the wrong slot reads as the wrong hook rather than as
/// an unannotated one.
///
/// The list loses its FIRST entry, which is the shape that pairs wrongly under
/// any positional scheme: the survivor would fold into the deleted hook's slot
/// and come back under `# the guard`.
#[test]
fn a_surviving_entry_keeps_what_was_written_about_it() {
    let current = "schema = 6\n\n# the guard\n[[custom-hooks]]\nevent = \"PreToolUse\"\ncommand = \"./guard.sh\"\n\n# the one that stays\n[[custom-hooks]]\nevent = \"Stop\"\ncommand = \"./done.sh\"\nnote = \"keep me\"\n";
    assert_eq!(
        folding(current, |manifest| {
            manifest.custom_hooks.remove(0);
        }),
        "schema = 6\n\n# the one that stays\n[[custom-hooks]]\nevent = \"Stop\"\ncommand = \"./done.sh\"\nnote = \"keep me\"\n"
    );
}

/// A re-sorted list comes back in its new order, each entry still under the
/// comment written about it. The desktop editor hands the hook list back in
/// whatever order it holds (`editor::custom_hook_deliveries` assigns it
/// wholesale), so a swap is a real write. Survivors keep their own places, so
/// the places have to be redealt in the order the entries now stand in or the
/// file renders in the order they used to.
#[test]
fn a_re_sorted_list_renders_in_its_new_order() {
    let current = "schema = 6\n\n# guards every bash call\n[[custom-hooks]]\nevent = \"PreToolUse\"\ncommand = \"./guard.sh\"\n\n# and this one at the end\n[[custom-hooks]]\nevent = \"Stop\"\ncommand = \"./done.sh\"\n";
    assert_eq!(
        folding(current, |manifest| {
            manifest.custom_hooks.swap(0, 1);
        }),
        "schema = 6\n\n# and this one at the end\n[[custom-hooks]]\nevent = \"Stop\"\ncommand = \"./done.sh\"\n\n# guards every bash call\n[[custom-hooks]]\nevent = \"PreToolUse\"\ncommand = \"./guard.sh\"\n"
    );
}

/// An inline list gains its entry inline. The two spellings say the same
/// thing, so the one on disk is the one that is edited and no `[[custom-hooks]]`
/// header is emitted over a key the person wrote as a value.
#[test]
fn an_inline_list_gains_its_entry_inline() {
    let current = "schema = 6\ncustom-hooks = [{ event = \"Stop\", command = \"./done.sh\" }]\n";
    let written = folding(current, |manifest| {
        manifest.custom_hooks.push(CustomHook {
            name: None,
            event: "PreToolUse".to_owned(),
            matcher: None,
            command: "./guard.sh".to_owned(),
            description: None,
            timeout: None,
            harnesses: None,
            enabled: true,
            agents: crate::manifest::default_hook_agents(),
        });
    });
    assert!(!written.contains("[[custom-hooks"), "{written}");
    assert_eq!(
        written,
        "schema = 6\ncustom-hooks = [{ event = \"Stop\", command = \"./done.sh\" }, { event = \"PreToolUse\", command = \"./guard.sh\" }]\n"
    );
}

/// The layout round trip, over one document holding every shape a write can
/// reach. Untouched: a header comment, hand spacing, a key order no
/// serializer would choose, an inline table, a trailing comment, a list, a
/// `[[custom-hooks]]` array whose entry carries a flag and a note the
/// serializer omits at its default, and `note`, a key the model does not
/// hold at all. Touched: one changed value, which keeps the writing around it; one
/// key the manifest dropped, which goes with its own line; one table it
/// gained, which lands under the tables already there.
#[test]
fn a_write_edits_the_keys_it_names_and_leaves_the_document_alone() {
    let current = "# my setup\nschema  =  6\n\n# where it comes from\nsources.cat = { path = 'x', enabled = true }\n\n[install]\nharnesses = [\"claude\"]\nmethod   =   \"copy\"   # for now\n\n[skills.gh]\nsource = \"cat\"\nnote = \"why I keep this\"\nenabled = false\n\n# guards every bash call\n[[custom-hooks]]\nevent = \"Stop\"\ncommand = \"./done.sh\"\nenabled = true   # still on\n";
    let desired = "schema = 6\n\n[install]\nharnesses = [\"claude\"]\nmethod = \"symlink\"\n\n[skills.gh]\nsource = \"cat\"\n\n[skills.fmt]\nsource = \"cat\"\n\n[sources.cat]\npath = \"x\"\n\n[[custom-hooks]]\nevent = \"Stop\"\ncommand = \"./done.sh\"\n";
    assert_eq!(
        fold(current, desired),
        "# my setup\nschema  =  6\n\n# where it comes from\nsources.cat = { path = 'x', enabled = true }\n\n[install]\nharnesses = [\"claude\"]\nmethod   =   \"symlink\"   # for now\n\n[skills.gh]\nsource = \"cat\"\nnote = \"why I keep this\"\n\n[skills.fmt]\nsource = \"cat\"\n\n# guards every bash call\n[[custom-hooks]]\nevent = \"Stop\"\ncommand = \"./done.sh\"\nenabled = true   # still on\n"
    );
}

/// A document that already says what kendex holds comes back byte for byte,
/// which is what lets `save` skip the write entirely.
#[test]
fn a_document_that_already_agrees_is_returned_unchanged() {
    let current = "# my setup\nschema  =  6\n\n# where it comes from\n[sources.cat]\npath = 'x'   # local\nenabled = true\n\n[install]\nharnesses = [\n  \"claude\",\n]\n\n[skills.gh]\nsource = \"cat\"\n";
    let desired = "schema = 6\n\n[install]\nharnesses = [\"claude\"]\n\n[skills.gh]\nsource = \"cat\"\n\n[sources.cat]\npath = \"x\"\n";
    assert_eq!(fold(current, desired), current);
}

/// What a file ends in is its own: the blank line somebody left at the
/// bottom is not a key any write names.
#[test]
fn the_files_own_terminator_survives() {
    let current = "schema = 6\n\n[skills.gh]\nsource = \"cat\"\n\n";
    let desired = "schema = 6\n\n[skills.gh]\nsource = \"cat\"\n";
    assert_eq!(fold(current, desired), current);
}

/// A document that does not parse is refused, so a write never replaces a
/// file kendex could not read.
#[test]
fn an_unparsable_document_is_refused() {
    assert!(super::folded("schema = ", "schema = 6\n", "schema = 6\n").is_err());
}

/// The tools an agent is denied, as somebody annotates them: a comment after
/// each of two entries, on the lines those entries sit on.
const DENIED: &str = "schema = 6\n\n[agent-frontmatter.claude.orch]\ndeny-tools = [\n  \"Bash\",   # no shells\n  \"Write\",   # no writing files\n  \"WebFetch\",\n]\n";

/// The tools' own list, with `deny-tools` reached through the model.
#[allow(clippy::unwrap_used)]
fn denied(manifest: &mut Manifest) -> &mut Vec<String> {
    manifest
        .agent_frontmatter
        .get_mut("claude")
        .unwrap()
        .get_mut("orch")
        .unwrap()
        .deny_tools
        .as_mut()
        .unwrap()
}

/// A re-sorted array of VALUES moves each comment with the value it was
/// written about. TOML keeps the run between one value and the next against
/// the LOWER value, so an annotation is stored on the entry below the one it
/// describes; rebuilding from raw decoration hands it to whatever lands in
/// that slot, and every comment then states something false.
///
/// `Manifest::suppress` sorts on every removal and the desktop editor rewrites
/// these lists wholesale, so this is an ordinary `kendex remove` away.
#[test]
fn a_re_sorted_array_of_values_keeps_each_comment_on_its_own_value() {
    assert_eq!(
        folding(DENIED, |manifest| denied(manifest).sort()),
        "schema = 6\n\n[agent-frontmatter.claude.orch]\ndeny-tools = [\n  \"Bash\",   # no shells\n  \"WebFetch\",\n  \"Write\",   # no writing files\n]\n"
    );
}

/// A dropped value takes its own comment and leaves every other comment on the
/// value it was written about — including the entry above it, whose annotation
/// is stored in the dropped entry's own decoration.
#[test]
fn a_dropped_value_takes_its_own_comment_and_no_other() {
    assert_eq!(
        folding(DENIED, |manifest| {
            denied(manifest).remove(1);
        }),
        "schema = 6\n\n[agent-frontmatter.claude.orch]\ndeny-tools = [\n  \"Bash\",   # no shells\n  \"WebFetch\",\n]\n"
    );
}

/// A gained value takes the shape the list is already in — the indent its
/// neighbours use and a line of its own — rather than the serializer's, and a
/// list nothing is left in closes on the bracket it opened on.
#[test]
fn a_gained_value_takes_the_shape_the_list_is_in() {
    assert_eq!(
        folding(DENIED, |manifest| denied(manifest).push("Edit".to_owned())),
        DENIED.replace("\"WebFetch\",\n]", "\"WebFetch\",\n  \"Edit\",\n]")
    );
    assert_eq!(
        folding(DENIED, |manifest| denied(manifest).clear()),
        "schema = 6\n\n[agent-frontmatter.claude.orch]\ndeny-tools = []\n"
    );
    // Flat lists keep being flat, and a gained entry is separated once
    // wherever it lands.
    let flat =
        "schema = 6\n\n[agent-frontmatter.claude.orch]\ndeny-tools = [\"Bash\", \"Write\"]\n";
    assert_eq!(
        folding(flat, |manifest| denied(manifest)
            .insert(0, "Agent".to_owned())),
        flat.replace("[\"Bash\"", "[\"Agent\", \"Bash\"")
    );
}

/// Two hooks, each with its own comment and its own `note` — a key the model
/// does not carry.
const NOTED: &str = "schema = 6\n\n# about A\n[[custom-hooks]]\nevent = \"PreToolUse\"\ncommand = \"./guard.sh\"\nnote = \"a note\"\n\n# about B\n[[custom-hooks]]\nevent = \"Stop\"\ncommand = \"./done.sh\"\nnote = \"b note\"\n";

/// The ordinary hook write: one entry's command edited, nothing removed. An
/// edited entry matches no `held` entry, so it can only keep its slot through
/// the positional pairing — and while the list keeps its length that slot is
/// its own, so the comment above it and the `note` inside it are still about
/// it and both stand. Pairing it with nothing instead loses both.
#[test]
fn an_edited_entry_keeps_the_writing_around_it_and_inside_it() {
    assert_eq!(
        folding(NOTED, |manifest| {
            manifest.custom_hooks[1].command = "./finish.sh".to_owned();
        }),
        NOTED.replace("./done.sh", "./finish.sh")
    );
}

/// A removal moves every slot after it, so an entry nothing identified is
/// standing where another declaration stood. It keeps what was written AROUND
/// that slot — `# about A`, the price pairing in order has always had — and
/// none of the keys INSIDE it: `a note` stays in the declaration that went
/// rather than reappearing in one a person never put it in.
#[test]
fn an_entry_in_another_declarations_slot_carries_none_of_its_keys() {
    assert_eq!(
        folding(NOTED, |manifest| {
            manifest.custom_hooks.remove(0);
            manifest.custom_hooks[0].command = "./finish.sh".to_owned();
        }),
        "schema = 6\n\n# about A\n[[custom-hooks]]\nevent = \"Stop\"\ncommand = \"./finish.sh\"\n"
    );
}
