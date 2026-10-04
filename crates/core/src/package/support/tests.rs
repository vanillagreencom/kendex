use super::{FallbackTool, ToolSupport, UnsupportedTool, tool_support};
use crate::model::{HarnessId, ItemKind};

fn hook(lines: &str) -> String {
    format!("#!/usr/bin/env bash\n# ---\n# name: guard\n{lines}# ---\nexit 0\n")
}

fn support(
    unsupported: Vec<UnsupportedTool>,
    advisory: Vec<HarnessId>,
    fallback: Vec<FallbackTool>,
) -> ToolSupport {
    ToolSupport {
        unsupported,
        advisory,
        fallback,
    }
}

fn gap(tool: HarnessId, reason: Option<&str>) -> UnsupportedTool {
    UnsupportedTool {
        tool,
        reason: reason.map(str::to_owned),
    }
}

/// Each row is one way a hook declares which tools do not run it as
/// written; the expected lists are written out, never derived from core.
#[test]
fn each_hook_declaration_answers_its_own_tools() {
    use HarnessId::*;
    let named = hook(
        "# event: PreToolUse\n# harnesses: [claude, codex, opencode, antigravity]\n# description: Guard. Not run on pi: its payload is unmeasured. Not run on copilot: it names no agent.\n",
    );
    let unnamed = hook("# event: PreToolUse\n# description: Guard.\n");
    let unfired = hook(
        "# event: StopFailure\n# description: Rows. Not run on gemini: it has no StopFailure event.\n",
    );
    let fallback = hook(
        "# event: SessionEnd\n# harnesses: [claude, codex, pi]\n# description: Rows. On codex: a watcher reads its pane instead. Not run on claude: never read. On gemini: never read.\n",
    );
    let broken = "#!/usr/bin/env bash\nexit 0\n";
    let rows: [(&str, ItemKind, Option<&str>, ToolSupport); 5] = [
        (
            "an On sentence on a listed tool is its fallback, and neither form crosses the list",
            ItemKind::Hook,
            Some(&fallback),
            support(vec![
                    gap(Opencode, None),
                    gap(Cursor, None),
                    gap(Gemini, None),
                    gap(Copilot, None),
                    gap(Antigravity, None),
                ], vec![], vec![FallbackTool {
                    tool: Codex,
                    reason: "a watcher reads its pane instead".to_owned(),
                }]),
        ),
        (
            "a harnesses line: a stated reason, an unstated one, advisory where it is named",
            ItemKind::Hook,
            Some(&named),
            support(vec![
                    gap(Cursor, None),
                    gap(Pi, Some("its payload is unmeasured")),
                    gap(Gemini, None),
                    gap(Copilot, Some("it names no agent")),
                ], vec![Opencode], vec![]),
        ),
        (
            "no harnesses line: Antigravity is reached only by name",
            ItemKind::Hook,
            Some(&unnamed),
            support(vec![gap(
                    Antigravity,
                    Some(&crate::hook::by_name_only(Antigravity)),
                )], vec![Opencode, Cursor], vec![]),
        ),
        (
            "an event a tool never fires: the stated reason, else core's sentence",
            ItemKind::Hook,
            Some(&unfired),
            support(vec![
                    gap(Codex, Some("Codex never fires StopFailure")),
                    gap(Gemini, Some("it has no StopFailure event")),
                    gap(Copilot, Some("GitHub Copilot never fires StopFailure")),
                    gap(Antigravity, Some("Antigravity never fires StopFailure")),
                ], vec![Opencode, Cursor], vec![]),
        ),
        (
            "a header that does not read runs nowhere",
            ItemKind::Hook,
            Some(broken),
            support(HarnessId::ALL
                    .into_iter()
                    .map(|tool| {
                        gap(
                            tool,
                            Some("its header does not read: hook script has no `# ---` frontmatter block"),
                        )
                    })
                    .collect(), vec![], vec![]),
        ),
    ];
    for (case, kind, header, expected) in rows {
        assert_eq!(tool_support(kind, header), expected, "{case}");
    }
}

/// A hook script nobody could read is no hook any tool runs.
#[test]
fn an_unread_hook_script_runs_nowhere() {
    let support = tool_support(ItemKind::Hook, None);
    assert_eq!(
        support.unsupported,
        HarnessId::ALL
            .into_iter()
            .map(|tool| gap(tool, Some("its script could not be read")))
            .collect::<Vec<_>>()
    );
    assert!(support.advisory.is_empty());
}

/// A kind's gaps come from the capability table alone, with no reason;
/// each row's expected list is written out, never derived from the table.
#[test]
fn a_kind_level_gap_needs_no_declaration() {
    use HarnessId::*;
    let rows: [(&str, ItemKind, ToolSupport); 3] = [
        (
            "a kind-level gap needs no declaration",
            ItemKind::McpServer,
            support(vec![gap(Pi, None)], vec![], vec![]),
        ),
        (
            "a kind every tool takes",
            ItemKind::Skill,
            ToolSupport::default(),
        ),
        (
            "a kind only two tools take",
            ItemKind::OutputStyle,
            support(
                vec![
                    gap(Codex, None),
                    gap(Opencode, None),
                    gap(Cursor, None),
                    gap(Gemini, None),
                    gap(Copilot, None),
                    gap(Antigravity, None),
                ],
                vec![],
                vec![],
            ),
        ),
    ];
    for (case, kind, expected) in rows {
        assert_eq!(tool_support(kind, None), expected, "{case}");
    }
}
