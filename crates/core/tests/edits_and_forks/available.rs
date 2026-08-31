//! What the scope offers an agent's skill assignment, and what it must
//! not. Too narrow refuses a fork over a skill that is installed; too wide
//! answers an assignment with a `## Required Skills` row pointing at
//! instructions no plan writes.

use std::fs;

use kendex_core::error::CoreError;

use super::*;

/// An item may pin its own revision, outranking the source's. A skill
/// carried only at that pinned commit is planned and readable, so the scan
/// has to read the pinned checkout too — reading the source's own revision
/// alone calls the skill absent and refuses a fork assigned to it.
#[test]
#[allow(clippy::unwrap_used)]
fn a_skill_only_a_pin_carries_is_not_called_unavailable() {
    let w = world();
    write_skill(&w.upstream, "recon", "Recon.");
    write_agent(&w.upstream, "rev", "Upstream body.");
    fs::write(
        w.upstream.join("kendex.toml"),
        "[agent-skills]\nrev = [\"recon\"]\n",
    )
    .unwrap();
    commit(&w.upstream, "one");
    let pinned = head_commit(&w.upstream);
    // Upstream drops the skill. Only the pin still carries it.
    fs::remove_dir_all(w.upstream.join("skills/recon")).unwrap();
    fs::write(w.upstream.join("kendex.toml"), "").unwrap();
    commit(&w.upstream, "two");

    let path = manifest::manifest_path(&w.env, &w.scope);
    fs::create_dir_all(path.parent().unwrap()).unwrap();
    fs::write(
        &path,
        format!(
            "schema = 6\n\n[sources.cat]\nrepo = \"{REPO}\"\n\n[install]\nharnesses = [\"gemini\"]\nmethod = \"symlink\"\n\n[agents.rev]\nsource = \"cat\"\n\n[skills.recon]\nsource = \"cat\"\nrev = \"{pinned}\"\n\n[agent-skills]\nrev = [\"recon\"]\n"
        ),
    )
    .unwrap();
    sync_and_apply(&w);
    let file = rendered(&w, HarnessId::Gemini, "rev");
    let before = fs::read_to_string(&file).unwrap();
    assert_eq!(times(&before, "## Required Skills"), 1, "{before}");
    edit_body(&file);

    let plan = fork::fork(&w.env, &w.scope, ItemKind::Agent, "rev", HarnessId::Gemini).unwrap();
    apply::execute(&w.env, &plan).unwrap();
    resettle(&w);

    let text = fs::read_to_string(&file).unwrap();
    assert_eq!(times(&text, "## Required Skills"), 1, "{text}");
    assert_eq!(text.matches("- recon: ").count(), 1, "{text}");
}

/// A pin belongs in the inventory because a pinned skill outranks its
/// source and still supplies what an agent reads. A pin on anything else
/// reads no skill out of its revision, so an old commit's since-removed
/// skills are not the scope's to offer: counted, a fork assigned one
/// passes the refusal and renders a row pointing at a file no plan writes.
#[test]
#[allow(clippy::unwrap_used)]
fn a_pin_on_another_kind_does_not_supply_its_revisions_skills() {
    let w = world();
    write_skill(&w.upstream, "ghost", "Ghost.");
    write_agent(&w.upstream, "rev", "Upstream body.");
    write_agent(&w.upstream, "other", "Other body.");
    commit(&w.upstream, "one");
    let pinned = head_commit(&w.upstream);
    // The skill goes; the agent the pin holds stays.
    fs::remove_dir_all(w.upstream.join("skills/ghost")).unwrap();
    commit(&w.upstream, "two");

    let path = manifest::manifest_path(&w.env, &w.scope);
    fs::create_dir_all(path.parent().unwrap()).unwrap();
    fs::write(
        &path,
        format!(
            "schema = 6\n\n[sources.cat]\nrepo = \"{REPO}\"\n\n[install]\nharnesses = [\"gemini\"]\nmethod = \"symlink\"\n\n[agents.rev]\nsource = \"cat\"\n\n[agents.other]\nsource = \"cat\"\nrev = \"{pinned}\"\n\n[agent-skills]\nrev = [\"ghost\"]\n"
        ),
    )
    .unwrap();
    sync_and_apply(&w);

    let file = rendered(&w, HarnessId::Gemini, "rev");
    let before = fs::read_to_string(&file).unwrap();
    assert_eq!(times(&before, "## Required Skills"), 0, "{before}");
    edit_body(&file);

    match fork::fork(&w.env, &w.scope, ItemKind::Agent, "rev", HarnessId::Gemini) {
        Err(CoreError::AgentSkillUnavailable { name, skill }) => {
            assert_eq!((name.as_str(), skill.as_str()), ("rev", "ghost"))
        }
        other => panic!("a skill no plan installs must not pass the refusal: {other:?}"),
    }
}

/// A set names its members; whether the catalog carries one is a separate
/// question, and the planner asks it before installing any of them. Read
/// without asking, a member nothing can install is offered to an agent's
/// assignment — the inventory saying a skill is available when no plan
/// will ever write it, which satisfies the refusal instead of raising it.
#[test]
#[allow(clippy::unwrap_used)]
fn a_set_member_the_catalog_lacks_is_not_offered() {
    let w = world();
    write_agent(&w.upstream, "rev", "Upstream body.");
    // The set names `ghost`; the catalog has never carried it.
    fs::write(
        w.upstream.join("kendex.toml"),
        "[bundles.kit]\ndescription = \"kit\"\nskills = [\"ghost\"]\n",
    )
    .unwrap();
    commit(&w.upstream, "one");
    let pinned = head_commit(&w.upstream);

    let path = manifest::manifest_path(&w.env, &w.scope);
    fs::create_dir_all(path.parent().unwrap()).unwrap();
    fs::write(
        &path,
        format!(
            "schema = 6\n\n[sources.cat]\nrepo = \"{REPO}\"\n\n[install]\nharnesses = [\"gemini\"]\nmethod = \"symlink\"\n\n[agents.rev]\nsource = \"cat\"\n\n[bundles.kit]\nsource = \"cat\"\nrev = \"{pinned}\"\n\n[agent-skills]\nrev = [\"ghost\"]\n"
        ),
    )
    .unwrap();
    sync_and_apply(&w);

    let file = rendered(&w, HarnessId::Gemini, "rev");
    let before = fs::read_to_string(&file).unwrap();
    assert_eq!(times(&before, "## Required Skills"), 0, "{before}");
    edit_body(&file);

    // Said out loud, not passed over: the assignment names a skill nothing
    // in this scope can install.
    match fork::fork(&w.env, &w.scope, ItemKind::Agent, "rev", HarnessId::Gemini) {
        Err(CoreError::AgentSkillUnavailable { name, skill }) => {
            assert_eq!((name.as_str(), skill.as_str()), ("rev", "ghost"))
        }
        other => panic!("a set member nothing can install must not satisfy it: {other:?}"),
    }
}

/// A declaration that lands on no tool is dropped from the plan, so what
/// it names is never written. Offered anyway, it answers an agent's
/// assignment with a file nothing installs — the same fail-open direction
/// as a set member the catalog lacks, by a different route.
///
/// The fixture reaches "lands nowhere" through a declaration that targets
/// no tool. Every tool holds a skill in a project, so a restricted
/// declaration only lands nowhere in a global scope, and both spellings
/// meet at the same empty answer from the planner.
#[test]
#[allow(clippy::unwrap_used)]
fn a_pinned_skill_that_lands_nowhere_is_not_offered() {
    let w = pinned_only_world(
        "[skills.recon]\nsource = \"cat\"\nrev = \"REV\"\nharnesses = []\n",
        "",
    );
    let file = rendered(&w, HarnessId::Gemini, "rev");
    let before = fs::read_to_string(&file).unwrap();
    assert_eq!(times(&before, "## Required Skills"), 0, "{before}");
    edit_body(&file);

    match fork::fork(&w.env, &w.scope, ItemKind::Agent, "rev", HarnessId::Gemini) {
        Err(CoreError::AgentSkillUnavailable { name, skill }) => {
            assert_eq!((name.as_str(), skill.as_str()), ("rev", "recon"))
        }
        other => panic!("a skill no tool can hold must not satisfy it: {other:?}"),
    }
}

/// The set branch answers the same question about its members: a set that
/// lands on no tool installs none of them, so none of them is the scope's
/// to offer.
#[test]
#[allow(clippy::unwrap_used)]
fn a_set_member_that_lands_nowhere_is_not_offered() {
    let w = pinned_only_world(
        "[bundles.kit]\nsource = \"cat\"\nrev = \"REV\"\nharnesses = []\n",
        "[bundles.kit]\ndescription = \"kit\"\nskills = [\"recon\"]\n",
    );
    let file = rendered(&w, HarnessId::Gemini, "rev");
    let before = fs::read_to_string(&file).unwrap();
    assert_eq!(times(&before, "## Required Skills"), 0, "{before}");
    edit_body(&file);

    match fork::fork(&w.env, &w.scope, ItemKind::Agent, "rev", HarnessId::Gemini) {
        Err(CoreError::AgentSkillUnavailable { name, skill }) => {
            assert_eq!((name.as_str(), skill.as_str()), ("rev", "recon"))
        }
        other => panic!("a set member no tool can hold must not satisfy it: {other:?}"),
    }
}

/// A settled scope where `recon` exists only at the pinned revision, so
/// the pinned declaration is the whole of what could offer it. `REV` in
/// `declaration` stands for that commit; `catalog` is the catalog's own
/// `kendex.toml` at it.
#[allow(clippy::unwrap_used)]
fn pinned_only_world(declaration: &str, catalog: &str) -> World {
    let w = world();
    write_skill(&w.upstream, "recon", "Recon.");
    write_agent(&w.upstream, "rev", "Upstream body.");
    fs::write(w.upstream.join("kendex.toml"), catalog).unwrap();
    commit(&w.upstream, "one");
    let pinned = head_commit(&w.upstream);
    fs::remove_dir_all(w.upstream.join("skills/recon")).unwrap();
    fs::write(w.upstream.join("kendex.toml"), "").unwrap();
    commit(&w.upstream, "two");

    let path = manifest::manifest_path(&w.env, &w.scope);
    fs::create_dir_all(path.parent().unwrap()).unwrap();
    fs::write(
        &path,
        format!(
            "schema = 6\n\n[sources.cat]\nrepo = \"{REPO}\"\n\n[install]\nharnesses = [\"gemini\"]\nmethod = \"symlink\"\n\n[agents.rev]\nsource = \"cat\"\n\n{}\n[agent-skills]\nrev = [\"recon\"]\n",
            declaration.replace("REV", &pinned)
        ),
    )
    .unwrap();
    sync_and_apply(&w);
    w
}

/// A pinned skill's dependencies install from the same pinned commit, so
/// one the source has since dropped is readable, planned and written.
/// Counted from the manifest's pins alone it is absent: the agent assigned
/// it renders without the row, and a fork of that agent is refused over a
/// skill sitting in the scope's own tree.
#[test]
#[allow(clippy::unwrap_used)]
fn a_pinned_skills_dependency_is_offered_at_the_pinned_revision() {
    let w = world();
    let recon = w.upstream.join("skills/recon/SKILL.md");
    fs::create_dir_all(recon.parent().unwrap()).unwrap();
    fs::write(
        &recon,
        "---\nname: recon\ndescription: about recon\ndependencies:\n  required: [helper]\n---\nRecon.\n",
    )
    .unwrap();
    write_skill(&w.upstream, "helper", "Helper.");
    write_agent(&w.upstream, "rev", "Upstream body.");
    commit(&w.upstream, "one");
    let pinned = head_commit(&w.upstream);
    // Upstream drops the dependency. Only the pin still carries it.
    fs::remove_dir_all(w.upstream.join("skills/helper")).unwrap();
    fs::write(
        &recon,
        "---\nname: recon\ndescription: about recon\n---\nRecon.\n",
    )
    .unwrap();
    commit(&w.upstream, "two");

    let path = manifest::manifest_path(&w.env, &w.scope);
    fs::create_dir_all(path.parent().unwrap()).unwrap();
    fs::write(
        &path,
        format!(
            "schema = 6\n\n[sources.cat]\nrepo = \"{REPO}\"\n\n[install]\nharnesses = [\"gemini\"]\nmethod = \"symlink\"\n\n[agents.rev]\nsource = \"cat\"\n\n[skills.recon]\nsource = \"cat\"\nrev = \"{pinned}\"\n\n[agent-skills]\nrev = [\"helper\"]\n"
        ),
    )
    .unwrap();
    sync_and_apply(&w);
    assert!(
        w.home.join("app/.agents/skills/helper/SKILL.md").is_file(),
        "the fixture proves nothing unless the pinned revision installed the dependency"
    );

    let file = rendered(&w, HarnessId::Gemini, "rev");
    let before = fs::read_to_string(&file).unwrap();
    assert_eq!(times(&before, "## Required Skills"), 1, "{before}");
    assert_eq!(before.matches("- helper: ").count(), 1, "{before}");
    edit_body(&file);

    let plan = fork::fork(&w.env, &w.scope, ItemKind::Agent, "rev", HarnessId::Gemini).unwrap();
    apply::execute(&w.env, &plan).unwrap();
    resettle(&w);

    let text = fs::read_to_string(&file).unwrap();
    assert_eq!(times(&text, "## Required Skills"), 1, "{text}");
    assert_eq!(text.matches("- helper: ").count(), 1, "{text}");
}

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

/// A declaration pins a revision; whether that revision carries what it
/// names is a separate question, and the plan asks it before installing
/// anything. Taken on the declaration's word, a skill the pinned commit
/// never held is offered to an agent's assignment, which satisfies the
/// refusal instead of raising it.
#[test]
#[allow(clippy::unwrap_used)]
fn a_pinned_skill_the_revision_does_not_carry_is_not_offered() {
    let w = world();
    write_agent(&w.upstream, "rev", "Upstream body.");
    commit(&w.upstream, "one");
    let pinned = head_commit(&w.upstream);

    let path = manifest::manifest_path(&w.env, &w.scope);
    fs::create_dir_all(path.parent().unwrap()).unwrap();
    fs::write(
        &path,
        format!(
            "schema = 6\n\n[sources.cat]\nrepo = \"{REPO}\"\n\n[install]\nharnesses = [\"gemini\"]\nmethod = \"symlink\"\n\n[agents.rev]\nsource = \"cat\"\n\n[skills.recon]\nsource = \"cat\"\nrev = \"{pinned}\"\n\n[agent-skills]\nrev = [\"recon\"]\n"
        ),
    )
    .unwrap();
    sync_and_apply(&w);

    let file = rendered(&w, HarnessId::Gemini, "rev");
    let before = fs::read_to_string(&file).unwrap();
    assert_eq!(times(&before, "## Required Skills"), 0, "{before}");
    edit_body(&file);

    match fork::fork(&w.env, &w.scope, ItemKind::Agent, "rev", HarnessId::Gemini) {
        Err(CoreError::AgentSkillUnavailable { name, skill }) => {
            assert_eq!((name.as_str(), skill.as_str()), ("rev", "recon"))
        }
        other => panic!("a pin naming a skill its revision lacks must not satisfy it: {other:?}"),
    }
}

/// Two pinned parents requiring one dependency at different commits: one
/// filesystem identity exists, so the plan writes nothing for it and says
/// so. Counted from the closure alone the name is still offered — the
/// closure is where the conflict is recorded, not where it is settled — and
/// the agent assigned it renders a row for instructions no plan wrote.
#[test]
#[allow(clippy::unwrap_used)]
fn a_dependency_two_pins_disagree_over_is_not_offered() {
    let w = world();
    for parent in ["gh", "top"] {
        let path = w.upstream.join("skills").join(parent).join("SKILL.md");
        fs::create_dir_all(path.parent().unwrap()).unwrap();
        fs::write(
            &path,
            format!(
                "---\nname: {parent}\ndescription: about {parent}\ndependencies:\n  required: [helper]\n---\nParent {parent}.\n"
            ),
        )
        .unwrap();
    }
    write_skill(&w.upstream, "helper", "Helper one.");
    write_agent(&w.upstream, "rev", "Upstream body.");
    commit(&w.upstream, "one");
    let first = head_commit(&w.upstream);
    write_skill(&w.upstream, "helper", "Helper two.");
    commit(&w.upstream, "two");
    let second = head_commit(&w.upstream);
    // Upstream drops it, so its own revision offers nothing here and the
    // two pins are the whole of what could.
    fs::remove_dir_all(w.upstream.join("skills/helper")).unwrap();
    commit(&w.upstream, "three");

    let path = manifest::manifest_path(&w.env, &w.scope);
    fs::create_dir_all(path.parent().unwrap()).unwrap();
    fs::write(
        &path,
        format!(
            "schema = 6\n\n[sources.cat]\nrepo = \"{REPO}\"\n\n[install]\nharnesses = [\"gemini\"]\nmethod = \"symlink\"\n\n[agents.rev]\nsource = \"cat\"\n\n[skills.gh]\nsource = \"cat\"\nrev = \"{first}\"\n\n[skills.top]\nsource = \"cat\"\nrev = \"{second}\"\n\n[agent-skills]\nrev = [\"helper\"]\n"
        ),
    )
    .unwrap();
    sync_and_apply(&w);
    assert!(
        !w.home.join("app/.agents/skills/helper/SKILL.md").exists(),
        "the fixture proves nothing unless the conflict left the dependency uninstalled"
    );

    let file = rendered(&w, HarnessId::Gemini, "rev");
    let before = fs::read_to_string(&file).unwrap();
    assert_eq!(times(&before, "## Required Skills"), 0, "{before}");
    edit_body(&file);

    match fork::fork(&w.env, &w.scope, ItemKind::Agent, "rev", HarnessId::Gemini) {
        Err(CoreError::AgentSkillUnavailable { name, skill }) => {
            assert_eq!((name.as_str(), skill.as_str()), ("rev", "helper"))
        }
        other => panic!("a dependency the plan refused must not satisfy it: {other:?}"),
    }
}
