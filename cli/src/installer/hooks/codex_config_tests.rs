//! Writing Codex's `config.toml`: the feature flag and the deprecated-key
//! migration. Both edits are structural, so string CONTENT that happens to
//! spell a table header or an assignment must come back byte-identical, and a
//! file that does not parse must come back untouched.

use super::codex::{
    CodexHooksFeature, codex_hooks_feature_state, enable_codex_hooks_feature,
    migrate_codex_hooks_feature,
};
use super::tests::tmpdir;

/// The multiline string a user might write to document Codex's own layout: it
/// spells a `[features]` table and a deprecated assignment, and neither is
/// configuration. Nothing in the file sets a real feature.
const STRING_SPELLING_A_FEATURES_TABLE: &str = "notes = '''\n\
Codex reads its flags from a table like this:\n\
\n\
[features]\n\
codex_hooks = true\n\
\n\
and vstack is what sets one.\n\
'''";

fn config_documenting_features() -> String {
    format!(
        "model = \"gpt-5.6-sol\"\n\n{STRING_SPELLING_A_FEATURES_TABLE}\n\n[profiles.default]\napproval_policy = \"never\"\n"
    )
}

fn parse(body: &str) -> toml::Value {
    body.parse::<toml::Value>()
        .unwrap_or_else(|err| panic!("vstack wrote a config that does not parse: {err}\n{body}"))
}

#[test]
fn enabling_hooks_treats_a_features_header_inside_a_string_as_content() {
    let dir = tmpdir("codex_features_string_header");
    let config = dir.join("config.toml");
    let original = config_documenting_features();
    std::fs::write(&config, &original).unwrap();

    enable_codex_hooks_feature(&config).unwrap();

    let body = std::fs::read_to_string(&config).unwrap();
    assert!(
        body.contains(STRING_SPELLING_A_FEATURES_TABLE),
        "the user's string is content and comes back byte-identical, got:\n{body}"
    );
    let parsed = parse(&body);
    assert_eq!(
        parsed
            .get("features")
            .and_then(|features| features.get("hooks"))
            .and_then(toml::Value::as_bool),
        Some(true),
        "a real [features] table now carries the flag, got:\n{body}"
    );
    assert!(
        parsed.get("hooks").is_none(),
        "nothing is written at the document root, got:\n{body}"
    );
    assert_eq!(
        parsed
            .get("profiles")
            .and_then(|profiles| profiles.get("default"))
            .and_then(|default| default.get("approval_policy"))
            .and_then(toml::Value::as_str),
        Some("never"),
        "the user's own table is untouched, got:\n{body}"
    );
    // The predicate `check` reads with must agree the install landed.
    assert_eq!(
        codex_hooks_feature_state(&config),
        CodexHooksFeature::Enabled
    );
    let _ = std::fs::remove_dir_all(&dir);
}

#[test]
fn migration_leaves_a_deprecated_key_inside_a_string_alone() {
    let dir = tmpdir("codex_features_string_deprecated");
    let config = dir.join("config.toml");
    let original = config_documenting_features();
    std::fs::write(&config, &original).unwrap();

    migrate_codex_hooks_feature(&config).unwrap();

    assert_eq!(
        std::fs::read_to_string(&config).unwrap(),
        original,
        "no feature is configured anywhere, so the migration has nothing to move and writes nothing"
    );
    let _ = std::fs::remove_dir_all(&dir);
}

#[test]
fn enabling_hooks_preserves_comments_and_key_order() {
    let dir = tmpdir("codex_features_formatting");
    let config = dir.join("config.toml");
    std::fs::write(
        &config,
        "# vstack must not reformat this file.\n\
         model   =   \"gpt-5.6-sol\"  # pinned on purpose\n\
         \n\
         [features]\n\
         # kept: the user's own note\n\
         web_search = true\n\
         codex_hooks = false\n\
         \n\
         [profiles.default]\n\
         approval_policy = \"never\"\n",
    )
    .unwrap();

    enable_codex_hooks_feature(&config).unwrap();

    assert_eq!(
        std::fs::read_to_string(&config).unwrap(),
        "# vstack must not reformat this file.\n\
         model   =   \"gpt-5.6-sol\"  # pinned on purpose\n\
         \n\
         [features]\n\
         # kept: the user's own note\n\
         web_search = true\n\
         hooks = true\n\
         \n\
         [profiles.default]\n\
         approval_policy = \"never\"\n"
    );
    let _ = std::fs::remove_dir_all(&dir);
}

#[test]
fn enabling_hooks_keeps_the_formatting_of_the_value_it_replaces() {
    let dir = tmpdir("codex_features_value_decor");
    let config = dir.join("config.toml");
    std::fs::write(
        &config,
        "[features]\nhooks   =   false  # turned off by hand\n",
    )
    .unwrap();

    enable_codex_hooks_feature(&config).unwrap();

    assert_eq!(
        std::fs::read_to_string(&config).unwrap(),
        "[features]\nhooks   =   true  # turned off by hand\n",
        "the flag flips; the user's spacing and comment are theirs to keep"
    );
    let _ = std::fs::remove_dir_all(&dir);
}

#[test]
fn an_unparseable_config_is_refused_and_left_alone() {
    let dir = tmpdir("codex_features_unparseable");
    let config = dir.join("config.toml");
    let original = "model = \"gpt-5.6-sol\"\n[features\nhooks = true\n";
    std::fs::write(&config, original).unwrap();

    let err = enable_codex_hooks_feature(&config).expect_err("a config nothing parses is refused");
    let rendered = format!("{err:#}");
    assert!(
        rendered.contains(crate::json_config::REFUSE_UNPARSEABLE_CONFIG)
            && rendered.contains(&config.display().to_string()),
        "the refusal names the rule and the file: {rendered}"
    );
    assert_eq!(std::fs::read_to_string(&config).unwrap(), original);
    let _ = std::fs::remove_dir_all(&dir);
}

#[test]
fn a_features_value_that_is_not_a_table_is_refused_by_name() {
    let dir = tmpdir("codex_features_not_a_table");
    let config = dir.join("config.toml");
    let original = "features = \"all\"\n";
    std::fs::write(&config, original).unwrap();

    let err = enable_codex_hooks_feature(&config).expect_err("there is nowhere to put the flag");
    let rendered = format!("{err:#}");
    assert!(
        rendered.contains("`features`") && rendered.contains(&config.display().to_string()),
        "the refusal names the key and the file: {rendered}"
    );
    assert_eq!(std::fs::read_to_string(&config).unwrap(), original);
    let _ = std::fs::remove_dir_all(&dir);
}

#[test]
fn a_hooks_table_is_refused_rather_than_replaced() {
    let dir = tmpdir("codex_features_hooks_table");
    let config = dir.join("config.toml");
    let original = "[features.hooks]\nallowed = [\"PreToolUse\"]\n";
    std::fs::write(&config, original).unwrap();

    let err = enable_codex_hooks_feature(&config).expect_err("replacing it would delete content");
    let rendered = format!("{err:#}");
    assert!(
        rendered.contains("`features.hooks`") && rendered.contains(&config.display().to_string()),
        "the refusal names the key and the file: {rendered}"
    );
    assert_eq!(std::fs::read_to_string(&config).unwrap(), original);
    let _ = std::fs::remove_dir_all(&dir);
}
