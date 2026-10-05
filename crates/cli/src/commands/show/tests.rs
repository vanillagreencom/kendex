use super::{Coverage, Segment, detail, file_list, metadata, segments};
use crate::ui::testing::{plain, rich, tagged};
use crate::width::visible_width;
use kendex_core::model::HarnessId;
use kendex_core::package::support::{FallbackTool, RecordSupport, UnsupportedTool};

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

/// What the supported-tools line says for each shape of record: the
/// unsupported list's collapse, an unread record's cause, and the advisory
/// and fallback lists.
#[test]
fn the_supported_tools_line_follows_the_record() {
    use HarnessId::*;
    let gap = |tool, reason: Option<&str>| UnsupportedTool {
        tool,
        reason: reason.map(str::to_owned),
    };
    let every = |reason: Option<&str>| HarnessId::ALL.map(|tool| gap(tool, reason)).to_vec();
    let read = |unsupported| RecordSupport::Read {
        unsupported,
        advisory: vec![],
        fallback: vec![],
    };
    let partial = vec![gap(Pi, Some("a reason")), gap(Gemini, None)];
    // Two reasons, each given by tools that are not neighbours: an adjacent
    // dedup would keep every one of them.
    let alternating: Vec<UnsupportedTool> = HarnessId::ALL
        .into_iter()
        .enumerate()
        .map(|(at, tool)| gap(tool, Some(if at % 2 == 0 { "first" } else { "second" })))
        .collect();
    let advisory = vec![Pi];
    let fallback = vec![FallbackTool {
        tool: Codex,
        reason: "a fallback".into(),
    }];
    let rows: [(RecordSupport, Vec<Segment>); 7] = [
        (read(vec![]), vec![Segment::Coverage(Coverage::All)]),
        (
            read(partial.clone()),
            vec![Segment::Coverage(Coverage::Except(&partial))],
        ),
        (
            read(every(None)),
            vec![Segment::Coverage(Coverage::None(vec![]))],
        ),
        (
            read(every(Some("shared"))),
            vec![Segment::Coverage(Coverage::None(vec!["shared"]))],
        ),
        (
            read(alternating),
            vec![Segment::Coverage(Coverage::None(vec!["first", "second"]))],
        ),
        (
            RecordSupport::Unread {
                cause: "a cause".into(),
            },
            vec![Segment::Unknown("a cause")],
        ),
        (
            RecordSupport::Read {
                unsupported: vec![],
                advisory: advisory.clone(),
                fallback: fallback.clone(),
            },
            vec![
                Segment::Coverage(Coverage::All),
                Segment::Advisory(&advisory),
                Segment::Fallback(&fallback),
            ],
        ),
    ];
    for (support, expected) in rows {
        assert_eq!(segments(&support), expected, "{support:?}");
    }
}
