use super::*;

fn rewrite(body: &str, harness: HarnessId) -> String {
    rewrite_prose(body, harness).0
}

#[test]
fn manifest_names_keep_their_claude_and_opencode_spelling() {
    assert_eq!(claude_tool_name("web_search"), "WebSearch");
    assert_eq!(claude_tool_name("mcp__gh"), "mcp__gh");
    assert_eq!(opencode_permission("apply-patch").as_deref(), Some("edit"));
    assert_eq!(opencode_permission("mcp__gh").as_deref(), Some("mcp__gh"));
    assert_eq!(opencode_permission("  "), None);
}

#[test]
fn a_tool_reference_speaks_each_harness_vocabulary() {
    let body = "Use the Read tool first, then the Bash tool.\n";
    assert_eq!(
        rewrite(body, HarnessId::Opencode),
        "Use the read tool first, then the bash tool.\n"
    );
    assert_eq!(
        rewrite(body, HarnessId::Pi),
        "Use the read tool first, then the bash tool.\n"
    );
    assert_eq!(
        rewrite(body, HarnessId::Cursor),
        "Use the read tool first, then the bash tool.\n"
    );
    // Codex names actions, so the whole `use the X tool` goes — and only
    // that shape, because the phrase reads as a verb and nothing else.
    assert_eq!(
        rewrite(body, HarnessId::Codex),
        "Open the file first, then the Bash tool.\n"
    );
    // Bodies are authored in Claude's words already.
    assert_eq!(rewrite(body, HarnessId::Claude), body);
    assert!(rewrite_prose(body, HarnessId::Claude).1.is_empty());
}

#[test]
fn a_codex_rewrite_keeps_the_capital_the_verb_had() {
    assert_eq!(
        rewrite("Use the Read tool to inspect it.\n", HarnessId::Codex),
        "Open the file to inspect it.\n"
    );
    assert_eq!(
        rewrite("Please use the Read tool first.\n", HarnessId::Codex),
        "Please open the file first.\n"
    );
}

/// A Codex phrase is a verb, so it can only replace a whole `use the X
/// tool`. Dropped anywhere else it produces sentences no reader can parse —
/// "Open the file is the only way in" — or collapses two different tools
/// into one phrase, so the reference stays in Claude's words instead.
#[test]
fn codex_leaves_every_other_shape_in_claude_s_words() {
    for body in [
        "The Read tool is the only way in.\n",
        "Do not reach for the Write tool here.\n",
        "The Edit tool, the Write tool and the Bash tool are denied.\n",
    ] {
        assert_eq!(rewrite(body, HarnessId::Codex), body, "{body}");
    }
    let (_, warnings) = rewrite_prose("The Read tool is the only way in.\n", HarnessId::Codex);
    assert_eq!(warnings.len(), 1);
    assert!(warnings[0].message.contains("Read"), "{:?}", warnings[0]);
}

/// An inline literal is a sample to copy. Codex's phrase would swallow the
/// backticks along with the name and the byte-faithful promise with them.
#[test]
fn a_quoted_name_keeps_every_byte_on_codex() {
    let body = "Use `Read` tool sparingly.\n";
    assert_eq!(rewrite(body, HarnessId::Codex), body);
    assert_eq!(
        rewrite("The `Write` tool overwrites.\n", HarnessId::Codex),
        "The `Write` tool overwrites.\n"
    );
    assert_eq!(
        rewrite("The `Write` tool overwrites.\n", HarnessId::Opencode),
        "The `write` tool overwrites.\n"
    );
}

#[test]
fn one_warning_names_every_tool_reworded_for_the_harness() {
    let body = "the Read tool, the Read tool again, the Grep tool\n";
    let (_, warnings) = rewrite_prose(body, HarnessId::Opencode);
    assert_eq!(warnings.len(), 1);
    assert_eq!(
        warnings[0].message,
        "tool references reworded for OpenCode: Read, Grep"
    );
    assert_eq!(warnings[0].remediation, None);
}

#[test]
fn unknown_and_mcp_references_pass_through_with_one_warning_each() {
    let body =
        "Call the mcp__github__search tool, the SendMessage tool, the mcp__github__search tool.\n";
    let (text, warnings) = rewrite_prose(body, HarnessId::Opencode);
    assert_eq!(text, body);
    assert_eq!(warnings.len(), 2);
    assert_eq!(
        warnings[0].message,
        "`mcp__github__search` is not an OpenCode tool name — the reference passes through as written"
    );
    assert!(warnings[1].message.starts_with("`SendMessage`"));

    // Codex leaves every reference as written, so naming them one by one
    // would drown the body — they arrive as one line.
    let (text, warnings) = rewrite_prose(body, HarnessId::Codex);
    assert_eq!(text, body);
    assert_eq!(warnings.len(), 1);
    assert!(warnings[0].message.contains("mcp__github__search"));
    assert!(warnings[0].message.contains("SendMessage"));
}

#[test]
fn a_tool_codex_has_no_word_for_is_reported_not_guessed_at() {
    let body = "Track it with the TodoWrite tool.\n";
    let (text, warnings) = rewrite_prose(body, HarnessId::Codex);
    assert_eq!(text, body);
    assert!(warnings[0].message.contains("TodoWrite"));
    // OpenCode has no word for it either, and says so rather than inventing one.
    let (text, warnings) = rewrite_prose(body, HarnessId::Opencode);
    assert_eq!(text, body);
    assert!(warnings[0].message.contains("`TodoWrite`"));
}

/// Four spaces at the top level, with no list marker to hang off, open an
/// indented code block and the backticks are its first line of text. So
/// the fence closes nothing and the line below it is prose — the other
/// reading of the indent `an_indented_fence` pins below, one rule seen
/// from two columns.
#[test]
fn a_top_level_indented_fence_opens_nothing() {
    assert_eq!(
        rewrite("    ```\nuse the Read tool\n", HarnessId::Opencode),
        "    ```\nuse the read tool\n"
    );
}

/// One row per markdown shape the rewrite must read as not prose: the
/// body comes back byte for byte on every harness that has words of its
/// own, and nothing warns. Fenced code, tilde fences, a fence nested in a
/// fence, inline code, a link's text and target, and a skill path keep
/// every byte. An unclosed fence protects the rest of the body. A fenced
/// block nested in a list item is indented four spaces — the shape most
/// real skills use — and reading that as prose rewrites a sample the
/// agent was told to copy verbatim. A run of backticks may close on a
/// later line, and a reader asked one line at a time sees the opener meet
/// nothing and calls the line prose; a span clipped at a line's start
/// opens on content, not on a backtick, so a containment test that wants
/// the name strictly inside the span lets through the one that begins the
/// line; a line the span crosses whole carries no delimiter of its own and
/// is covered end to end. Markdown reads nothing inside a raw HTML block:
/// a fence there is three literal backticks, and prose tight under a
/// wrapper keeps Claude's words with no warning naming it — the whole of
/// what the Changed entry promises, which a fixture carrying a fence or a
/// backtick cannot pin, since narrowing the HTML arm to blocks that hold
/// code marks would leave those green. Four spaces open a code block with
/// no fence to mark it. And prose about tools is never a reference.
#[test]
fn a_sample_or_prose_about_tools_keeps_every_byte_on_every_harness() {
    let rows: [&str; 18] = [
        concat!(
            "```\nuse the Read tool\n```\n",
            "~~~md\nuse the Read tool\n~~~\n",
            "````\n```\nuse the Read tool\n```\n````\n",
            "Run `use the Read tool` verbatim.\n",
            "See [the Read tool](https://example.com/the-Read-tool).\n",
            "- dev: .agents/skills/dev/SKILL.md — read it with the Read tool\n",
        ),
        "```\nuse the Read tool\nstill fenced: the Bash tool\n",
        "1. Run this:\n\n    ```sh\n    use the Bash tool\n    ```\n\nDone.\n",
        "Paste `use the Read tool\n--dry-run` into the prompt.\n",
        "Paste `run\nRead tool now` here.\n",
        "Paste `x\nRead tool` now\n",
        "Paste `one\nuse the Read tool\ntwo` here.\n",
        "<details>\n<summary>x</summary>\n```sh\nuse the Read tool\n```\n</details>\n",
        "<!--\n```\nuse the Read tool\n```\n-->\n",
        "<div>\nRun `use the Read tool` verbatim.\n</div>\n",
        "<div>\nUse the Read tool here.\n</div>\n",
        "<details>\nUse the Read tool here.\n</details>\n",
        "<br>\nUse the Read tool here.\n",
        "Then run:\n\n    use the Read tool --dry-run\n",
        "Pick the right tool for the job.\n",
        "Prefer the dedicated tools over shell commands.\n",
        "The toolkit is yours.\n",
        "the Read toolbox\n",
    ];
    for body in rows {
        for harness in [HarnessId::Codex, HarnessId::Opencode, HarnessId::Cursor] {
            let (text, warnings) = rewrite_prose(body, harness);
            assert_eq!(text, body, "{harness:?} rewrote {body:?}");
            assert!(
                warnings.is_empty(),
                "{harness:?} warned about {body:?}: {warnings:?}"
            );
        }
    }
}

/// A blank line ends the HTML block, and what follows is markdown's again.
/// That is how a body puts prose inside a wrapper and still has it read as
/// prose — by the tag alone it is markup, and the rewrite leaves markup be.
#[test]
fn prose_a_blank_line_below_a_wrapper_is_still_prose() {
    assert_eq!(
        rewrite(
            "<div>\n\nUse the Read tool here.\n\n</div>\n",
            HarnessId::Opencode
        ),
        "<div>\n\nUse the read tool here.\n\n</div>\n"
    );
}

/// The converse, and the reading main did not have: a fence line inside an
/// HTML block opens no fence, because markdown never read it as one. So
/// the blank line below it ends the block rather than the fence, and what
/// follows is prose.
#[test]
fn a_fence_inside_a_raw_html_block_opens_nothing() {
    assert_eq!(
        rewrite("<div>\n```\n\nuse the Read tool\n", HarnessId::Opencode),
        "<div>\n```\n\nuse the read tool\n"
    );
}

/// A table cell is a leaf block of its own, so a backtick in one cell and
/// a backtick in the next are two literal characters rather than a span
/// across the boundary. A reader that pairs them quotes the tail of the
/// first cell and the head of the second, and leaves the reference
/// standing in Claude's words with no warning that it did.
#[test]
fn backticks_in_two_table_cells_do_not_pair_across_the_boundary() {
    let body = "| how | when |\n|---|---|\n| `git log | use the Read tool` |\n";
    assert_eq!(
        rewrite(body, HarnessId::Codex),
        "| how | when |\n|---|---|\n| `git log | open the file` |\n"
    );
    assert_eq!(
        rewrite(body, HarnessId::Opencode),
        "| how | when |\n|---|---|\n| `git log | use the read tool` |\n"
    );
}

#[test]
fn rewriting_rewritten_text_changes_nothing() {
    let body = concat!(
        "Use the Read tool, the `Grep` tool, and the Bash tool.\n",
        "The Write tool overwrites; the mcp__gh tool does not.\n",
        "```\nthe Read tool\n```\n",
    );
    for harness in [
        HarnessId::Codex,
        HarnessId::Opencode,
        HarnessId::Cursor,
        HarnessId::Pi,
    ] {
        let once = rewrite(body, harness);
        assert_eq!(rewrite(&once, harness), once, "{harness:?} is not stable");
    }
}

/// Hook matchers are regexes over each tool's own names. Every alternative
/// kendex can restate it restates; a token carrying regex syntax around a
/// name stays exactly as authored and is reported as such.
#[test]
fn a_hook_matcher_is_restated_alternative_by_alternative() {
    assert_eq!(
        hook_matcher("Bash", HarnessId::Gemini),
        ("run_shell_command".to_owned(), true)
    );
    assert_eq!(
        hook_matcher("Bash", HarnessId::Copilot),
        ("bash".to_owned(), true)
    );
    assert_eq!(
        hook_matcher("Bash|Write", HarnessId::Antigravity),
        ("run_command|write_to_file".to_owned(), true)
    );
    assert_eq!(
        hook_matcher("mcp__gh", HarnessId::Antigravity),
        ("mcp__gh".to_owned(), true)
    );
    assert_eq!(
        hook_matcher("Bash|Write", HarnessId::Gemini),
        ("run_shell_command|write_file".to_owned(), true)
    );
    // A name neither tool documents narrows nothing and is left alone.
    assert_eq!(
        hook_matcher("mcp__gh", HarnessId::Copilot),
        ("mcp__gh".to_owned(), true)
    );
    // Pure syntax names no tool, so there is nothing to restate.
    assert_eq!(
        hook_matcher(".*", HarnessId::Gemini),
        (".*".to_owned(), true)
    );
    // Syntax around a name: kept as authored, and said out loud.
    assert_eq!(
        hook_matcher("Bash.*", HarnessId::Gemini),
        ("Bash.*".to_owned(), false)
    );
    // Claude's own names are what a matcher is authored in.
    assert_eq!(
        hook_matcher("Bash", HarnessId::Claude),
        ("Bash".to_owned(), true)
    );
}

/// The rewrite says each line in the harness's words and gives back one
/// line for every line it was handed. The fork's capture pairs a rendering
/// with the prose it was published as by position, so a rewrite that
/// wrapped, split or joined a line would leave the two holding different
/// numbers of lines, and every fork off that harness of a body carrying
/// such a line would refuse.
#[test]
fn every_harness_gives_back_one_line_for_every_line() {
    let body = concat!(
        "Use the Read tool, then the `Grep` tool.\n",
        "\n",
        "See [the Bash tool](docs/bash.md) and the mcp__gh tool.\n",
        "\n",
        "```sh\n",
        "use the Bash tool\n",
        "```\n",
        "\n",
        "Read .agents/skills/gh/SKILL.md first.\n",
        "\n",
        "Use the WebFetch tool last.\n",
    );
    // Claude hands the body straight back, so the count holds for it
    // trivially and every harness in ALL is covered.
    for harness in HarnessId::ALL {
        let (text, _) = rewrite_prose(body, harness);
        assert_eq!(
            text.lines().count(),
            body.lines().count(),
            "{harness:?} changed how many lines the body has: {text}"
        );
    }
}
