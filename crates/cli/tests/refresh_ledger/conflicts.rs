//! What one conflict says: the position it sits at, how the files in
//! the way compare with the catalog, and the notes that name what to do
//! about a declaration no tool can hold.

use std::fs;

use super::*;

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

/// How the files in the way compare with the catalog, one row per
/// shape, pinned as the one comparison line the conflict prints. Files
/// byte-for-byte the catalog's cost the reader nothing to keep, and say
/// so beside the adopt offer rather than reading as differing; a one-file
/// item is compared like any other, the plan holding its bytes at the
/// moment it refuses; and beyond the first three, differing files are
/// counted rather than listed, the count taken from the total rather
/// than from the names that survived the bound. Each row: the method,
/// the declaration, what is planted in the catalog and in the way, and
/// the line.
#[test]
#[allow(clippy::unwrap_used)]
fn a_conflict_says_how_the_files_in_the_way_compare_with_the_catalog() {
    type Plant = fn(&Path, &Path);
    type Row = (
        &'static str,
        &'static str,
        &'static str,
        Plant,
        &'static str,
    );
    let rows: [Row; 3] = [
        (
            "identical files",
            "symlink",
            "[skills.gamma]\nsource = \"cat\"\n",
            |catalog, project| {
                skill(catalog, "gamma", "Body.\n");
                let body = fs::read_to_string(catalog.join("skills/gamma/SKILL.md")).unwrap();
                fs::create_dir_all(project.join(".claude/skills/gamma")).unwrap();
                fs::write(project.join(".claude/skills/gamma/SKILL.md"), body).unwrap();
            },
            "identical to the catalog — adopt is safe",
        ),
        (
            "a one-file item",
            "copy",
            "[agents.rust]\nsource = \"cat\"\n",
            |catalog, project| {
                fs::create_dir_all(catalog.join("agents")).unwrap();
                fs::write(
                    catalog.join("agents/rust.md"),
                    "---\nname: rust\ndescription: writes rust\n---\nUpstream.\n",
                )
                .unwrap();
                let at = project.join(".claude/agents");
                fs::create_dir_all(&at).unwrap();
                fs::write(at.join("rust.md"), "By hand.\n").unwrap();
            },
            "differs from the catalog in 1 file: rust.md",
        ),
        (
            "more differing files than are named",
            "copy",
            "[skills.wide]\nsource = \"cat\"\n",
            |catalog, project| {
                skill(catalog, "wide", "Body.\n");
                let at = project.join(".claude/skills/wide");
                fs::create_dir_all(&at).unwrap();
                fs::write(at.join("SKILL.md"), "By hand.\n").unwrap();
                // Past the bound the row itself carries.
                for n in 0..40 {
                    fs::write(
                        catalog.join(format!("skills/wide/ref{n:02}.md")),
                        format!("catalog {n}\n"),
                    )
                    .unwrap();
                    fs::write(at.join(format!("ref{n:02}.md")), format!("mine {n}\n")).unwrap();
                }
            },
            "differs from the catalog in 41 files: SKILL.md, ref00.md, ref01.md, and 38 more",
        ),
    ];
    for (shape, method, declaration, plant, line) in rows {
        let tmp = tempfile::tempdir().unwrap();
        let home = rooted(&tmp);
        let home = home.as_path();
        let project = home.join("dev/app");
        let catalog = home.join("catalog");
        manifest(&project, &catalog, "[\"claude\"]", method, declaration);
        plant(&catalog, &project);

        let printed = said(&kendex(
            home,
            &project,
            &["apply", "--plan", "--scope", "project"],
        ));
        let compared: Vec<&str> = printed
            .lines()
            .map(str::trim)
            .filter(|l| l.contains("the catalog"))
            .collect();
        assert_eq!(compared, [line], "{shape}: {printed}");
    }
}

/// The place a conflict names comes off a path a person chose, and reaches
/// the terminal as its own characters rather than as an escape it would
/// act on. Core carries the path; this line is where it is escaped.
#[test]
#[allow(clippy::unwrap_used)]
fn a_position_reaches_the_terminal_escaped() {
    let tmp = tempfile::tempdir().unwrap();
    let home = tmp.path();
    let catalog = home.join("catalog");
    skill(&catalog, "deploy", "Upstream.\n");
    // The item name cannot carry a control character — names refuse them —
    // so the directory the project sits in is where one reaches a row.
    let project = home.join("we\u{1b}[31mird");
    manifest(
        &project,
        &catalog,
        "[\"claude\"]",
        "copy",
        "[skills.deploy]\nsource = \"cat\"\n",
    );
    let at = project.join(".claude/skills/deploy");
    fs::create_dir_all(&at).unwrap();
    fs::write(at.join("SKILL.md"), "By hand.\n").unwrap();

    let printed = said(&kendex(
        home,
        &project,
        &["refresh", "-y", "--scope", "project"],
    ));
    let conflict = printed
        .lines()
        .find(|line| line.starts_with("conflict: skill deploy"))
        .unwrap_or_else(|| panic!("the fixture needs a blocked install: {printed}"));
    assert!(
        !conflict.contains('\u{1b}'),
        "a control character reached the terminal: {conflict:?}"
    );
    assert!(
        conflict.contains("we\\u{1b}[31mird/.claude/skills/deploy"),
        "the place was not printed as what it is: {conflict}"
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
