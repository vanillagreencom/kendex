//! What the scope offers an agent's skill assignment: everything its own
//! checkouts hold. Too narrow refuses a fork over a skill that is right
//! there.

use std::fs;

use super::*;

/// A source's own assignment names skills out of its catalog, and the
/// refusal weighs them against the scope. So the scope supplies what a
/// source offers, declared or not: read as installed-only, a fork is
/// refused over the skill the render just wrote the row for.
#[test]
#[allow(clippy::unwrap_used)]
fn a_skill_a_source_only_offers_answers_the_assignment_it_makes() {
    let w = world();
    write_skill(&w.upstream, "spare", "Spare.");
    write_agent(&w.upstream, "rev", "Upstream body.");
    fs::write(
        w.upstream.join("kendex.toml"),
        "[agent-skills]\nrev = [\"spare\"]\n",
    )
    .unwrap();
    commit(&w.upstream, "one");

    // Nothing declares `spare`: the catalog offers it and the agent it
    // carries is the only thing asking for it.
    let path = manifest::manifest_path(&w.env, &w.scope);
    fs::create_dir_all(path.parent().unwrap()).unwrap();
    fs::write(
        &path,
        format!(
            "schema = 6\n\n[sources.cat]\nrepo = \"{REPO}\"\n\n[install]\nharnesses = [\"gemini\"]\nmethod = \"symlink\"\n\n[agents.rev]\nsource = \"cat\"\n"
        ),
    )
    .unwrap();
    sync_and_apply(&w);

    let file = rendered(&w, HarnessId::Gemini, "rev");
    let before = fs::read_to_string(&file).unwrap();
    assert_eq!(before.matches("- spare: ").count(), 1, "{before}");
    edit_body(&file);

    let plan = fork::fork(&w.env, &w.scope, ItemKind::Agent, "rev", HarnessId::Gemini).unwrap();
    apply::execute(&w.env, &plan).unwrap();
    resettle(&w);

    let text = fs::read_to_string(&file).unwrap();
    assert_eq!(text.matches("- spare: ").count(), 1, "{text}");
}
