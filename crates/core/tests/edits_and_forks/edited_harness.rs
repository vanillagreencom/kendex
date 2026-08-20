//! Which rendering an edit lives in: a fork captures one tool's bytes, so
//! the update row has to name the tool whose copy was changed.

use std::fs;

use super::*;

#[test]
#[allow(clippy::unwrap_used)]
fn an_edited_agent_names_the_rendering_that_was_edited() {
    let w = world();
    let dir = w.upstream.join("agents");
    fs::create_dir_all(&dir).unwrap();
    fs::write(
        dir.join("rev.md"),
        "---\nname: rev\ndescription: agent rev\n---\nAgent body.\n",
    )
    .unwrap();
    commit(&w.upstream, "one");
    fs::create_dir_all(w.home.join("app/.opencode")).unwrap();
    let path = manifest::manifest_path(&w.env, &w.scope);
    fs::create_dir_all(path.parent().unwrap()).unwrap();
    fs::write(
        &path,
        format!(
            "schema = 5\n\n[sources.cat]\nrepo = \"{REPO}\"\n\n[install]\nharnesses = [\"claude\", \"opencode\"]\nmethod = \"symlink\"\n\n[agents.rev]\nsource = \"cat\"\n"
        ),
    )
    .unwrap();
    sync_and_apply(&w);
    let claude = w.home.join("app/.claude/agents/rev.md");
    let opencode = w.home.join("app/.opencode/agents/rev.md");
    assert!(claude.is_file() && opencode.is_file());

    fs::write(&opencode, "my opencode edit").unwrap();
    let report = kendex_core::package::updates::updates(&w.env, &w.scope).unwrap();
    let row = report
        .rows
        .iter()
        .find(|row| row.kind == ItemKind::Agent && row.name == "rev")
        .unwrap();
    assert!(row.blocked_by_local_edit);
    assert_eq!(
        row.edited_harnesses,
        vec![HarnessId::Opencode],
        "the fork must capture the rendering that was edited, not the first one"
    );
}
