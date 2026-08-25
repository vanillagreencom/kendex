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

#[test]
fn a_clean_manifest_validates_empty() {
    let table = parse(
        r#"
schema = 1
[sources.vstack]
repo = "vanillagreencom/vstack"
[skills.github]
source = "vstack"
[agents.local-one]
source = "local"
[hooks.guard]
source = "vstack"
[mcp-servers.gh]
source = "vstack"
[plugins."fmt@main"]
enabled = false
harness = "copilot"
"#,
    );
    assert_eq!(validate(&table), Vec::new());
}

/// A plugin segment is only a name for the kinds a marketplace catalog
/// offers. A hook or a server named with a `/` would install into a
/// directory nothing ever cleans up, so it is refused where it is written.
#[test]
fn only_the_kinds_a_catalog_offers_may_carry_a_plugin_segment() {
    let table = parse(
        r#"
schema = 6
[sources.market]
repo = "owner/market"
[skills."tools/eda"]
source = "market"
[agents."tools/reviewer"]
source = "market"
[commands."tools/report"]
source = "market"
[pi-extensions."@scope/pkg"]
source = "market"
"#,
    );
    assert_eq!(validate(&table), Vec::new());

    let table = parse(
        r#"
schema = 6
[sources.market]
repo = "owner/market"
[hooks."tools/guard"]
source = "market"
[mcp-servers."tools/gh"]
source = "market"
[pi-extensions."tools/ext"]
source = "market"
"#,
    );
    let findings = validate(&table);
    let located: Vec<&str> = findings.iter().map(|f| f.location.as_str()).collect();
    for location in [
        "hooks.tools/guard",
        "mcp-servers.tools/gh",
        "pi-extensions.tools/ext",
    ] {
        assert!(located.contains(&location), "{located:?}");
    }
    for finding in &findings {
        assert!(finding.fix.contains("without a `/`"), "{finding}");
    }
}

/// A revision belongs to a repository, and a key nobody reads is a typo
/// the user should hear about rather than a setting that quietly does
/// nothing.
#[test]
fn a_source_revision_is_a_string_on_a_repo_and_stray_keys_are_findings() {
    let table = parse(
        r#"
schema = 6
[sources.pinned]
repo = "owner/repo"
rev = "v1.2.0"
"#,
    );
    assert_eq!(validate(&table), Vec::new());

    let table = parse(
        r#"
schema = 6
[sources.local-path]
path = "../catalog"
rev = "v1.2.0"
[sources.typo]
repo = "owner/repo"
revision = "v1"
[sources.wrong-type]
repo = "owner/repo"
rev = 12
"#,
    );
    let findings = validate(&table);
    let problems: Vec<&str> = findings.iter().map(|f| f.problem.as_str()).collect();
    assert!(
        problems.contains(&"only a repo has revisions"),
        "{problems:?}"
    );
    assert!(problems.contains(&"unknown key 'revision'"), "{problems:?}");
    assert!(problems.contains(&"rev must be a string"), "{problems:?}");
    for finding in &findings {
        assert!(finding.fix.contains("rev"), "{finding}");
    }
}

/// An event no harness fires is a hook that would install cleanly and then
/// never run — nothing downstream reads the name, so this is the only place
/// it can be caught.
#[test]
fn a_custom_hook_event_must_be_one_a_harness_fires() {
    let table: toml::Table = r#"
schema = 1
[[custom-hooks]]
event = "PreToolUse"
command = "./guard.sh"
[[custom-hooks]]
event = "PreToolUSe"
command = "./guard.sh"
"#
    .parse()
    .unwrap();

    let findings = validate(&table);
    let event = findings
        .iter()
        .find(|f| f.location == "custom-hooks[1].event")
        .expect("the typo should be reported");
    assert!(event.problem.contains("PreToolUSe"), "{event:?}");
    assert!(event.fix.contains("PreToolUse"), "{event:?}");
    assert!(
        !findings
            .iter()
            .any(|f| f.location.starts_with("custom-hooks[0]")),
        "{findings:?}"
    );
}

#[test]
fn custom_hook_identity_and_parity_fields_are_checked() {
    let table: toml::Table = r#"
schema = 1
[hooks.guard]
source = "local"
[[custom-hooks]]
name = "guard"
event = "PreToolUse"
command = "./a.sh"
[[custom-hooks]]
name = "Bad Name"
event = "Stop"
command = "./b.sh"
timeout = 0
harnesses = ["claude", "emacs"]
typo-key = 1
[[custom-hooks]]
name = "twice"
event = "Stop"
command = "./c.sh"
[[custom-hooks]]
name = "twice"
event = "Stop"
command = "./d.sh"
"#
    .parse()
    .unwrap();

    let findings = validate(&table);
    let at = |loc: &str| {
        findings
            .iter()
            .find(|f| f.location == loc)
            .unwrap_or_else(|| panic!("expected a finding at {loc}: {findings:?}"))
    };
    assert!(
        at("custom-hooks[0].name")
            .problem
            .contains("installed hook")
    );
    assert!(at("custom-hooks[1].name").problem.contains("Bad Name"));
    assert!(at("custom-hooks[1].timeout").problem.contains("1 to 3600"));
    assert!(at("custom-hooks[1].harnesses").problem.contains("emacs"));
    assert!(at("custom-hooks[1]").problem.contains("typo-key"));
    assert!(at("custom-hooks[3].name").problem.contains("names two"));
    assert!(
        !findings
            .iter()
            .any(|f| f.location.starts_with("custom-hooks[2]")),
        "{findings:?}"
    );
}

#[test]
fn a_clean_named_custom_hook_validates_empty() {
    let table: toml::Table = r#"
schema = 1
[[custom-hooks]]
name = "guard-pretooluse"
event = "PreToolUse"
matcher = "Bash"
command = "./guard.sh"
timeout = 30
harnesses = ["claude"]
agents = "all"
"#
    .parse()
    .unwrap();
    assert_eq!(validate(&table), Vec::new());
}
