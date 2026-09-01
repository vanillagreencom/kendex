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
fn code_links_and_skill_paths_keep_every_byte() {
    let body = concat!(
        "```\nuse the Read tool\n```\n",
        "~~~md\nuse the Read tool\n~~~\n",
        "````\n```\nuse the Read tool\n```\n````\n",
        "Run `use the Read tool` verbatim.\n",
        "See [the Read tool](https://example.com/the-Read-tool).\n",
        "- dev: .agents/skills/dev/SKILL.md — read it with the Read tool\n",
    );
    for harness in [HarnessId::Codex, HarnessId::Opencode, HarnessId::Cursor] {
        let (text, warnings) = rewrite_prose(body, harness);
        assert_eq!(text, body, "{harness:?} rewrote protected text");
        assert!(
            warnings.is_empty(),
            "{harness:?} warned about protected text"
        );
    }
}

#[test]
fn an_unclosed_fence_protects_the_rest_of_the_body() {
    let body = "```\nuse the Read tool\nstill fenced: the Bash tool\n";
    assert_eq!(rewrite(body, HarnessId::Opencode), body);
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

/// A fenced block nested in a list item is indented four spaces — the shape
/// most real skills use. Reading that as prose rewrites a sample the agent
/// was told to copy verbatim.
#[test]
fn an_indented_fence_is_still_a_fence() {
    let body = "1. Run this:\n\n    ```sh\n    use the Bash tool\n    ```\n\nDone.\n";
    for harness in [HarnessId::Codex, HarnessId::Opencode, HarnessId::Cursor] {
        let (text, warnings) = rewrite_prose(body, harness);
        assert_eq!(text, body, "{harness:?} rewrote an indented block");
        assert!(warnings.is_empty(), "{harness:?} warned: {warnings:?}");
    }
}

#[test]
fn prose_about_tools_is_never_mistaken_for_a_reference() {
    for body in [
        "Pick the right tool for the job.\n",
        "Prefer the dedicated tools over shell commands.\n",
        "The toolkit is yours.\n",
        "the Read toolbox\n",
    ] {
        let (text, warnings) = rewrite_prose(body, HarnessId::Codex);
        assert_eq!(text, body);
        assert!(warnings.is_empty(), "{body} warned");
    }
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
    // trivially and a harness added to ALL is covered the day it lands.
    for harness in HarnessId::ALL {
        let (text, _) = rewrite_prose(body, harness);
        assert_eq!(
            text.lines().count(),
            body.lines().count(),
            "{harness:?} changed how many lines the body has: {text}"
        );
    }
}
