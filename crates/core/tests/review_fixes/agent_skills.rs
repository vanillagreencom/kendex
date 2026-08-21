//! What an agent renders with: the skill list, resolved once and read once.
//!
//! The manifest holds the person's declaration; the mapping turns it into
//! the list the agent actually has — filtered to what is installed, with
//! whatever upstream added since the last sync merged back in. Reading the
//! declaration again anywhere else is how a rendering and the manifest end
//! up disagreeing about what an agent carries.

use std::fs;

use super::{add_skill, apply_now, declare, loaded_manifest, project, put, world};

/// The rendering reads the skill list the mapping resolved, not the raw
/// `[agent-skills]` entry: filtered to what is actually installed, and
/// carrying whatever upstream gained during this very pass. Reading the
/// entry directly renders an agent pointing at a skill that is not there.
#[test]
#[allow(clippy::unwrap_used)]
fn an_agent_renders_the_skills_it_actually_has() {
    let w = world();
    let scope = project(&w);
    declare(
        &w,
        &scope,
        "[agents.rust]\nsource = \"cat\"\n\n[agent-skills]\nrust = [\"gh\", \"ghost\"]\n",
    );
    apply_now(&w, &scope);
    let rendered = w.home.join("dev/app/.claude/agents/rust.md");
    let first = fs::read_to_string(&rendered).unwrap();
    assert!(first.contains("skills: gh"), "{first}");
    assert!(
        !first.contains("ghost"),
        "a declared skill this catalog does not carry is not rendered: {first}"
    );

    // And what upstream gained this pass is in what this pass wrote.
    add_skill(&w.source, "rust-perf");
    apply_now(&w, &scope);
    assert_eq!(
        loaded_manifest(&w, &scope).agent_skills["rust"],
        ["gh", "ghost", "rust-perf"]
    );
    let second = fs::read_to_string(&rendered).unwrap();
    assert!(second.contains("rust-perf"), "{second}");
    assert!(!second.contains("ghost"), "{second}");
}

/// A reviewer agent's declaration is read under its base agent's key, so a
/// rendering that asked only for the full name would find no declaration
/// and put the source's own prefix matches back — the removal undone on
/// every apply, and the person's list never durable.
#[test]
#[allow(clippy::unwrap_used)]
fn a_declaration_under_the_base_agents_key_holds_on_the_first_apply() {
    let w = world();
    let scope = project(&w);
    add_skill(&w.source, "rust-perf");
    put(
        &w.source.join("agents/reviewer-rust.md"),
        "---\nname: reviewer-rust\ndescription: Rust reviewer\nmodel: opus\nrole: reviewer\n---\n\nBody.\n",
    );
    declare(
        &w,
        &scope,
        "[agents.reviewer-rust]\nsource = \"cat\"\n\n[agent-skills]\nrust = [\"gh\"]\n",
    );
    apply_now(&w, &scope);

    let rendered =
        fs::read_to_string(w.home.join("dev/app/.claude/agents/reviewer-rust.md")).unwrap();
    assert!(rendered.contains("skills: gh"), "{rendered}");
    assert!(
        !rendered.contains("rust-perf"),
        "the prefix match the declaration replaced does not come back: {rendered}"
    );
}
