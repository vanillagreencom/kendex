use super::*;
const V1_MANIFEST: &str = r#"
project-skills-dir = ".claude/skills-src"

[agent-launch-instructions]
generalist = ""
rust = "Read docs/architecture.md before coding."

[agent-guidance]
iced = "Read docs/ui.md."

[agent-skills]
rust = ["dev", "github"]

[skill-instructions]
github = "prefer gh cli"

[agent-colors]
rust = "orange"

[agent-frontmatter.claude-code.rust]
model = "opus"
deny-tools = "WebSearch, WebFetch"
allowedSubagents = ["scout"]
tools = ["Read"]

[agent-frontmatter.legacykey]
color = "red"
tools = ["Read", "Grep"]

[[custom-hooks]]
event = "PreToolUse"
matcher = "Bash"
command = "./guard.sh"
"#;

const V1_LOCK: &str = r#"{
  "version": 1,
  "entries": {
    "decider": {
      "name": "decider", "kind": "skill",
      "source": "vanillagreencom/vstack", "source_repo": "vanillagreencom/vstack",
      "harnesses": ["pi", "claude-code", "codex"],
      "method": "symlink", "installed_at": "2026-08-10T15:42:13Z", "source_hash": "3a368ae2"
    },
    "rust": {
      "name": "rust", "kind": "agent",
      "source": "/home/u/dev/vstack", "source_repo": "vanillagreencom/vstack",
      "harnesses": ["claude-code"],
      "method": "symlink", "installed_at": "2026-08-10T15:42:13Z", "source_hash": "aa"
    },
    "sunset": {
      "name": "sunset", "kind": "extra",
      "source": "vanillagreencom/vstack",
      "harnesses": [], "method": "symlink", "installed_at": "", "source_hash": ""
    }
  }
}"#;

#[test]
fn converts_tables_with_aliases_and_drops_the_dead_ones() {
    let outcome = convert(Some(V1_MANIFEST), None).unwrap();
    let m = &outcome.manifest;
    assert_eq!(m.schema, crate::manifest::MANIFEST_SCHEMA);
    assert_eq!(
        m.agent_launch_instructions.get("rust").map(String::as_str),
        Some("Read docs/architecture.md before coding.")
    );
    // The `agent-guidance` alias merges; empty strings drop.
    assert!(m.agent_launch_instructions.contains_key("iced"));
    assert!(!m.agent_launch_instructions.contains_key("generalist"));
    assert_eq!(m.agent_skills["rust"], ["dev", "github"]);
    let overrides = &m.agent_frontmatter["claude"]["rust"];
    assert_eq!(overrides.model.as_deref(), Some("opus"));
    assert_eq!(
        overrides.deny_tools,
        Some(vec!["WebSearch".to_owned(), "WebFetch".to_owned()])
    );
    assert_eq!(overrides.allowed_subagents, Some(vec!["scout".to_owned()]));
    // The v1 `tools` allowlist survives as allow-only intent — dropping it
    // would migrate a restricted agent unrestricted.
    assert_eq!(overrides.allow_tools, Some(vec!["Read".to_owned()]));
    assert_eq!(m.custom_hooks.len(), 1);
    let joined = outcome.notes.join("\n");
    assert!(joined.contains("agent-colors"));
    assert!(joined.contains("legacykey"));
    assert!(joined.contains("tools"));
    // v1's committed-vs-generated skills split is gone: the key is dropped
    // with a note, never carried into the new manifest.
    assert!(joined.contains("project-skills-dir"));
}

#[test]
fn harness_agnostic_overrides_expand_to_every_harness() {
    let outcome = convert(Some(V1_MANIFEST), None).unwrap();
    let m = &outcome.manifest;
    for harness in crate::model::HarnessId::ALL {
        let overrides = &m.agent_frontmatter[harness.name()]["legacykey"];
        assert_eq!(
            overrides.color.as_deref(),
            Some("red"),
            "{}",
            harness.name()
        );
        assert_eq!(
            overrides.allow_tools,
            Some(vec!["Read".to_owned(), "Grep".to_owned()]),
            "{}",
            harness.name()
        );
    }
    assert!(
        outcome
            .notes
            .iter()
            .any(|n| n.contains("expanded harness-agnostic"))
    );
}

#[test]
fn lock_entries_split_per_harness_and_extras_are_skipped() {
    let outcome = convert(None, Some(V1_LOCK)).unwrap();
    assert_eq!(outcome.lock.entries.len(), 4);
    assert!(outcome.lock.entries.contains_key("skill:decider:pi"));
    assert!(outcome.lock.entries.contains_key("skill:decider:claude"));
    assert!(outcome.lock.entries.contains_key("agent:rust:claude"));
    // Declarations + the default source derive from the lock. v1 wrote the
    // pre-rename default repo; the import maps it and writes the current
    // name and repo everywhere, entries included.
    assert_eq!(outcome.manifest.skills["decider"].source, "kendex");
    assert_eq!(outcome.manifest.agents["rust"].source, "kendex");
    assert_eq!(
        outcome.manifest.sources["kendex"].repo.as_deref(),
        Some("vanillagreencom/kendex")
    );
    assert_eq!(
        outcome.lock.entries["skill:decider:claude"].source_repo,
        "vanillagreencom/kendex"
    );
    assert!(outcome.notes.iter().any(|n| n.contains("sunset")));
    // Imported hashes never match recomputed ones → first refresh
    // regenerates.
    assert!(
        outcome.lock.entries["skill:decider:pi"]
            .source_hash
            .starts_with("v1:")
    );
}

/// v1 named no owner, and one installed skill proves nothing about who
/// seeded a key — the seeder may be long gone — so no import guesses an
/// owner; a template earns the record later by matching the comment.
#[test]
fn settings_seeds_import_legacy_owned_even_with_one_skill_installed() {
    let lock = r#"{
        "version": 1,
        "entries": {
            "decider": { "kind": "skill", "source": "vanillagreencom/vstack",
                         "harnesses": ["claude-code"], "installed_at": "t", "source_hash": "x" }
        },
        "settings_seeds": { "REVIEWERS": "cbf29ce484222325" }
    }"#;
    let outcome = convert(None, Some(lock)).unwrap();
    let record = outcome.lock.settings_seeds.get("REVIEWERS").unwrap();
    assert_eq!(record.owner, None);
    // Hash-for-hash: same algorithm, so migrated repos keep verifying
    // instead of re-freezing.
    assert_eq!(record.hash, "cbf29ce484222325");
}

/// A record whose hash is not a string cannot verify anything: skipped
/// with a note, never imported as a record that would freeze the key.
#[test]
fn malformed_settings_seed_records_are_skipped_with_a_note() {
    let lock = r#"{
        "version": 1,
        "entries": {},
        "settings_seeds": { "REVIEWERS": 12, "DEPTH": "cbf29ce484222325" }
    }"#;
    let outcome = convert(None, Some(lock)).unwrap();
    assert!(!outcome.lock.settings_seeds.contains_key("REVIEWERS"));
    assert!(outcome.lock.settings_seeds.contains_key("DEPTH"));
    assert!(
        outcome
            .notes
            .iter()
            .any(|n| n.contains("malformed settings seed record 'REVIEWERS'")),
        "{:?}",
        outcome.notes
    );
}

#[test]
fn contested_settings_seeds_import_legacy_owned() {
    let lock = r#"{
        "version": 1,
        "entries": {
            "one": { "kind": "skill", "source": "vanillagreencom/vstack",
                     "harnesses": ["claude-code"], "installed_at": "t", "source_hash": "x" },
            "two": { "kind": "skill", "source": "vanillagreencom/vstack",
                     "harnesses": ["claude-code"], "installed_at": "t", "source_hash": "x" }
        },
        "settings_seeds": { "REVIEWERS": "cbf29ce484222325" }
    }"#;
    let outcome = convert(None, Some(lock)).unwrap();
    let record = outcome.lock.settings_seeds.get("REVIEWERS").unwrap();
    assert_eq!(record.owner, None, "contested keys import legacy-owned");
    assert!(
        outcome
            .notes
            .iter()
            .any(|n| n.contains("stays as it is until a skill's template matches it")),
        "{:?}",
        outcome.notes
    );
}

/// A symlinked project's v1 lock is the shared-path case whatever spelling
/// the scope arrived under: both lock paths derive from the canonical root,
/// so the same file can never compare unequal and be refused as a foreign
/// v1 record sitting at the v2 path (macOS reaches every temp directory
/// through the `/var` → `/private/var` link).
#[cfg(unix)]
#[test]
#[allow(clippy::unwrap_used)]
fn a_symlinked_project_migrates_its_v1_lock() {
    let tmp = tempfile::tempdir().unwrap();
    let env = crate::env::Env::fake(tmp.path(), crate::env::FakeOs::Linux);
    let real = tmp.path().join("dev/app");
    std::fs::create_dir_all(real.join(".claude")).unwrap();
    std::fs::write(real.join("vstack.toml"), V1_MANIFEST).unwrap();
    std::fs::write(real.join(".vstack-lock.json"), V1_LOCK).unwrap();
    std::os::unix::fs::symlink(tmp.path().join("dev"), tmp.path().join("via")).unwrap();
    let scope = crate::model::Scope::Project {
        root: tmp.path().join("via/app"),
    };

    let migration = super::migrate::migrate_scope(&env, &scope).unwrap();
    assert!(migration.migrated.is_some(), "{:?}", migration.notes);
}
