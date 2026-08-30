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

/// Keeping the declaration means the plan writes the manifest nowhere, so
/// the upstream skill merge that would want a save waits for the refresh:
/// the agent renders and records as it stands, and the refresh merges what
/// upstream added. An agent whose upstream skill list grew is what makes
/// the planner want that save.
#[test]
#[allow(clippy::unwrap_used)]
fn keeping_the_declaration_drops_the_planners_own_manifest_save() {
    let w = world();
    let scope = project(&w);
    declare(
        &w,
        &scope,
        "[skills.gh]\nsource = \"cat\"\n\n[agents.rust]\nsource = \"cat\"\n\n[agent-skills]\nrust = [\"gh\"]\n",
    );
    apply_now(&w, &scope);
    add_skill(&w.source, "rust-perf");
    let path = super::manifest::manifest_path(&w.env, &scope);
    let before = fs::read_to_string(&path).unwrap();
    let rendered = w.home.join("dev/app/.claude/agents/rust.md");
    let rendered_before = fs::read_to_string(&rendered).unwrap();
    let recorded = |w: &super::World| {
        super::load_lock(&super::lock_path(&w.env, &scope))
            .unwrap()
            .entries
            .values()
            .find(|entry| entry.name == "rust")
            .unwrap()
            .upstream_skills
            .clone()
    };
    let recorded_before = recorded(&w);
    assert!(
        super::persists_manifest(&super::audit(&w.env, &scope).unwrap().plan.ops),
        "the fixture must make the planner save the manifest on its own"
    );

    let report = super::ops::uninstall(&w.env, &scope, &["gh".to_owned()]).unwrap();
    assert!(
        !super::persists_manifest(&report.plan.ops),
        "{:?}",
        report.plan.ops
    );
    super::apply::execute(&w.env, &report.plan).unwrap();
    assert_eq!(fs::read_to_string(&path).unwrap(), before);
    assert!(before.contains("[skills.gh]"));
    assert!(!w.home.join("dev/app/.claude/skills/gh").exists());
    assert_eq!(fs::read_to_string(&rendered).unwrap(), rendered_before);
    assert_eq!(recorded(&w), recorded_before);

    // The refresh after it still sees the addition and merges it.
    let next = super::audit(&w.env, &scope).unwrap();
    let merged = next.plan.ops.iter().find_map(|op| match &op.op {
        super::apply::Op::WriteManifest { manifest, .. } => {
            Some(manifest.agent_skills["rust"].clone())
        }
        _ => None,
    });
    assert_eq!(merged.unwrap(), ["gh", "rust-perf"]);
}

/// A reviewer agent reads its base agent's `[agent-skills]` entry by
/// prefix. Taking the base agent away with the declaration kept must leave
/// that entry in the transient manifest, or the reviewer is re-rendered
/// from its upstream list and its record rewritten for nothing.
#[test]
#[allow(clippy::unwrap_used)]
fn keeping_the_declaration_leaves_a_reviewers_skill_list_alone() {
    let w = world();
    let scope = project(&w);
    put(
        &w.source.join("agents/reviewer-rust.md"),
        "---\nname: reviewer-rust\ndescription: Rust reviewer\nmodel: opus\nrole: reviewer\n---\n\nBody.\n",
    );
    declare(
        &w,
        &scope,
        "[skills.gh]\nsource = \"cat\"\n\n[agents.rust]\nsource = \"cat\"\n\n[agents.reviewer-rust]\nsource = \"cat\"\n\n[agent-skills]\nrust = [\"gh\"]\n",
    );
    apply_now(&w, &scope);
    let reviewer = w.home.join("dev/app/.claude/agents/reviewer-rust.md");
    let rendered_before = fs::read_to_string(&reviewer).unwrap();
    let entry = |w: &super::World| {
        super::load_lock(&super::lock_path(&w.env, &scope))
            .unwrap()
            .entries
            .remove("agent:reviewer-rust:claude")
            .unwrap()
    };
    let entry_before = entry(&w);

    let report = super::ops::uninstall(&w.env, &scope, &["rust".to_owned()]).unwrap();
    super::apply::execute(&w.env, &report.plan).unwrap();
    assert!(!w.home.join("dev/app/.claude/agents/rust.md").exists());
    assert_eq!(fs::read_to_string(&reviewer).unwrap(), rendered_before);
    assert_eq!(entry(&w), entry_before);
}
