use super::*;
use crate::error::CoreError;
use crate::model::ItemKind;

#[test]
fn round_trips_the_binding_skeleton() {
    let text = r#"
schema = 6

[sources.kendex]
repo = "vanillagreencom/kendex"
enabled = true

[install]
harnesses = ["claude", "pi"]
method = "symlink"

[agents.orch]
source = "kendex"

[skills.github]
source = "kendex"
method = "copy"
enabled = false

[agent-skills]
orch = ["github"]

[agent-frontmatter.claude.orch]
model = "opus"
deny-tools = ["WebSearch"]

[[custom-hooks]]
event = "PreToolUse"
matcher = "Bash"
command = "./guard.sh"

[skill-instructions]
github = "prefer gh cli"
"#;
    let tmp = tempfile::tempdir().unwrap();
    let path = tmp.path().join("kendex.toml");
    std::fs::write(&path, text).unwrap();

    let ManifestFile::Current(manifest) = load(&path).unwrap() else {
        panic!("expected current manifest");
    };
    assert_eq!(
        manifest.sources["kendex"].repo.as_deref(),
        Some("vanillagreencom/kendex")
    );
    assert_eq!(
        manifest.install.harnesses,
        [HarnessId::Claude, HarnessId::Pi]
    );
    assert!(!manifest.skills["github"].enabled);
    assert_eq!(manifest.skills["github"].method, Some(Method::Copy));
    assert_eq!(
        manifest.agent_frontmatter["claude"]["orch"].deny_tools,
        Some(vec!["WebSearch".to_owned()])
    );
    assert_eq!(manifest.custom_hooks[0].event, "PreToolUse");

    save(&path, &manifest).unwrap();
    let ManifestFile::Current(reloaded) = load(&path).unwrap() else {
        panic!("expected current manifest after save");
    };
    assert_eq!(reloaded, manifest);
}

/// The tables schema 6 retired. A file still carrying them is a file from
/// before schema 6, and it is refused whole rather than read with the
/// records quietly dropped — the drop would go durable on the next write,
/// over every other byte the person put there.
#[test]
#[allow(clippy::unwrap_used)]
fn safety_decision_tables_are_refused_with_the_file_they_are_in() {
    let tmp = tempfile::tempdir().unwrap();
    let path = tmp.path().join("kendex.toml");
    let recorded = r#"
schema = 5

[sources.cat]
repo = "owner/repo"

[skills.deploy]
source = "cat"

[safety-overrides."skill:deploy:claude"]
review-hash = "abc"
ruleset = 3
findings = ["f1"]
granted-at = "2026-01-01T00:00:00Z"

[safety-reviews."skill:deploy:claude"]
review-hash = "abc"
ruleset = 3

[safety-reviews."skill:deploy:claude".dismissed.f2]
reason = "intended"
dismissed-at = "2026-01-01T00:00:00Z"
"#;
    std::fs::write(&path, recorded).unwrap();

    let refused = load_for_mutation(&path).unwrap_err();
    assert!(
        matches!(refused, CoreError::LegacyManifest { .. }),
        "{refused}"
    );
    assert!(refused.to_string().contains("schema 5"), "{refused}");
    assert_eq!(
        std::fs::read_to_string(&path).unwrap(),
        recorded,
        "and the file is left exactly as it was written"
    );
}

#[test]
fn schema_less_file_is_refused_and_never_a_mutation_target() {
    let tmp = tempfile::tempdir().unwrap();
    let path = tmp.path().join("kendex.toml");
    let v1 = "[agent-skills]\nrust = [\"clippy\"]\n";
    std::fs::write(&path, v1).unwrap();

    assert!(matches!(load(&path), Err(CoreError::LegacyManifest { .. })));
    assert!(matches!(
        load_for_mutation(&path),
        Err(CoreError::LegacyManifest { .. })
    ));
    assert_eq!(std::fs::read_to_string(&path).unwrap(), v1);
}

#[test]
fn seed_declares_the_default_source_once() {
    let manifest = seed(&[HarnessId::Claude]);
    // Spelled out: a fresh scope seeds the post-rename name and repo.
    assert_eq!(
        manifest.sources["kendex"].repo.as_deref(),
        Some("vanillagreencom/kendex")
    );
    assert!(manifest.sources[DEFAULT_SOURCE_NAME].enabled);
    assert_eq!(manifest.declared(ItemKind::Agent).len(), 0);
    assert_eq!(manifest.install.harnesses, [HarnessId::Claude]);
}

#[test]
fn source_catalog_routes_install_state_to_a_sibling() {
    use crate::env::{Env, FakeOs};
    use crate::model::Scope;

    let tmp = tempfile::tempdir().unwrap();
    let root = tmp.path();
    let env = Env::fake(root, FakeOs::Linux);
    let scope = Scope::Project {
        root: root.to_path_buf(),
    };

    // No catalog marker: install state lives in the project's own kendex.toml.
    assert_eq!(
        crate::manifest::manifest_path(&env, &scope)
            .file_name()
            .unwrap(),
        "kendex.toml",
    );

    // A source catalog keeps kendex.toml as its definition and routes install
    // state to the sibling instead.
    std::fs::write(
        root.join("kendex.toml"),
        "is_source_catalog = true\n[marketplace]\nname = \"c\"\n",
    )
    .unwrap();
    assert!(crate::manifest::is_source_catalog(root));
    assert_eq!(
        crate::manifest::manifest_path(&env, &scope)
            .file_name()
            .unwrap(),
        "kendex-local.toml",
    );

    // The flag off is not a catalog: back to the project's own kendex.toml.
    std::fs::write(root.join("kendex.toml"), "is_source_catalog = false\n").unwrap();
    assert!(!crate::manifest::is_source_catalog(root));
    assert_eq!(
        crate::manifest::manifest_path(&env, &scope)
            .file_name()
            .unwrap(),
        "kendex.toml",
    );
}

/// A fold with `held` derived the way `save` derives it: the manifest this
/// very document reads back as, spelled by the serializer that spelled the
/// target.
#[allow(clippy::unwrap_used)]
fn fold(current: &str, desired: &str) -> String {
    let held: Manifest = toml::from_str(current).unwrap();
    let held = toml::to_string_pretty(&held).unwrap();
    super::fold::folded(current, &held, desired).unwrap()
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
            agents: super::default_hook_agents(),
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
    assert!(super::fold::folded("schema = ", "schema = 6\n", "schema = 6\n").is_err());
}
