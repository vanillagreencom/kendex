//! The authoring verbs end to end through the binary: create, register,
//! list — the non-interactive spellings of the Mine tab's flows.
#![cfg(unix)]

use std::path::Path;
use std::process::{Command, Output};

#[path = "../../test_util.rs"]
mod test_util;
use test_util::rooted;

#[allow(clippy::expect_used)]
fn kendex(home: &Path, args: &[&str]) -> Output {
    Command::new(env!("CARGO_BIN_EXE_kendex"))
        .args(args)
        .current_dir(home)
        .env_clear()
        .env("HOME", home)
        .env("KENDEX_REAL_HOME", "1")
        .env("PATH", std::env::var("PATH").unwrap_or_default())
        .output()
        .expect("kendex binary runs")
}

#[test]
#[allow(clippy::unwrap_used)]
fn new_scaffolds_and_mine_lists_the_row() {
    let tmp = tempfile::tempdir().unwrap();
    let home = tmp.path();
    let dir = home.join("team-skills");
    let output = kendex(
        home,
        &[
            "marketplace",
            "new",
            "team-skills",
            "--description",
            "Skills for the team",
            "--author",
            "Jane Doe",
            "--license",
            "mit",
            "--dir",
            dir.to_str().unwrap(),
        ],
    );
    let said = String::from_utf8_lossy(&output.stderr).into_owned();
    assert!(output.status.success(), "{said}");
    assert!(dir.join("kendex.toml").exists());
    assert!(dir.join("LICENSE").exists());
    assert!(dir.join(".github/workflows/kendex-check.yml").exists());
    assert!(said.contains("0 breakage"), "{said}");

    let mine = kendex(home, &["marketplace", "mine"]);
    assert!(mine.status.success());
    let listed = String::from_utf8_lossy(&mine.stdout).into_owned();
    assert!(listed.contains("team-skills"), "{listed}");
}

#[test]
#[allow(clippy::unwrap_used)]
fn use_registers_a_discovered_repo_without_writing_into_it() {
    let tmp = tempfile::tempdir().unwrap();
    let home = tmp.path();
    let repo = home.join("their-repo");
    let skill = repo.join(".claude/skills/review");
    std::fs::create_dir_all(&skill).unwrap();
    std::fs::write(
        skill.join("SKILL.md"),
        "---\nname: review\ndescription: reviews\n---\nBody.\n",
    )
    .unwrap();

    let output = kendex(home, &["marketplace", "use", repo.to_str().unwrap()]);
    let said = String::from_utf8_lossy(&output.stderr).into_owned();
    assert!(output.status.success(), "{said}");
    assert!(said.contains("nothing inside it was changed"), "{said}");
    assert!(
        !repo.join("kendex.toml").exists(),
        "use-existing must not write a control file"
    );

    let mine = kendex(home, &["marketplace", "mine", "--json"]);
    let json: serde_json::Value = serde_json::from_slice(&mine.stdout).unwrap();
    assert_eq!(json["schema"], 3);
    let rows = json["marketplaces"].as_array().unwrap();
    assert_eq!(rows.len(), 1);
    assert_eq!(rows[0]["counts"]["skill"], 1);
    assert_eq!(rows[0]["declared"], false);
}

#[test]
#[allow(clippy::unwrap_used)]
fn import_with_no_selections_lists_candidates_and_exits_clean() {
    let tmp = tempfile::tempdir().unwrap();
    let home = tmp.path();
    let target = home.join("mine");
    std::fs::create_dir_all(&target).unwrap();
    let output = kendex(
        home,
        &["marketplace", "import", target.to_str().unwrap(), "--json"],
    );
    let said = String::from_utf8_lossy(&output.stderr).into_owned();
    assert!(output.status.success(), "{said}");
    let json: serde_json::Value = serde_json::from_slice(&output.stdout).unwrap();
    assert_eq!(json["schema"], 2);
    assert!(json["candidates"].as_array().unwrap().is_empty());
}

/// A selection whose every origin is unusable is refused before the copy,
/// and the refusal says where the bytes were and why they cannot be taken.
///
/// The shipped path in: a machine holding a Codex agent, which is TOML and
/// which a catalog's `agents/<name>.md` slot cannot store. The message is
/// core's — one sentence for this condition wherever it is said — laid out
/// here one origin per line.
#[test]
#[allow(clippy::unwrap_used)]
fn import_of_an_agent_in_another_format_refuses_and_says_why() {
    let tmp = tempfile::tempdir().unwrap();
    let home = rooted(&tmp);
    let home = home.as_path();
    let target = home.join("mine");
    std::fs::create_dir_all(&target).unwrap();
    let agents = home.join(".codex/agents");
    std::fs::create_dir_all(&agents).unwrap();
    std::fs::write(
        agents.join("codexer.toml"),
        "name = \"codexer\"\ndescription = \"about codexer\"\n",
    )
    .unwrap();

    let output = kendex(
        home,
        &[
            "marketplace",
            "import",
            target.to_str().unwrap(),
            "--agent",
            "codexer",
        ],
    );
    let said = String::from_utf8_lossy(&output.stderr).into_owned();
    assert!(!output.status.success(), "{said}");
    assert!(said.contains("has no bytes kendex can import"), "{said}");
    assert!(said.contains("codexer.toml"), "{said}");
    assert!(said.contains("it has no frontmatter"), "{said}");
    assert!(
        said.contains("a catalog stores an agent as markdown"),
        "{said}"
    );
    assert!(
        !target.join("agents").exists(),
        "a refused import writes nothing"
    );
}

/// The listing says an unusable origin cannot be taken and why, without
/// calling it unreadable: a Codex agent reads fine and is merely a format
/// a catalog cannot store. Both spellings of the listing, since the
/// envelope is what a program reads.
#[test]
#[allow(clippy::unwrap_used)]
fn listing_marks_an_agent_in_another_format_unusable_and_says_why() {
    let tmp = tempfile::tempdir().unwrap();
    let home = rooted(&tmp);
    let home = home.as_path();
    let target = home.join("mine");
    std::fs::create_dir_all(&target).unwrap();
    let agents = home.join(".codex/agents");
    std::fs::create_dir_all(&agents).unwrap();
    std::fs::write(
        agents.join("codexer.toml"),
        "name = \"codexer\"\ndescription = \"about codexer\"\n",
    )
    .unwrap();

    let listed = kendex(home, &["marketplace", "import", target.to_str().unwrap()]);
    let rows = String::from_utf8_lossy(&listed.stdout).into_owned();
    assert!(listed.status.success(), "{rows}");
    let row = rows
        .lines()
        .find(|line| line.contains("codexer"))
        .unwrap_or_else(|| panic!("no codexer row: {rows}"));
    assert!(
        row.contains("unusable"),
        "where a hash would be, and not a word blaming the read: {row}"
    );
    assert!(!row.contains("unreadable"), "{row}");
    assert!(row.contains("codexer.toml"), "{row}");
    assert!(
        row.contains("it has no frontmatter")
            && row.contains("a catalog stores an agent as markdown"),
        "the reason follows the place: {row}"
    );

    let json = kendex(
        home,
        &["marketplace", "import", target.to_str().unwrap(), "--json"],
    );
    let payload: serde_json::Value = serde_json::from_slice(&json.stdout).unwrap();
    assert_eq!(payload["schema"], 2);
    let origin = payload["candidates"]
        .as_array()
        .unwrap()
        .iter()
        .find(|candidate| candidate["name"] == "codexer")
        .unwrap_or_else(|| panic!("no codexer candidate: {payload}"))["origins"][0]
        .clone();
    assert_eq!(origin["hash"], "");
    assert!(
        origin["problem"]
            .as_str()
            .unwrap()
            .contains("it has no frontmatter"),
        "{origin}"
    );
    assert!(
        origin["locations"][0]
            .as_str()
            .unwrap()
            .ends_with("codexer.toml"),
        "the place is a path and nothing else: {origin}"
    );
}

/// A place is an untrusted filename, and the refusal is a message that
/// owns its breaks — `ui/refusal.rs` splits on `\n` and escapes each piece
/// after — so a raw newline reaching it would open a line of its own in
/// the run's account of why it stopped. `import::no_importable_bytes`
/// spells every value through `names::shown` for exactly that, and this
/// pins the property rather than the wording: the fixture's name carries a
/// real newline and a right-to-left override, and neither reaches stderr.
#[test]
#[allow(clippy::unwrap_used)]
fn a_refusal_cannot_be_given_extra_lines_by_the_name_it_quotes() {
    let tmp = tempfile::tempdir().unwrap();
    let home = rooted(&tmp);
    let home = home.as_path();
    let target = home.join("mine");
    std::fs::create_dir_all(&target).unwrap();
    let agents = home.join(".codex/agents");
    std::fs::create_dir_all(&agents).unwrap();
    let hostile = "co\ndex\u{202e}er";
    std::fs::write(
        agents.join(format!("{hostile}.toml")),
        "name = \"hostile\"\ndescription = \"about it\"\n",
    )
    .unwrap();

    let output = kendex(
        home,
        &[
            "marketplace",
            "import",
            target.to_str().unwrap(),
            "--agent",
            hostile,
        ],
    );
    let said = String::from_utf8_lossy(&output.stderr).into_owned();
    assert!(!output.status.success(), "{said}");
    assert!(said.contains("has no bytes kendex can import"), "{said:?}");
    assert!(said.contains("it has no frontmatter"), "{said:?}");
    // The sentence and its one place. A raw newline in either the name or
    // the path would make a third.
    assert_eq!(said.trim_end().lines().count(), 2, "{said:?}");
    assert!(!said.contains("co\ndex"), "{said:?}");
    assert!(!said.contains('\u{202e}'), "{said:?}");
}
