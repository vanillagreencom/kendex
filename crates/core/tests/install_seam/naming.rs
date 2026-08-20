//! The five naming-a-catalog cases: a bare name searches every
//! subscription, a `marketplace::name` spelling says exactly which, and
//! `/` keeps meaning `plugin/item` or `owner/repo` — never a qualifier.

use std::fs;
use std::path::{Path, PathBuf};
use std::process::Command;

use kendex_core::engine::ops;
use kendex_core::env::{Env, FakeOs};
use kendex_core::error::CoreError;
use kendex_core::remote;

use super::{add_and_apply, agent, manifest_of, manifest_with, skill, world};

/// Case 1: one subscription offers the name — it installs from there, no
/// prompt, no default, no download.
#[test]
fn a_bare_name_one_subscription_offers_installs_from_it() {
    let f = world();
    let a = f.home.join("a");
    skill(&a, "docs");
    let b = f.home.join("b");
    skill(&b, "gh");
    manifest_with(&f, &[("a", &a), ("b", &b)], "");

    add_and_apply(
        &f,
        &ops::AddRequest {
            skills: vec!["gh".into()],
            ..ops::AddRequest::default()
        },
    );
    assert_eq!(manifest_of(&f).skills["gh"].source, "b");
    assert!(f.project.join(".claude/skills/gh").exists());
}

/// A hostile or broken subscription must not sink the bare-name search:
/// a repo with two disagreeing control-file generations cannot be read, but
/// installing `gh` from a healthy sibling still works. Without the skip, the
/// unreadable catalog's error propagated and blocked every marketplace.
#[test]
fn a_broken_subscription_does_not_block_bare_name_installs_from_others() {
    let f = world();
    let good = f.home.join("good");
    skill(&good, "gh");
    let bad = f.home.join("bad");
    skill(&bad, "other");
    fs::write(bad.join("kendex.toml"), "is_source_catalog = true\n").unwrap();
    fs::write(bad.join("vstack.toml"), "is_source_catalog = false\n").unwrap();
    manifest_with(&f, &[("good", &good), ("bad", &bad)], "");

    add_and_apply(
        &f,
        &ops::AddRequest {
            skills: vec!["gh".into()],
            ..ops::AddRequest::default()
        },
    );
    assert_eq!(manifest_of(&f).skills["gh"].source, "good");

    // A name that only the broken source could answer for names it, rather
    // than reporting a plain "not offered" that hides the real problem.
    let err = ops::add(
        &f.env,
        &f.scope,
        &ops::AddRequest {
            skills: vec!["other".into()],
            ..ops::AddRequest::default()
        },
    )
    .unwrap_err();
    assert!(
        matches!(&err, CoreError::SearchSourcesUnreadable { sources, .. } if sources == &["bad"]),
        "{err:?}"
    );
}

#[allow(clippy::unwrap_used)]
fn git(dir: &Path, args: &[&str]) {
    // The caller's git environment is dropped: run from a commit hook,
    // GIT_DIR and friends point at the repository being committed to and
    // every command here would act on that one instead of this fixture.
    let output = Command::new("git")
        .args(["-c", "user.email=t@t", "-c", "user.name=t"])
        .args(args)
        .current_dir(dir)
        .env_remove("GIT_DIR")
        .env_remove("GIT_WORK_TREE")
        .env_remove("GIT_INDEX_FILE")
        .env_remove("GIT_OBJECT_DIRECTORY")
        .env_remove("GIT_PREFIX")
        .output()
        .unwrap();
    assert!(
        output.status.success(),
        "git {args:?} failed: {}",
        String::from_utf8_lossy(&output.stderr)
    );
}

/// A git upstream under `<home>/base/<owner>/<repo>` holding one `gh`
/// skill, reachable through `KENDEX_GIT_BASE`.
#[allow(clippy::unwrap_used)]
fn upstream(home: &Path, repo: &str) -> PathBuf {
    let dir = home.join("base").join(repo);
    fs::create_dir_all(dir.join("skills/gh")).unwrap();
    fs::write(
        dir.join("skills/gh/SKILL.md"),
        "---\nname: gh\ndescription: github things\n---\nBody.\n",
    )
    .unwrap();
    git(&dir, &["init", "--quiet", "-b", "main"]);
    git(&dir, &["add", "-A"]);
    git(&dir, &["commit", "--quiet", "-m", "one"]);
    dir
}

/// Case 2: two subscriptions offer the name. The refusal prints the `::`
/// spelling for each — the syntax for next time — and each subscription's
/// canonical `owner/repo`, because an alias is a local label. An
/// agent-only subscription never appears in a skill refusal.
#[test]
#[allow(clippy::unwrap_used)]
fn a_bare_name_offered_twice_refuses_printing_qualified_forms_and_repos() {
    let f = world();
    let base = format!("file://{}", f.home.join("base").display());
    let env = Env::fake(&f.home, FakeOs::Linux).with_var("KENDEX_GIT_BASE", &base);
    upstream(&f.home, "owner1/tools");
    upstream(&f.home, "owner2/kit");
    remote::sync(&env, "owner1/tools", None).unwrap();
    remote::sync(&env, "owner2/kit", None).unwrap();
    let c = f.home.join("c");
    agent(&c, "gh");
    super::write(
        &f.project,
        "kendex.toml",
        &format!(
            "schema = 5\n\n[sources.a]\nrepo = \"owner1/tools\"\n\n[sources.b]\nrepo = \"owner2/kit\"\n\n[sources.c]\npath = \"{}\"\n\n[install]\nharnesses = [\"claude\"]\nmethod = \"symlink\"\n",
            c.display()
        ),
    );

    let error = ops::add(
        &env,
        &f.scope,
        &ops::AddRequest {
            skills: vec!["gh".into()],
            ..ops::AddRequest::default()
        },
    )
    .unwrap_err();

    let said = error.to_string();
    assert!(
        matches!(error, CoreError::ItemAmbiguous { .. }),
        "expected the ambiguity refusal, got {said}"
    );
    assert!(said.contains("a::gh") && said.contains("b::gh"), "{said}");
    assert!(
        said.contains("owner1/tools") && said.contains("owner2/kit"),
        "{said}"
    );
    assert!(
        !said.contains("c::gh") && !said.contains("agent"),
        "an agent by the same name is not this refusal's business: {said}"
    );
}

/// The kind flag is the kind: a skill and an agent sharing a bare name in
/// different subscriptions are each unique within their own kind, so
/// neither add asks a question.
#[test]
fn a_cross_kind_name_needs_no_qualifier_because_the_flag_says_the_kind() {
    let f = world();
    let a = f.home.join("a");
    skill(&a, "gh");
    let c = f.home.join("c");
    agent(&c, "gh");
    manifest_with(&f, &[("a", &a), ("c", &c)], "");

    add_and_apply(
        &f,
        &ops::AddRequest {
            skills: vec!["gh".into()],
            agents: vec!["gh".into()],
            no_auto_skills: true,
            ..ops::AddRequest::default()
        },
    );
    let manifest = manifest_of(&f);
    assert_eq!(manifest.skills["gh"].source, "a");
    assert_eq!(manifest.agents["gh"].source, "c");
}

/// Case 3: a qualified name installs from exactly that subscription, even
/// when others offer the same name.
#[test]
fn a_qualified_name_installs_from_exactly_that_subscription() {
    let f = world();
    let a = f.home.join("a");
    skill(&a, "gh");
    let b = f.home.join("b");
    skill(&b, "gh");
    manifest_with(&f, &[("a", &a), ("b", &b)], "");

    add_and_apply(
        &f,
        &ops::AddRequest {
            skills: vec!["b::gh".into()],
            ..ops::AddRequest::default()
        },
    );
    assert_eq!(manifest_of(&f).skills["gh"].source, "b");
}

/// Case 4: a qualifier naming no subscription refuses, naming what is
/// subscribed — it never declares a repository and never guesses.
#[test]
#[allow(clippy::unwrap_used)]
fn a_qualifier_naming_no_subscription_refuses_naming_the_subscribed() {
    let f = world();
    let a = f.home.join("a");
    skill(&a, "gh");
    manifest_with(&f, &[("a", &a)], "");
    let before = fs::read_to_string(f.project.join("kendex.toml")).unwrap();

    let error = ops::add(
        &f.env,
        &f.scope,
        &ops::AddRequest {
            skills: vec!["nope::gh".into()],
            ..ops::AddRequest::default()
        },
    )
    .unwrap_err();

    let said = error.to_string();
    assert!(
        matches!(error, CoreError::UnknownMarketplace { ref name, .. } if name == "nope"),
        "{said}"
    );
    assert!(
        said.contains("a (") && said.contains(&a.display().to_string()),
        "{said}"
    );
    assert_eq!(
        fs::read_to_string(f.project.join("kendex.toml")).unwrap(),
        before,
        "a refusal writes nothing"
    );
}

/// Case 5, one way round: a `/` name is an item — `team/github` finds the
/// plugin-registry item of that name even while a subscription is also
/// called `team`; the `::` spelling is the only qualifier.
#[test]
fn a_slash_name_is_a_plugin_item_never_a_qualifier() {
    let f = world();
    let team = f.home.join("team");
    skill(&team, "docs");
    let market = f.home.join("market");
    super::write(
        &market,
        ".claude-plugin/marketplace.json",
        r#"{"name": "market", "owner": {"name": "o"},
            "plugins": [{"name": "team", "source": "./plugins/team"}]}"#,
    );
    super::write(
        &market,
        "plugins/team/skills/github/SKILL.md",
        "---\nname: github\ndescription: github things\n---\nBody.\n",
    );
    manifest_with(&f, &[("team", &team), ("market", &market)], "");

    add_and_apply(
        &f,
        &ops::AddRequest {
            skills: vec!["team/github".into()],
            ..ops::AddRequest::default()
        },
    );
    assert_eq!(manifest_of(&f).skills["team/github"].source, "market");
}

/// Case 5, the other way round: a positional `owner/repo` source still
/// declares a repository, exactly as before qualifiers existed.
#[test]
#[allow(clippy::unwrap_used)]
fn a_positional_owner_repo_source_still_declares_a_repository() {
    let f = world();
    let a = f.home.join("a");
    skill(&a, "gh");
    manifest_with(&f, &[("a", &a)], "");

    let error = ops::add(
        &f.env,
        &f.scope,
        &ops::AddRequest {
            source: Some("acme/tools".to_owned()),
            skills: vec!["x".into()],
            ..ops::AddRequest::default()
        },
    )
    .unwrap_err();
    assert!(
        matches!(error, CoreError::SourcePending { ref name } if name == "tools"),
        "an owner/repo source is a repository to fetch, got {error}"
    );
}

/// Zero matches is NOT FOUND, never a fallback: nothing offers the name,
/// nothing installs, nothing downloads, and the fix is named.
#[test]
#[allow(clippy::unwrap_used)]
fn an_unoffered_bare_name_is_not_found_and_nothing_is_declared() {
    let f = world();
    let a = f.home.join("a");
    skill(&a, "gh");
    let b = f.home.join("b");
    skill(&b, "docs");
    manifest_with(&f, &[("a", &a), ("b", &b)], "");
    let before = fs::read_to_string(f.project.join("kendex.toml")).unwrap();

    let error = ops::add(
        &f.env,
        &f.scope,
        &ops::AddRequest {
            skills: vec!["ghost".into()],
            ..ops::AddRequest::default()
        },
    )
    .unwrap_err();

    let said = error.to_string();
    assert!(
        matches!(
            error,
            CoreError::ItemNotOffered { kind: kendex_core::model::ItemKind::Skill, ref name } if name == "ghost"
        ),
        "{said}"
    );
    assert!(said.contains("subscribe"), "the fix is named: {said}");
    assert_eq!(
        fs::read_to_string(f.project.join("kendex.toml")).unwrap(),
        before,
        "no declaration was written"
    );
}
