use super::*;

fn parse(text: &str) -> Table {
    text.parse().unwrap()
}

#[test]
fn every_finding_carries_a_fix() {
    let table = parse(
        r#"
schema = 99
typo-table = 1

[sources.bad]
enabled = true

[install]
harnesses = ["claude", "emacs"]

[skills.x]
source = "nowhere"

[agents."-bad/name"]
source = "local"

[mcp-servers.gh]
source = "nowhere"

[plugins."fmt@main"]
version = "1"
harness = "cursor"

[agent-frontmatter.claude.orch]
tools = ["a"]

[[custom-hooks]]
matcher = "Bash"
"#,
    );
    let findings = validate(&table);
    let locations: Vec<_> = findings.iter().map(|f| f.location.as_str()).collect();
    assert!(locations.contains(&"mcp-servers.gh"));
    assert!(locations.contains(&"plugins.fmt@main"));
    // Cursor reads no plugin map kendex can write, so aiming a plugin at
    // it asks for a write with nowhere to land.
    assert!(locations.contains(&"plugins.fmt@main.harness"));
    assert!(locations.contains(&"schema"));
    assert!(locations.contains(&"typo-table"));
    assert!(locations.contains(&"sources.bad"));
    assert!(locations.contains(&"install.harnesses"));
    assert!(locations.contains(&"skills.x"));
    assert!(locations.contains(&"agents.-bad/name"));
    assert!(locations.contains(&"agent-frontmatter.claude.orch.tools"));
    assert!(locations.iter().any(|l| l.starts_with("custom-hooks[0]")));
    for finding in &findings {
        assert!(!finding.fix.is_empty(), "{finding}");
    }
}

/// One row per manifest, and every finding it gets as (location, problem)
/// in order, so a row pins what was found, where, and that nothing else
/// was. The location discriminates a finding; the fix beside it is
/// authoring guidance, so every row asserts each finding carries one and
/// none pins its wording. Only the current schema validates: an
/// older number, a newer one, and no number at all are one finding, so
/// the editor rejects exactly what a file read does. A known override key
/// under a harness that never renders it is a setting the author believes
/// is in force and is not. A plugin segment is only a name for the kinds
/// a marketplace catalog offers: a hook, a server or a Pi extension named
/// with a `/` would install into a directory nothing ever cleans up, so it
/// is refused where it is written. A revision belongs to a repository, and
/// a key nobody reads is a typo the user should hear about rather than a
/// setting that quietly does nothing. An event no harness fires is a hook
/// that would install cleanly and then never run — nothing downstream
/// reads the name, so this is the only place it can be caught. A custom
/// hook's identity and parity fields are each checked, and the clean one
/// beside them gets nothing. The safety-decision tables schema 6 retired
/// are stray keys like any other; an older file carrying them never
/// reaches here, since the schema below current is refused at the read.
#[test]
#[allow(clippy::too_many_lines)]
fn every_manifest_defect_is_located_with_nothing_else_said() {
    let kendex = "[sources.kendex]\nrepo = \"vanillagreencom/kendex\"\n";
    let schema = ("schema", "missing or unsupported schema version");
    let rows: Vec<(String, Vec<(&str, &str)>)> = vec![
        (format!("schema = 6\n{kendex}"), vec![]),
        (format!("schema = 5\n{kendex}"), vec![schema]),
        (format!("schema = 7\n{kendex}"), vec![schema]),
        (kendex.to_owned(), vec![schema]),
        (
            "schema = 6\n[agent-frontmatter.gemini.rust]\neffort = \"high\"\nmodel = \"inherit\"\n[agent-frontmatter.claude.rust]\neffort = \"high\"\n[agent-frontmatter.cursor.rust]\ncolor = \"red\"\n[agent-frontmatter.antigravity.rust]\neffort = \"high\"\nmodel = \"opus\"\n".to_owned(),
            vec![
                ("agent-frontmatter.antigravity.rust.effort", "antigravity renders no `effort`, so this override changes nothing"),
                ("agent-frontmatter.cursor.rust.color", "cursor renders no `color`, so this override changes nothing"),
                ("agent-frontmatter.gemini.rust.effort", "gemini renders no `effort`, so this override changes nothing"),
            ],
        ),
        (
            "schema = 6\n[sources.kendex]\nrepo = \"vanillagreencom/kendex\"\n[skills.github]\nsource = \"kendex\"\n[agents.local-one]\nsource = \"local\"\n[hooks.guard]\nsource = \"kendex\"\n[mcp-servers.gh]\nsource = \"kendex\"\n[plugins.\"fmt@main\"]\nenabled = false\nharness = \"copilot\"\n".to_owned(),
            vec![],
        ),
        (
            "schema = 6\n[sources.market]\nrepo = \"owner/market\"\n[skills.\"tools/eda\"]\nsource = \"market\"\n[agents.\"tools/reviewer\"]\nsource = \"market\"\n[commands.\"tools/report\"]\nsource = \"market\"\n[pi-extensions.\"@scope/pkg\"]\nsource = \"market\"\n".to_owned(),
            vec![],
        ),
        (
            "schema = 6\n[sources.market]\nrepo = \"owner/market\"\n[hooks.\"tools/guard\"]\nsource = \"market\"\n[mcp-servers.\"tools/gh\"]\nsource = \"market\"\n[pi-extensions.\"tools/ext\"]\nsource = \"market\"\n".to_owned(),
            vec![
                ("hooks.tools/guard", "`tools/guard` holds `/`, which no filename may"),
                ("mcp-servers.tools/gh", "`tools/gh` holds `/`, which no filename may"),
                ("pi-extensions.tools/ext", "`tools/ext` holds `/`, which no filename may"),
            ],
        ),
        (
            "schema = 6\n[sources.pinned]\nrepo = \"owner/repo\"\nrev = \"v1.2.0\"\n".to_owned(),
            vec![],
        ),
        (
            "schema = 6\n[sources.local-path]\npath = \"../catalog\"\nrev = \"v1.2.0\"\n[sources.typo]\nrepo = \"owner/repo\"\nrevision = \"v1\"\n[sources.wrong-type]\nrepo = \"owner/repo\"\nrev = 12\n".to_owned(),
            vec![
                ("sources.local-path", "only a repo has revisions"),
                ("sources.typo", "unknown key 'revision'"),
                ("sources.wrong-type", "rev must be a string"),
            ],
        ),
        (
            "schema = 6\n[[custom-hooks]]\nevent = \"PreToolUse\"\ncommand = \"./guard.sh\"\n[[custom-hooks]]\nevent = \"PreToolUSe\"\ncommand = \"./guard.sh\"\n".to_owned(),
            vec![("custom-hooks[1].event", "no harness fires 'PreToolUSe'")],
        ),
        (
            "schema = 6\n[hooks.guard]\nsource = \"local\"\n[[custom-hooks]]\nname = \"guard\"\nevent = \"PreToolUse\"\ncommand = \"./a.sh\"\n[[custom-hooks]]\nname = \"Bad Name\"\nevent = \"Stop\"\ncommand = \"./b.sh\"\ntimeout = 0\nharnesses = [\"claude\", \"emacs\"]\ntypo-key = 1\n[[custom-hooks]]\nname = \"twice\"\nevent = \"Stop\"\ncommand = \"./c.sh\"\n[[custom-hooks]]\nname = \"twice\"\nevent = \"Stop\"\ncommand = \"./d.sh\"\n".to_owned(),
            vec![
                ("custom-hooks[0].name", "'guard' is already an installed hook"),
                ("custom-hooks[1]", "unknown key 'typo-key'"),
                ("custom-hooks[1].name", "'Bad Name' is not a usable hook name"),
                ("custom-hooks[1].timeout", "timeout must be whole seconds, 1 to 3600"),
                ("custom-hooks[1].harnesses", "unknown harness 'emacs'"),
                ("custom-hooks[3].name", "'twice' names two custom hooks"),
            ],
        ),
        (
            "schema = 6\n[[custom-hooks]]\nname = \"guard-pretooluse\"\nevent = \"PreToolUse\"\nmatcher = \"Bash\"\ncommand = \"./guard.sh\"\ntimeout = 30\nharnesses = [\"claude\"]\nagents = \"all\"\n".to_owned(),
            vec![],
        ),
        (
            "schema = 6\n[sources.market]\nrepo = \"owner/market\"\n[skills.deploy]\nsource = \"market\"\n[safety-overrides.\"skill:deploy:claude\"]\nreview-hash = \"abc\"\n[safety-reviews.\"skill:deploy:claude\"]\nreview-hash = \"abc\"\n".to_owned(),
            vec![
                ("safety-overrides", "unknown table or key"),
                ("safety-reviews", "unknown table or key"),
            ],
        ),
    ];
    for (manifest, expected) in rows {
        let found = validate(&parse(&manifest));
        assert!(
            found.iter().all(|finding| !finding.fix.is_empty()),
            "{manifest}: {found:?}"
        );
        let findings: Vec<(String, String)> = found
            .into_iter()
            .map(|finding| (finding.location, finding.problem))
            .collect();
        let expected: Vec<(String, String)> = expected
            .into_iter()
            .map(|(location, problem)| (location.to_owned(), problem.to_owned()))
            .collect();
        assert_eq!(findings, expected, "{manifest}");
    }
}

/// Every part of a finding is escaped, because the refusal that carries
/// findings is the one the CLI splits into lines: a break in any of the
/// three would become a finding of its own on the reader's screen.
///
/// All three, not the location alone. A finding is composed here and
/// nowhere else — `CoreError::ManifestInvalid` takes `Finding`, not text —
/// so a constructor that interpolates a name into `problem` or a path into
/// `fix` is covered by this and by nothing else.
#[test]
fn a_finding_is_one_line_however_its_parts_are_written() {
    let hostile = "we\nir\u{1b}[31md";
    let finding = Finding {
        location: hostile.to_owned(),
        problem: format!("clashes with {hostile}"),
        fix: format!("rename {hostile}"),
    };
    let said = joined(std::slice::from_ref(&finding));
    assert_eq!(said.lines().count(), 1, "{said:?}");
    assert!(!said.contains('\u{1b}'), "{said:?}");
    assert_eq!(said.matches("we\\nir\\u{1b}[31md").count(), 3, "{said:?}");

    // Two findings are two lines, which is the shape the door exists for.
    let pair = joined(&[finding.clone(), finding]);
    assert_eq!(pair.lines().count(), 2, "{pair:?}");
}
