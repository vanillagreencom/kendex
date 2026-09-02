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

/// The same document as the case above, under another name, and that is the
/// point: replacing an entry with an unrelated one and editing the entry that
/// was there produce byte-identical input, differing only in how much the new
/// entry resembles the old. So a replacement inherits the slot's comment and
/// the `note` inside it. This is not independent evidence — it cannot red
/// while the edit case passes — it is the claim written down where the prose
/// that describes it can be checked against it.
#[test]
fn an_entry_replacing_another_inherits_what_was_written_in_its_slot() {
    assert_eq!(
        folding(NOTED, |manifest| {
            manifest.custom_hooks[1] = CustomHook {
                name: None,
                event: "Notification".to_owned(),
                matcher: None,
                command: "./ping.sh".to_owned(),
                description: None,
                timeout: None,
                harnesses: None,
                enabled: true,
                agents: crate::manifest::default_hook_agents(),
            };
        }),
        NOTED
            .replace("event = \"Stop\"", "event = \"Notification\"")
            .replace("./done.sh", "./ping.sh")
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

/// `deny-tools` as a bare list, so a case can state the whole span.
fn deny(list: &str) -> String {
    format!("schema = 6\n\n[agent-frontmatter.claude.orch]\ndeny-tools = {list}\n")
}

/// A gained entry is placed against what is already there, in every shape a
/// list can be in when it has nothing to place it against. An empty list has
/// no entry to take an indent from, one whose first entry shares the opening
/// line says nothing about the margin, and a list holding only a comment says
/// it in the whitespace holding its bracket out.
#[test]
fn a_gained_value_is_placed_against_the_list_it_lands_in() {
    let one = |list: &str, add: &[&str]| {
        folding(&deny(list), |manifest| {
            denied(manifest).extend(add.iter().map(|tool| (*tool).to_owned()));
        })
    };
    assert_eq!(one("[]", &["Bash"]), deny("[\"Bash\"]"));
    assert_eq!(one("[]", &["aaa", "zzz"]), deny("[\"aaa\", \"zzz\"]"));
    assert_eq!(
        one("[\n  # nothing yet\n]", &["Bash"]),
        deny("[\n  \"Bash\"\n  # nothing yet\n]")
    );
    assert_eq!(
        one("[\"Bash\",\n  \"Write\",\n]", &["Edit"]),
        deny("[\"Bash\",\n  \"Write\",\n  \"Edit\",\n]")
    );
    assert_eq!(
        folding(&deny("[\n  \"Bash\",\n  \"Write\",\n]"), |manifest| {
            denied(manifest).insert(0, "Agent".to_owned());
        }),
        deny("[\n  \"Agent\",\n  \"Bash\",\n  \"Write\",\n]")
    );
}

/// The run before `]` belongs to the bracket. An entry that stood mid-list
/// carries the separator that led to the neighbour after it, so an entry
/// promoted to last by a removal must not bring it: the space before the
/// bracket would be a separator to nothing.
#[test]
fn removing_the_last_entry_leaves_no_separator_behind() {
    assert_eq!(
        folding(&deny("[\"Bash\", \"Write\"]"), |manifest| {
            denied(manifest).pop();
        }),
        deny("[\"Bash\"]")
    );
    // The same in the other spelling, and the same run one level in: the
    // spacing before an inline table's brace sits on whichever key is last, so
    // an entry that loses that key must hand the run back to the brace. Here
    // `matcher` is written last and is what the strip takes.
    let inline = "schema = 6\ncustom-hooks = [{ event = \"A\", command = \"c\", matcher = \"x\" }, { event = \"B\", command = \"d\" }]\n";
    assert_eq!(
        folding(inline, |manifest| {
            manifest.custom_hooks.pop();
        }),
        "schema = 6\ncustom-hooks = [{ event = \"A\", command = \"c\", matcher = \"x\" }]\n"
    );
    assert_eq!(
        folding(inline, |manifest| {
            manifest.custom_hooks.remove(0);
            manifest.custom_hooks[0].command = "z".to_owned();
        }),
        "schema = 6\ncustom-hooks = [{ event = \"B\", command = \"z\" }]\n"
    );
}

/// Where the run before `]` is kept depends on a comma: the array's trailing
/// text when the list ends with one, the last value's suffix when it does not.
/// A write naming another key entirely must return either spelling byte for
/// byte — reading the wrong one deletes the comment on the last entry, or the
/// space before the bracket.
#[test]
fn a_list_that_ends_without_a_comma_comes_back_whole() {
    let elsewhere = |current: &str| {
        folding(current, |manifest| {
            manifest.install.method = Method::Copy;
        })
    };
    let gained = "\n[install]\nmethod = \"copy\"\n";
    let broken = deny("[\n  \"Bash\",\n  \"Write\"   # the last one\n]");
    assert_eq!(elsewhere(&broken), format!("{broken}{gained}"));
    let flat = deny("[\"Bash\", \"Write\" ]");
    assert_eq!(elsewhere(&flat), format!("{flat}{gained}"));
}

/// Three hooks, each under its own comment, the first and last carrying a
/// `note` the model does not hold.
const THREE: &str = "schema = 6\n\n# about A\n[[custom-hooks]]\nevent = \"PreToolUse\"\ncommand = \"./guard.sh\"\nnote = \"a note\"\n\n# about B\n[[custom-hooks]]\nevent = \"Stop\"\ncommand = \"./done.sh\"\n\n# about C\n[[custom-hooks]]\nevent = \"Notification\"\ncommand = \"./ping.sh\"\nnote = \"c note\"\n";

/// Whether an entry keeps the keys in its slot is asked per entry, not of the
/// list. What decides it is whether the slot was FORCED: the entries `held`
/// recognized hold their own places, so an unrecognized entry between two of
/// them can only have come from a slot between the same two.
///
/// Three shapes the list's own length gets wrong. A same-length write that
/// removes one entry and adds another moves the added one into the removed
/// one's slot, so its `note` must not follow. A write that only ADDS still
/// leaves an entry unplaceable — two looking for one free slot — so neither is
/// its own. And a removal well AFTER the changed entry leaves that entry's
/// slot forced, so it keeps everything written about it.
#[test]
fn the_keys_in_a_slot_go_only_where_the_slot_was_not_the_entrys_own() {
    let ping = || CustomHook {
        name: None,
        event: "Notification".to_owned(),
        matcher: None,
        command: "./ping.sh".to_owned(),
        description: None,
        timeout: None,
        harnesses: None,
        enabled: true,
        agents: crate::manifest::default_hook_agents(),
    };
    // Same length, one out and one in: the arrival stands in A's slot, under
    // A's comment, and carries none of A's keys.
    assert_eq!(
        folding(NOTED, |manifest| {
            manifest.custom_hooks.remove(0);
            manifest.custom_hooks.push(ping());
        }),
        "schema = 6\n\n# about B\n[[custom-hooks]]\nevent = \"Stop\"\ncommand = \"./done.sh\"\nnote = \"b note\"\n\n# about A\n[[custom-hooks]]\nevent = \"Notification\"\ncommand = \"./ping.sh\"\n"
    );
    // Longer, and nothing removed: two entries nothing recognized compete for
    // the one free slot, so neither of them is standing in its own.
    assert_eq!(
        folding(NOTED, |manifest| {
            manifest.custom_hooks[1].command = "./z.sh".to_owned();
            manifest.custom_hooks.push(ping());
        }),
        "schema = 6\n\n# about A\n[[custom-hooks]]\nevent = \"PreToolUse\"\ncommand = \"./guard.sh\"\nnote = \"a note\"\n\n# about B\n[[custom-hooks]]\nevent = \"Stop\"\ncommand = \"./z.sh\"\n\n[[custom-hooks]]\nevent = \"Notification\"\ncommand = \"./ping.sh\"\n"
    );
    // Same length, nothing in or out, and the keys still go: two changes side
    // by side leave each other unplaceable — either could have come from
    // either slot — so neither is standing in one anything can call its own.
    assert_eq!(
        folding(THREE, |manifest| {
            manifest.custom_hooks[0].command = "./g2.sh".to_owned();
            manifest.custom_hooks[1].command = "./d2.sh".to_owned();
        }),
        THREE
            .replace("./guard.sh", "./g2.sh")
            .replace("./done.sh", "./d2.sh")
            .replace(
                "command = \"./g2.sh\"\nnote = \"a note\"\n",
                "command = \"./g2.sh\"\n"
            )
    );
    // Shorter, and the removal is after the change: the changed entry is
    // bounded by the anchor below it and one free slot, so it kept its own.
    assert_eq!(
        folding(THREE, |manifest| {
            manifest.custom_hooks.pop();
            manifest.custom_hooks[0].command = "./g2.sh".to_owned();
        }),
        "schema = 6\n\n# about A\n[[custom-hooks]]\nevent = \"PreToolUse\"\ncommand = \"./g2.sh\"\nnote = \"a note\"\n\n# about B\n[[custom-hooks]]\nevent = \"Stop\"\ncommand = \"./done.sh\"\n"
    );
}

/// A comment after the `[` or before the `]` is about the list, not about any
/// entry in it, so emptying the list keeps it. The lines the entries stood on
/// are theirs and go with them, which is why a list carrying nothing but
/// whitespace between its brackets closes as `[]`.
///
/// Both halves in both spellings of the closing run, since which slot holds
/// the bytes before `]` turns on a trailing comma.
#[test]
fn emptying_a_list_keeps_what_was_written_about_the_list() {
    let empty = |list: &str| {
        folding(&deny(list), |manifest| {
            denied(manifest).clear();
        })
    };
    assert_eq!(
        empty("[   # what we deny\n  \"Bash\",\n]"),
        deny("[   # what we deny\n]")
    );
    assert_eq!(
        empty("[   # what we deny\n  \"Bash\"\n]"),
        deny("[   # what we deny\n]")
    );
    assert_eq!(
        empty("[\n  \"Bash\",\n  # keep this\n]"),
        deny("[\n  # keep this\n]")
    );
    assert_eq!(
        empty("[\n  \"Bash\"\n  # keep this\n]"),
        deny("[\n  # keep this\n]")
    );
    assert_eq!(empty("[\n  \"Bash\",\n]"), deny("[]"));
}
