//! What a copy taken under a new name declares: the rename itself, the
//! kinds carrying no name anything keys on, and the refusals that decide
//! before the first byte is written.

use std::fs;
use std::path::Path;

use super::{file_item, find, raw_skill, seeded, selection, target};
use crate::author::import::{apply, inventory};
use crate::model::Scope;

/// What the catalog check makes of what one import wrote, read as the
/// person's own marketplace: how many items it found, and every breakage
/// over them. The count is half the answer — a check that read nothing
/// reports no breakage either.
#[allow(clippy::unwrap_used)]
fn checked(target: &Path) -> (usize, Vec<String>) {
    let sealed = crate::source_read::SealedSource::open(target).unwrap();
    let check = crate::check_catalog::check(&sealed, "mine").unwrap();
    let breakage = check
        .findings()
        .filter(|finding| finding.is_breakage() && !finding.is_note())
        .map(|finding| format!("{}: {}", finding.file, finding.message))
        .collect();
    (check.tally().items, breakage)
}

/// A copy taken under a new name has to declare that name: a skill copied
/// verbatim under a renamed destination lands a SKILL.md calling it
/// something else, which the catalog check reports as breakage — run here
/// over what the import wrote, so this holds only as long as it does.
///
/// Both shapes: the flat rename, and the nested destination it was
/// reported against.
#[test]
#[allow(clippy::unwrap_used)]
fn a_renamed_skill_declares_its_destination_and_leaves_the_catalog_whole() {
    let (tmp, env, scope) = seeded();
    let scopes = [scope.clone()];
    let target = target(&env, &tmp, "mine-renamed");
    fs::write(
        target.join("kendex.toml"),
        "[marketplace]\nname = \"mine\"\n",
    )
    .unwrap();
    let candidates = inventory(&env, &scopes).unwrap();
    let mut flat = selection(find(&candidates, "stray"), false);
    flat.destination = "renamed".to_owned();
    let mut nested = selection(find(&candidates, "mine"), false);
    nested.destination = "group/deep".to_owned();

    let selections = [flat, nested];

    let outcome = apply(&env, &scopes, &target, &selections).unwrap();
    assert_eq!(outcome.written, ["skills/renamed", "skills/group/deep"]);

    let flat_md = fs::read_to_string(target.join("skills/renamed/SKILL.md")).unwrap();
    assert!(flat_md.contains("name: renamed"), "{flat_md}");
    assert!(
        flat_md.contains("unmanaged bytes") && flat_md.contains("description: about stray"),
        "only the name line changes: {flat_md}"
    );
    // The rest of the tree is a copy. A rewrite reaching a body file would
    // refuse the whole import, because a file with no frontmatter has no
    // line to carry a name, so a skill with a references/ directory could
    // not be imported under a new name at all.
    let Scope::Project { root } = &scope else {
        unreachable!()
    };
    assert_eq!(
        fs::read(target.join("skills/renamed/references/notes.md")).unwrap(),
        fs::read(root.join(".claude/skills/stray/references/notes.md")).unwrap(),
        "the tree's body files are copied, not declared",
    );
    let nested_md = fs::read_to_string(target.join("skills/group/deep/SKILL.md")).unwrap();
    assert!(nested_md.contains("name: deep"), "{nested_md}");

    let (items, breakage) = checked(&target);
    assert_eq!(items, 2, "the check read both imported trees");
    assert_eq!(breakage, Vec::<String>::new());

    // The bytes on disk are what the same selection would write again, so
    // a repeated import is already present rather than someone else's.
    let again = apply(&env, &scopes, &target, &selections).unwrap();
    assert_eq!(
        again.already_present,
        ["skills/renamed", "skills/group/deep"]
    );
    assert!(again.written.is_empty());
}

/// An import that keeps the candidate's name copies its bytes verbatim,
/// nested destination included: the leaf is the name a declaration
/// carries, so moving a skill into a directory renames nothing.
#[test]
#[allow(clippy::unwrap_used)]
fn an_import_that_keeps_the_leaf_copies_the_bytes_untouched() {
    let (tmp, env, scope) = seeded();
    let scopes = [scope.clone()];
    let target = target(&env, &tmp, "mine-kept");
    let candidates = inventory(&env, &scopes).unwrap();
    let mut moved = selection(find(&candidates, "stray"), false);
    moved.destination = "group/stray".to_owned();
    // A tree carrying no frontmatter is copied as it is, rather than
    // refused for a name nobody asked to change.
    let bare = selection(find(&candidates, "bare"), false);

    apply(&env, &scopes, &target, &[moved, bare]).unwrap();

    let Scope::Project { root } = &scope else {
        unreachable!()
    };
    assert_eq!(
        fs::read(target.join("skills/group/stray/SKILL.md")).unwrap(),
        fs::read(root.join(".claude/skills/stray/SKILL.md")).unwrap(),
    );
    assert_eq!(
        fs::read_to_string(target.join("skills/bare/SKILL.md")).unwrap(),
        "No frontmatter at all.\n",
    );
}

/// The rename is decided with every other refusal, before the first byte:
/// bytes no name can be written into refuse the whole apply rather than
/// land a copy that still answers to the old name.
#[test]
#[allow(clippy::unwrap_used)]
fn a_rename_no_declaration_can_carry_refuses_and_writes_nothing() {
    let (tmp, env, scope) = seeded();
    let scopes = [scope];
    let target = target(&env, &tmp, "mine-uncarried");
    let candidates = inventory(&env, &scopes).unwrap();
    let mut renamed = selection(find(&candidates, "bare"), false);
    renamed.destination = "clothed".to_owned();
    let selections = [selection(find(&candidates, "mine"), false), renamed];

    let message = apply(&env, &scopes, &target, &selections)
        .unwrap_err()
        .to_string();
    assert!(message.contains("it has no frontmatter"), "{message}");
    assert!(message.contains("'clothed'"), "{message}");
    assert!(
        message.contains("still call itself 'bare'"),
        "and what the copy would have answered to: {message}"
    );
    assert!(
        !target.join("skills").exists(),
        "a refused apply writes nothing at all"
    );
}

/// The refusal spells the names it quotes rather than replaying them. A
/// candidate name is read off a directory on disk, so it can hold anything
/// a filesystem accepts — a bidi override included — and the inventory
/// keeps illegal spellings on purpose, so the wizard can offer them under
/// a legal destination. That offer is the path into this refusal, and a
/// raw override reaching a terminal is the terminal's to obey.
///
/// The name carries U+202E, the right-to-left override that would let one
/// package read as another. It is the threat `names::shown` exists for,
/// and unlike a control character it is a filename every platform this
/// runs on will create, so the fixture is the same on all three.
#[test]
#[allow(clippy::unwrap_used)]
fn a_refusal_escapes_the_candidate_name_it_quotes() {
    let (tmp, env, scope) = seeded();
    let Scope::Project { root } = &scope else {
        unreachable!()
    };
    raw_skill(
        &root.join(".claude/skills"),
        "ba\u{202e}re",
        "No frontmatter at all.\n",
    );
    let scopes = [scope.clone()];
    let target = target(&env, &tmp, "mine-escaped");
    let candidates = inventory(&env, &scopes).unwrap();
    let mut renamed = selection(find(&candidates, "ba\u{202e}re"), false);
    renamed.destination = "clothed".to_owned();

    let message = apply(&env, &scopes, &target, &[renamed])
        .unwrap_err()
        .to_string();
    assert!(message.contains("ba\\u{202e}re"), "{message}");
    assert!(!message.contains('\u{202e}'), "{message:?}");
}

/// A namespaced candidate landing under its own name is no rename. What a
/// file inside an item declares is the leaf — it knows nothing of the
/// namespace it is installed under — so `kit/gadget` copied to
/// `kit/gadget` changes nothing, a declaration that was already wrong at
/// the origin included: this is a copy, not a repair.
#[test]
#[allow(clippy::unwrap_used)]
fn a_namespaced_candidate_kept_under_its_own_name_is_no_rename() {
    let (tmp, env, scope) = seeded();
    let Scope::Project { root } = &scope else {
        unreachable!()
    };
    // A namespaced candidate comes off the scan as the directory it sits
    // in plus its own stem, and the name its frontmatter gives is neither.
    let declared = "---\nname: misdeclared\ndescription: about gadget\n---\nAgent body.\n";
    file_item(&root.join(".claude/agents/kit"), "gadget.md", declared);
    let scopes = [scope.clone()];
    let target = target(&env, &tmp, "mine-namespaced");
    let candidates = inventory(&env, &scopes).unwrap();

    apply(
        &env,
        &scopes,
        &target,
        &[selection(find(&candidates, "kit/gadget"), false)],
    )
    .unwrap();

    assert_eq!(
        fs::read_to_string(target.join("agents/kit/gadget.md")).unwrap(),
        declared,
    );
}

/// Bytes that are not text carry no declaration either, and the refusal
/// says so rather than landing a copy whose name line is a replacement
/// character. A skill's tree is read as bytes, so nothing upstream has
/// asked whether its declaration is text.
#[test]
#[allow(clippy::unwrap_used)]
fn a_rename_of_bytes_that_are_not_text_refuses() {
    let (tmp, env, scope) = seeded();
    let Scope::Project { root } = &scope else {
        unreachable!()
    };
    let dir = root.join(".claude/skills/binary");
    fs::create_dir_all(&dir).unwrap();
    fs::write(dir.join("SKILL.md"), [0xff, 0xfe, b'\n']).unwrap();
    let scopes = [scope.clone()];
    let target = target(&env, &tmp, "mine-binary");
    let candidates = inventory(&env, &scopes).unwrap();
    let mut renamed = selection(find(&candidates, "binary"), false);
    renamed.destination = "textual".to_owned();
    // A selection that would have been written first, so the folder
    // staying empty is the refusal beating the copy rather than there
    // being nothing to copy.
    let selections = [selection(find(&candidates, "mine"), false), renamed];

    let message = apply(&env, &scopes, &target, &selections)
        .unwrap_err()
        .to_string();
    assert!(message.contains("the file is not text"), "{message}");
    assert!(
        !target.join("skills").exists(),
        "a refused apply writes nothing at all"
    );
}

/// What every other kind does under a rename, as a fixture rather than a
/// claim in a comment.
///
/// An agent's own file carries the name its tool answers to, so a renamed
/// agent declares its destination. The other three carry no name anything
/// keys on and are copied byte for byte.
///
/// All three are real candidates: a hook and an MCP server reach the
/// wizard through a lock entry pointing at the local source, which is how
/// they are seeded here.
#[test]
#[allow(clippy::unwrap_used)]
fn a_renamed_agent_declares_its_destination_and_the_name_less_kinds_are_copied_verbatim() {
    let (tmp, env, scope) = seeded();
    let scopes = [scope.clone()];
    let target = target(&env, &tmp, "mine-kinds");
    let candidates = inventory(&env, &scopes).unwrap();
    let renamed_to = |name: &str, destination: &str| {
        let mut chosen = selection(find(&candidates, name), false);
        chosen.destination = destination.to_owned();
        chosen
    };
    let selections = [
        renamed_to("drifter", "settled"),
        renamed_to("note", "memo"),
        renamed_to("watcher", "sentry"),
        renamed_to("server", "relay"),
    ];

    apply(&env, &scopes, &target, &selections).unwrap();

    let written = fs::read_to_string(target.join("agents/settled.md")).unwrap();
    assert!(written.contains("name: settled"), "{written}");
    assert!(
        written.contains("description: about drifter") && written.contains("Agent body."),
        "only the name line changes: {written}"
    );
    let Scope::Project { root } = &scope else {
        unreachable!()
    };
    let local = root.join(crate::source::LOCAL_SOURCE_DIR);
    for (landed, origin) in [
        ("commands/memo.md", root.join(".claude/commands/note.md")),
        ("hooks/sentry.sh", local.join("hooks/watcher.sh")),
        ("mcp/relay.toml", local.join("mcp/server.toml")),
    ] {
        assert_eq!(
            fs::read(target.join(landed)).unwrap(),
            fs::read(&origin).unwrap(),
            "{landed} is a copy, not a declaration",
        );
    }
}

/// An illegal namespace is not a rename. The inventory keeps illegal names
/// on purpose so the wizard can offer them under a legal destination, and
/// that is the path here: `-bad/tuned` landing at `tuned` changes no leaf,
/// because a file inside an item only ever declares its leaf.
///
/// The Codex agent is the case that made it matter. For a frontmatter file
/// the needless rewrite is only wasted work; for that one it refuses an
/// import that asked for no rename at all.
#[test]
#[allow(clippy::unwrap_used)]
fn an_illegal_namespace_over_the_same_leaf_is_no_rename() {
    let (tmp, env, scope) = seeded();
    let Scope::Project { root } = &scope else {
        unreachable!()
    };
    let toml = "name = \"tuned\"\ndescription = \"about tuned\"\n";
    file_item(&root.join(".codex/agents/-bad"), "tuned.toml", toml);
    let declared = "---\nname: kept\ndescription: about kept\n---\nAgent body.\n";
    file_item(&root.join(".claude/agents/-bad"), "kept.md", declared);
    let scopes = [scope.clone()];
    let target = target(&env, &tmp, "mine-illegal");
    let candidates = inventory(&env, &scopes).unwrap();
    let landing = |name: &str, destination: &str| {
        let mut chosen = selection(find(&candidates, name), false);
        chosen.destination = destination.to_owned();
        chosen
    };

    // A plain leaf and a legal namespace, the two repairs the wizard offers.
    let selections = [
        landing("-bad/tuned", "tuned"),
        landing("-bad/kept", "good/kept"),
    ];
    apply(&env, &scopes, &target, &selections).unwrap();

    assert_eq!(
        fs::read_to_string(target.join("agents/tuned.md")).unwrap(),
        toml,
    );
    assert_eq!(
        fs::read_to_string(target.join("agents/good/kept.md")).unwrap(),
        declared,
    );
}

/// A parked agent keeps its content at `<name>.md.disabled`, so the file
/// the bytes come from ends in a suffix that is not a format at all. The
/// bytes are the frontmatter they always were, so it renames like any
/// other agent — which is the whole reason the bytes are asked rather than
/// the filename.
#[test]
#[allow(clippy::unwrap_used)]
fn a_renamed_parked_agent_declares_its_destination() {
    let (tmp, env, scope) = seeded();
    let Scope::Project { root } = &scope else {
        unreachable!()
    };
    file_item(
        &root.join(".claude/agents"),
        "parked.md.disabled",
        "---\nname: parked\ndescription: about parked\n---\nAgent body.\n",
    );
    let scopes = [scope.clone()];
    let target = target(&env, &tmp, "mine-parked");
    let candidates = inventory(&env, &scopes).unwrap();
    let mut renamed = selection(find(&candidates, "parked"), false);
    renamed.destination = "roused".to_owned();

    apply(&env, &scopes, &target, &[renamed]).unwrap();

    let written = fs::read_to_string(target.join("agents/roused.md")).unwrap();
    assert!(written.contains("name: roused"), "{written}");
    assert!(
        written.contains("description: about parked") && written.contains("Agent body."),
        "only the name line changes: {written}"
    );
}

/// What decides is the format, not the extension it wears. A Cursor rule
/// is `.mdc` and carries frontmatter, so it is renamed like any other
/// agent: it lands in the catalog's markdown slot declaring the
/// destination, and refusing it would take away a rename that worked.
#[test]
#[allow(clippy::unwrap_used)]
fn a_renamed_cursor_agent_declares_its_destination() {
    let (tmp, env, scope) = seeded();
    let Scope::Project { root } = &scope else {
        unreachable!()
    };
    file_item(
        &root.join(".cursor/rules"),
        "ruler.mdc",
        "---\ndescription: about ruler\nalwaysApply: false\n---\nRule body.\n",
    );
    let scopes = [scope.clone()];
    let target = target(&env, &tmp, "mine-cursor");
    let candidates = inventory(&env, &scopes).unwrap();
    let mut renamed = selection(find(&candidates, "ruler"), false);
    renamed.destination = "measured".to_owned();

    apply(&env, &scopes, &target, &[renamed]).unwrap();

    let written = fs::read_to_string(target.join("agents/measured.md")).unwrap();
    assert!(written.contains("name: measured"), "{written}");
    assert!(
        written.contains("description: about ruler") && written.contains("Rule body."),
        "only the name line changes: {written}"
    );
}

/// An agent is not always frontmatter: Codex reads its agents as TOML and
/// an unmanaged scan offers those like any other, so a rename arrives here
/// with bytes that carry a `name` key and no frontmatter at all. It
/// refuses, and names the file it read, so the person can see the format
/// the answer is about — rather than being sent off to add a frontmatter
/// block that the harness would then refuse to load.
#[test]
#[allow(clippy::unwrap_used)]
fn a_renamed_agent_in_another_format_is_refused_by_that_format() {
    let (tmp, env, scope) = seeded();
    let Scope::Project { root } = &scope else {
        unreachable!()
    };
    file_item(
        &root.join(".codex/agents"),
        "codexer.toml",
        "name = \"codexer\"\ndescription = \"about codexer\"\n",
    );
    let scopes = [scope.clone()];
    let target = target(&env, &tmp, "mine-codex");
    let candidates = inventory(&env, &scopes).unwrap();
    let mut renamed = selection(find(&candidates, "codexer"), false);
    renamed.destination = "settled".to_owned();

    let message = apply(&env, &scopes, &target, &[renamed])
        .unwrap_err()
        .to_string();
    assert!(message.contains("'codexer.toml'"), "{message}");
    assert!(
        message.contains("still call itself 'codexer'"),
        "and what the copy would have answered to: {message}"
    );
    // Never the instruction to add one: a Codex agent with a frontmatter
    // block on top is an agent Codex will not load.
    assert!(!message.contains("give it a frontmatter"), "{message}");
}
