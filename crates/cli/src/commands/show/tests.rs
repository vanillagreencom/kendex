use super::{Coverage, coverage, detail, file_list, metadata};
use crate::ui::testing::{plain, rich, tagged};
use crate::width::visible_width;
use kendex_core::model::HarnessId;
use kendex_core::package::support::{RecordSupport, UnsupportedTool};

#[test]
fn inspection_show_snapshots() {
    let meta = detail::PackageMeta {
        source: "cat".into(),
        repo: Some("owner/catalog".into()),
        repo_url: Some("https://github.com/owner/catalog".into()),
        rev: Some("1234567890".into()),
        current: None,
        installed_at: None,
        harnesses: vec![],
        enabled: true,
        fork: None,
        catalog: None,
        support: RecordSupport::Read {
            unsupported: vec![],
            advisory: vec![],
            fallback: vec![],
        },
    };
    assert_eq!(
        metadata(&plain(), &meta),
        [
            "marketplace: cat",
            "repository: owner/catalog",
            "held at: 1234567",
            "supported tools: all"
        ]
    );
    assert_eq!(
        tagged(&metadata(&rich(80), &meta)),
        [
            "  <36>•</> marketplace: cat",
            "  <link https://github.com/owner/catalog><36>repository: owner/catalog</></link>",
            "  <33>!</> held at: 1234567",
            "  <36>•</> supported tools: all",
        ]
    );
    let files = [
        detail::PackageFile {
            path: "SKILL.md".into(),
            size: 42,
            is_readme: false,
        },
        detail::PackageFile {
            path: "references/rules.md".into(),
            size: 7,
            is_readme: false,
        },
    ];
    // Plain keeps each file's line as written, unpadded.
    assert_eq!(
        file_list(&plain(), &files),
        ["SKILL.md  42 bytes", "references/rules.md  7 bytes"]
    );
    assert_eq!(
        tagged(&file_list(&rich(80), &files)),
        [
            "",
            "<1;36>files</>  <90>2</>",
            "  <1;90>path</>                 <1;90>size</>",
            "  <90>─────────────────────────────</>",
            "  SKILL.md             42 bytes",
            "  references/rules.md  7 bytes"
        ]
    );
    let local = detail::PackageMeta {
        source: "local".into(),
        repo: None,
        repo_url: None,
        rev: None,
        ..meta
    };
    assert_eq!(
        metadata(&plain(), &local),
        [
            "marketplace: none — your own package",
            "supported tools: all"
        ]
    );
    assert_eq!(
        tagged(&metadata(&rich(80), &local)),
        [
            "  <36>•</> marketplace: none — your own package",
            "  <36>•</> supported tools: all"
        ]
    );
}

#[test]
fn inspection_show_wraps_links_and_file_paths() {
    let long = "path-part-".repeat(15);
    let meta = detail::PackageMeta {
        source: long.clone(),
        repo: Some(long.clone()),
        repo_url: Some(format!("https://example.com/{long}")),
        rev: None,
        current: None,
        installed_at: None,
        harnesses: vec![],
        enabled: true,
        fork: None,
        catalog: None,
        support: RecordSupport::Read {
            unsupported: vec![],
            advisory: vec![],
            fallback: vec![],
        },
    };
    let files = [detail::PackageFile {
        path: long,
        size: 42,
        is_readme: false,
    }];
    let drawn = metadata(&rich(80), &meta)
        .into_iter()
        .chain(file_list(&rich(80), &files))
        .collect::<Vec<_>>();
    assert!(
        drawn.iter().all(|line| visible_width(line) <= 80),
        "{drawn:?}"
    );
    assert!(
        metadata(&plain(), &meta)
            .iter()
            .any(|line| visible_width(line) > 80)
    );
}

/// How the supported-tools line collapses core's unsupported list: each row
/// is one shape that list takes and the branch it lands in.
#[test]
fn the_unsupported_list_collapses_to_all_except_or_none() {
    use HarnessId::*;
    let gap = |tool, reason: Option<&str>| UnsupportedTool {
        tool,
        reason: reason.map(str::to_owned),
    };
    let every = |reason: Option<&str>| HarnessId::ALL.map(|tool| gap(tool, reason)).to_vec();
    let partial = vec![gap(Pi, Some("a reason")), gap(Gemini, None)];
    // Two reasons, each given by tools that are not neighbours: an adjacent
    // dedup would keep every one of them.
    let alternating: Vec<UnsupportedTool> = HarnessId::ALL
        .into_iter()
        .enumerate()
        .map(|(at, tool)| gap(tool, Some(if at % 2 == 0 { "first" } else { "second" })))
        .collect();
    let rows: [(Vec<UnsupportedTool>, Coverage); 5] = [
        (vec![], Coverage::All),
        (partial.clone(), Coverage::Except(&partial)),
        (every(None), Coverage::None(vec![])),
        (every(Some("shared")), Coverage::None(vec!["shared"])),
        (alternating, Coverage::None(vec!["first", "second"])),
    ];
    for (unsupported, expected) in rows {
        assert_eq!(coverage(&unsupported), expected, "{unsupported:?}");
    }
}
