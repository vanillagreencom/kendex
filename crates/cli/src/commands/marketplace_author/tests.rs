use std::collections::BTreeMap;
use std::path::Path;

use kendex_core::author::import::{CandidateGroup, CandidateOrigin};
use kendex_core::author::status::GitReadiness;
use kendex_core::registry::submit::SubmissionRow;

use super::*;
use crate::ui::testing::{plain, rich, tagged};

fn mine_row(breakage: u32, candidate: Option<&str>) -> author::MineRow {
    author::MineRow {
        path: "/dev/team-skills".to_owned(),
        name: "team-skills".to_owned(),
        description: None,
        license: None,
        counts: BTreeMap::from([("skill".to_owned(), 2), ("agent".to_owned(), 1)]),
        bundles: 1,
        declared: true,
        breakage,
        advisory: 0,
        safety_findings: 0,
        findings: Vec::new(),
        git: GitReadiness {
            repository: true,
            clean: Some(true),
            remote: None,
            candidate: candidate.map(str::to_owned),
            ahead: None,
        },
    }
}

/// What a created or registered marketplace holds, clean and broken: a
/// broken one is drawn as a failure, since it will not install.
#[test]
fn authored_marketplace_snapshots() {
    let mut lines = folder_line(
        &plain(),
        "created ",
        Path::new("/dev/team-skills"),
        " — a git repository with kendex.toml, README.md and the check workflow",
    );
    lines.extend(summarized(&plain(), &mine_row(0, Some("acme/team-skills"))));
    assert_eq!(
        lines,
        [
            "created /dev/team-skills — a git repository with kendex.toml, README.md and the check workflow",
            "team-skills: 3 package(s), 1 bundle(s); check: 0 breakage, 0 safety finding(s)",
            "git: remote candidate acme/team-skills",
        ]
    );
    assert_eq!(
        tagged(&summarized(&rich(100), &mine_row(2, None))),
        [
            "  <31>✗</> team-skills: 3 package(s), 1 bundle(s); check: 2 breakage, 0 safety finding(s)",
            "  <36>•</> git: no GitHub remote yet",
        ]
    );
}

#[test]
fn mine_snapshots() {
    let rows = [mine_row(1, None)];
    assert_eq!(
        mine_lines(&plain(), &rows),
        ["team-skills  3 package(s), 1 bundle(s), 1 problem(s)  /dev/team-skills"]
    );
    // A folder longer than its column could be at 80 cells: the folder
    // keeps its line, and what the marketplace holds wraps beside it.
    let far = author::MineRow {
        path: "/home/dev/My Projects/marketplaces/acme/skills-1".to_owned(),
        ..mine_row(1, None)
    };
    assert_eq!(
        tagged(&mine_lines(&rich(80), &[far])),
        [
            "",
            "<1;36>marketplaces</>  <90>1</>",
            "  <1;90>name</>         <1;90>holds</>            <1;90>folder</>",
            "  <90>──────────────────────────────────────────────────────────────────────────────</>",
            "  team-skills  3 package(s), 1  /home/dev/My Projects/marketplaces/acme/skills-1",
            "               bundle(s), 1",
            "               problem(s)",
        ]
    );
    assert_eq!(
        tagged(&mine_lines(&rich(100), &rows)),
        [
            "",
            "<1;36>marketplaces</>  <90>1</>",
            "  <1;90>name</>         <1;90>holds</>                                    <1;90>folder</>",
            "  <90>──────────────────────────────────────────────────────────────────────</>",
            "  team-skills  3 package(s), 1 bundle(s), 1 problem(s)  /dev/team-skills",
        ]
    );
    assert_eq!(
        tagged(&unread(&rich(80), Path::new("/dev/gone"), "no such folder")),
        ["  <31>✗</> /dev/gone: no such folder"]
    );
}

/// Each origin of a candidate is its own row, a usable one with its hash
/// and one nothing can take with the word that says so.
#[test]
fn import_candidate_snapshots() {
    let candidates = [author::ImportCandidate {
        kind: kendex_core::model::ItemKind::Skill,
        name: "review".to_owned(),
        name_problem: None,
        origins: vec![
            CandidateOrigin {
                group: CandidateGroup::Marketplace {
                    source: "cat".to_owned(),
                    repo: "acme/cat".to_owned(),
                    license: Some("MIT".to_owned()),
                    license_recognized: true,
                },
                locations: vec!["/a/review".to_owned(), "/b/review".to_owned()],
                hash: "0123456789abcdef".to_owned(),
                problem: None,
            },
            CandidateOrigin {
                group: CandidateGroup::Unmanaged,
                locations: vec!["/c/review".to_owned()],
                hash: String::new(),
                problem: Some("it has no frontmatter".to_owned()),
            },
        ],
    }];
    assert_eq!(
        candidate_lines(&plain(), &candidates),
        [
            "skill  review  [from marketplace 'cat' (MIT)]  0123456789ab  /a/review = /b/review",
            "skill  review  [found on disk]  unusable  /c/review — it has no frontmatter",
        ]
    );
    let drawn = candidate_lines(&rich(100), &candidates).join("\n");
    for cell in ["0123456789ab", "unusable", "it has no frontmatter"] {
        assert!(drawn.contains(cell), "{cell}: {drawn}");
    }
    // A place that leaves the other columns less room than their words
    // need: every word, the name and the place stay whole, and the row runs
    // past the width.
    let place = format!(
        "/home/dev/My Marketplaces/{}review",
        "marketplaces/".repeat(3)
    );
    let mut far = candidates[0].clone();
    far.origins[0].locations = vec![place];
    assert_eq!(
        tagged(&candidate_lines(&rich(80), &[far])),
        [
            "",
            "<1;36>candidates</>  <90>2</>",
            "  <1;90>kind</>   <1;90>name</>    <1;90>origin</>       <1;90>hash</>          <1;90>places</>",
            "  <90>─────────────────────────────────────────────────────────────────────────────────────────────────────────────────</>",
            "  skill  review  [from        0123456789ab  /home/dev/My Marketplaces/marketplaces/marketplaces/marketplaces/review",
            "                 marketplace",
            "                 'cat'",
            "                 (MIT)]",
            "  skill  review  [found on    unusable      /c/review — it has no frontmatter",
            "                 disk]",
        ]
    );
}

#[test]
fn import_outcome_snapshots() {
    let outcome = author::ImportOutcome {
        written: vec!["skills/review".to_owned()],
        already_present: vec!["agents/helper".to_owned()],
    };
    assert_eq!(
        imported(&plain(), &outcome),
        ["imported skills/review", "already present: agents/helper"]
    );
    assert_eq!(
        tagged(&imported(&rich(80), &outcome)),
        [
            "  <32>✓</> imported skills/review",
            "  <36>•</> already present: agents/helper",
        ]
    );
}

/// The submission checks: a passing row, a failing one that blocks the
/// submission with its fix under it, and one that could not be read.
#[test]
fn submit_preflight_snapshots() {
    let checks = [
        author::PreflightCheck {
            ok: Some(true),
            label: "kendex.toml declares the marketplace".to_owned(),
            fix: None,
        },
        author::PreflightCheck {
            ok: Some(false),
            label: "a license is chosen".to_owned(),
            fix: Some("add a LICENSE file".to_owned()),
        },
        author::PreflightCheck {
            ok: None,
            label: "everything is pushed".to_owned(),
            fix: None,
        },
    ];
    assert_eq!(
        preflight_lines(&plain(), &checks),
        [
            "ok  kendex.toml declares the marketplace",
            " ✗  a license is chosen",
            "      add a LICENSE file",
            " ?  everything is pushed",
        ]
    );
    assert_eq!(
        tagged(&preflight_lines(&rich(80), &checks)),
        [
            "  <32>✓</> kendex.toml declares the marketplace",
            "  <31>✗</> a license is chosen",
            "    <90>add a LICENSE file</>",
            "  <31>✗</> everything is pushed",
        ]
    );
}

#[test]
fn submission_status_snapshots() {
    let rows = [
        SubmissionRow {
            repo: "acme/team-skills".to_owned(),
            status: "rejected".to_owned(),
            status_reason: Some("no license".to_owned()),
            head_commit: None,
            indexed_at: None,
        },
        SubmissionRow {
            repo: "acme/tools".to_owned(),
            status: "listed".to_owned(),
            status_reason: None,
            head_commit: None,
            indexed_at: None,
        },
    ];
    assert_eq!(
        submissions(&plain(), &rows),
        [
            "acme/team-skills  rejected — no license",
            "acme/tools  listed",
        ]
    );
}
