//! Collections: the strict resolver parse, the link recognizer, and the
//! reuse-or-refuse rule — a collection never re-pins an existing
//! subscription as a side effect.

use crate::test_util;
use test_util::rooted;

use std::cell::RefCell;
use std::fs;

use kendex_core::env::{Env, FakeOs};
use kendex_core::model::{ItemKind, Scope};
use kendex_core::registry::collections::{Collection, CollectionMember, resolve};
use kendex_core::registry::{Fetch, FetchResponse};
use kendex_core::source_ops::{SourceAction, collection_steps};
use kendex_core::source_ref::{SourceRef, parse_typed};

struct Canned(RefCell<Vec<(u16, String)>>);

impl Fetch for Canned {
    fn get_auth(
        &self,
        _url: &str,
        _etag: Option<&str>,
        _bearer: Option<&str>,
    ) -> kendex_core::error::Result<FetchResponse> {
        let (status, body) = self.0.borrow_mut().remove(0);
        Ok(FetchResponse {
            status,
            etag: None,
            body: body.into_bytes(),
        })
    }
    fn post_json_auth(
        &self,
        _url: &str,
        _body: &str,
        _bearer: Option<&str>,
    ) -> kendex_core::error::Result<FetchResponse> {
        unreachable!("resolving never posts")
    }
}

fn canned(status: u16, body: &str) -> Canned {
    Canned(RefCell::new(vec![(status, body.to_owned())]))
}

#[test]
#[allow(clippy::unwrap_used)]
fn a_collection_link_parses_and_junk_refuses() {
    crate::diagnostic::parent!(a_collection_link_parses_and_junk_refuses);
    let parsed = parse_typed("https://kendex.ai/c/aB3-_dEf12345678").unwrap();
    assert_eq!(
        parsed,
        SourceRef::Collection {
            id: "aB3-_dEf12345678".to_owned()
        }
    );
    assert!(parse_typed("https://kendex.ai/c/short").is_err());
    assert!(parse_typed("https://kendex.ai/m/owner/repo").is_err());
    assert!(parse_typed("https://kendex.ai/c/../../../etc/passwd").is_err());
}

#[test]
#[allow(clippy::unwrap_used)]
fn the_resolver_parses_strictly_and_refuses_junk() {
    crate::diagnostic::parent!(the_resolver_parses_strictly_and_refuses_junk);
    let good = canned(
        200,
        r#"{"schema":1,"id":"aB3-_dEf12345678","name":"starter","description":null,
            "members":[{"repo":"acme/kit","kind":"skill","name":"gh","commit":"AB12CD34EF12345678901234567890123456ABCD"},
                       {"repo":"acme/kit","kind":"agent","name":"scout","commit":"ab12cd34ef12345678901234567890123456abcd"}]}"#,
    );
    let collection = resolve(&good, "aB3-_dEf12345678").unwrap();
    assert_eq!(collection.name, "starter");
    assert_eq!(collection.members.len(), 2);
    assert_eq!(collection.members[0].kind, ItemKind::Skill);
    assert_eq!(
        collection.members[0].commit.as_deref(),
        Some("ab12cd34ef12345678901234567890123456abcd")
    );

    let gone = canned(404, r#"{"error":"no such collection"}"#);
    let why = resolve(&gone, "x").unwrap_err().to_string();
    assert!(why.contains("no longer resolves"), "{why}");

    let bad_kind = canned(
        200,
        r#"{"schema":1,"id":"i","name":"n","members":[{"repo":"a/b","kind":"virus","name":"x","commit":null}]}"#,
    );
    assert!(resolve(&bad_kind, "i").is_err());

    let bad_commit = canned(
        200,
        r#"{"schema":1,"id":"i","name":"n","members":[{"repo":"a/b","kind":"skill","name":"x","commit":"main"}]}"#,
    );
    assert!(resolve(&bad_commit, "i").is_err());

    // An abbreviation is not a snapshot; neither is a missing commit.
    let short_commit = canned(
        200,
        r#"{"schema":1,"id":"i","name":"n","members":[{"repo":"a/b","kind":"skill","name":"x","commit":"ab12cd34ef"}]}"#,
    );
    assert!(resolve(&short_commit, "i").is_err());
    let no_commit = canned(
        200,
        r#"{"schema":1,"id":"i","name":"n","members":[{"repo":"a/b","kind":"skill","name":"x","commit":null}]}"#,
    );
    assert!(resolve(&no_commit, "i").is_err());

    let empty = canned(200, r#"{"schema":1,"id":"i","name":"n","members":[]}"#);
    assert!(resolve(&empty, "i").is_err());
}

fn member(repo: &str, name: &str, commit: Option<&str>) -> CollectionMember {
    CollectionMember {
        repo: repo.to_owned(),
        kind: ItemKind::Skill,
        name: name.to_owned(),
        commit: commit.map(str::to_owned),
    }
}

#[allow(clippy::unwrap_used)]
fn scoped(manifest: &str) -> (tempfile::TempDir, Env, Scope) {
    let tmp = tempfile::tempdir().unwrap();
    let env = Env::fake(tmp.path(), FakeOs::Linux);
    let project = tmp.path().join("app");
    fs::create_dir_all(&project).unwrap();
    fs::write(project.join("kendex.toml"), manifest).unwrap();
    (tmp, env, Scope::Project { root: project })
}

#[test]
#[allow(clippy::unwrap_used)]
fn a_fresh_scope_subscribes_each_repo_at_the_snapshot() {
    crate::diagnostic::parent!(a_fresh_scope_subscribes_each_repo_at_the_snapshot);
    let (_tmp, env, scope) = scoped("schema = 7\n");
    let collection = Collection {
        id: "i".to_owned(),
        name: "starter".to_owned(),
        members: vec![
            member(
                "acme/kit",
                "gh",
                Some("ab12cd34ef12345678901234567890123456abcd"),
            ),
            member(
                "acme/kit",
                "review",
                Some("ab12cd34ef12345678901234567890123456abcd"),
            ),
            member("other/tools", "deploy", None),
        ],
    };
    let steps = collection_steps(&env, &scope, &collection).unwrap();
    assert_eq!(steps.len(), 2);
    let kit = steps.iter().find(|step| step.repo == "acme/kit").unwrap();
    assert_eq!(
        kit.action,
        SourceAction::Subscribe {
            reference: "acme/kit@ab12cd34ef12345678901234567890123456abcd".to_owned()
        }
    );
    assert_eq!(kit.skills, ["gh", "review"]);
    let tools = steps
        .iter()
        .find(|step| step.repo == "other/tools")
        .unwrap();
    assert_eq!(
        tools.action,
        SourceAction::Subscribe {
            reference: "other/tools".to_owned()
        }
    );
}

/// A scope that has no manifest yet is read as its first write would
/// create it, so a member of the default marketplace reuses the seeded
/// subscription: planning a fresh Subscribe there would print a step the
/// install then refuses as a duplicate. Read the absent file as empty
/// and this case is what goes red.
#[test]
#[allow(clippy::unwrap_used)]
fn a_fresh_personal_scope_reuses_the_seeded_default_marketplace() {
    crate::diagnostic::parent!(a_fresh_personal_scope_reuses_the_seeded_default_marketplace);
    let tmp = tempfile::tempdir().unwrap();
    let home = rooted(&tmp);
    let env = Env::fake(home, FakeOs::Linux);
    let collection = Collection {
        id: "i".to_owned(),
        name: "starter".to_owned(),
        members: vec![member(
            kendex_core::manifest::DEFAULT_SOURCE_REPO,
            "gh",
            None,
        )],
    };
    let steps = collection_steps(&env, &Scope::Global, &collection).unwrap();
    assert_eq!(
        steps[0].action,
        SourceAction::Reuse {
            name: kendex_core::manifest::DEFAULT_SOURCE_NAME.to_owned()
        }
    );
}

#[test]
fn a_malformed_manifest_refuses_collection_planning() {
    crate::diagnostic::parent!(a_malformed_manifest_refuses_collection_planning);
    let (_tmp, env, scope) = scoped("schema = [broken\n");
    let collection = Collection {
        id: "i".to_owned(),
        name: "starter".to_owned(),
        members: vec![member("acme/kit", "gh", None)],
    };

    assert!(matches!(
        collection_steps(&env, &scope, &collection),
        Err(kendex_core::error::CoreError::TomlParse { .. })
    ));
}

#[test]
#[allow(clippy::unwrap_used)]
fn an_existing_subscription_is_reused_when_its_pin_matches() {
    crate::diagnostic::parent!(an_existing_subscription_is_reused_when_its_pin_matches);
    let (_tmp, env, scope) = scoped(
        "schema = 7\n[sources.kit]\nrepo = \"acme/kit\"\nrev = \"ab12cd34ef12345678901234567890123456abcd\"\n",
    );
    let collection = Collection {
        id: "i".to_owned(),
        name: "starter".to_owned(),
        members: vec![member(
            "acme/kit",
            "gh",
            Some("ab12cd34ef12345678901234567890123456abcd"),
        )],
    };
    let steps = collection_steps(&env, &scope, &collection).unwrap();
    assert_eq!(
        steps[0].action,
        SourceAction::Reuse {
            name: "kit".to_owned()
        }
    );
}

#[test]
#[allow(clippy::unwrap_used)]
fn a_mismatched_pin_refuses_naming_both_halves() {
    crate::diagnostic::parent!(a_mismatched_pin_refuses_naming_both_halves);
    let (_tmp, env, scope) =
        scoped("schema = 7\n[sources.kit]\nrepo = \"acme/kit\"\nrev = \"1111111111\"\n");
    let collection = Collection {
        id: "i".to_owned(),
        name: "starter".to_owned(),
        members: vec![member(
            "acme/kit",
            "gh",
            Some("ab12cd34ef12345678901234567890123456abcd"),
        )],
    };
    // The declared rev disagrees and nothing is fetched: kendex cannot
    // verify, so it refuses rather than re-pinning or guessing.
    let refused = collection_steps(&env, &scope, &collection)
        .unwrap_err()
        .to_string();
    assert!(refused.contains("kit"), "{refused}");
    assert!(
        refused.contains("cannot verify") || refused.contains("never re-pins"),
        "{refused}"
    );
}

#[test]
#[allow(clippy::unwrap_used)]
fn one_repo_pinned_at_two_commits_is_not_a_snapshot() {
    crate::diagnostic::parent!(one_repo_pinned_at_two_commits_is_not_a_snapshot);
    let (_tmp, env, scope) = scoped("schema = 7\n");
    let collection = Collection {
        id: "i".to_owned(),
        name: "starter".to_owned(),
        members: vec![
            member(
                "acme/kit",
                "gh",
                Some("ab12cd34ef12345678901234567890123456abcd"),
            ),
            member(
                "acme/kit",
                "review",
                Some("ffff000011112222333344445555666677778888"),
            ),
        ],
    };
    let refused = collection_steps(&env, &scope, &collection)
        .unwrap_err()
        .to_string();
    assert!(refused.contains("two different commits"), "{refused}");
}

#[test]
#[allow(clippy::unwrap_used)]
fn a_member_repo_cannot_be_a_filesystem_path() {
    crate::diagnostic::parent!(a_member_repo_cannot_be_a_filesystem_path);
    for repo in ["../.ssh", "..", "./x", "/etc", ".hidden/repo"] {
        let body = format!(
            r#"{{"schema":1,"id":"aB3-_dEf12345678","name":"n","members":[{{"repo":"{repo}","kind":"skill","name":"x","commit":"ab12cd34ef12345678901234567890123456abcd"}}]}}"#
        );
        let fetch = canned(200, &body);
        assert!(
            resolve(&fetch, "aB3-_dEf12345678").is_err(),
            "member repo '{repo}' must be refused"
        );
    }
}

#[allow(clippy::unwrap_used)]
fn replacement_catalog(catalog: &std::path::Path, names: &[&str]) {
    for name in names {
        fs::create_dir_all(catalog.join(format!("skills/{name}"))).unwrap();
        fs::write(
            catalog.join(format!("skills/{name}/SKILL.md")),
            format!("---\nname: {name}\ndescription: fixture\n---\nBody.\n"),
        )
        .unwrap();
    }
    fs::write(catalog.join("kendex.toml"), "min_kendex = '0.0.0'\n").unwrap();
    test_util::git(catalog, &["init", "-q", "-b", "main"]);
    test_util::git(catalog, &["add", "-A"]);
    test_util::git(catalog, &["commit", "-q", "-m", "compatible"]);
}

/// A released CLI could record a catalog minimum it ignored. The real
/// installation record supplies every field except that historical commit.
#[test]
#[allow(clippy::unwrap_used)]
fn collection_replacements_and_retained_readings_are_checked_before_installation() {
    crate::diagnostic::parent!(
        collection_replacements_and_retained_readings_are_checked_before_installation
    );
    use kendex_core::{apply, engine, error::CoreError, lock, source_ops};

    for (reverse, retained) in [(false, false), (true, false), (false, true), (true, true)] {
        let tmp = tempfile::tempdir().unwrap();
        let home = rooted(&tmp);
        let env = Env::fake(&home, FakeOs::Linux);
        let project = home.join("consumer");
        fs::create_dir_all(project.join(".claude")).unwrap();
        let first = home.join("a");
        let last = home.join("z");
        replacement_catalog(&first, &["fresh"]);
        replacement_catalog(&last, &["held", "retained"]);
        fs::write(last.join("kendex.toml"), "min_kendex = '999999.0.0'\n").unwrap();
        test_util::git(&last, &["add", "-A"]);
        test_util::git(&last, &["commit", "-q", "-m", "historical minimum"]);
        let historical = test_util::git(&last, &["rev-parse", "HEAD"])
            .trim()
            .to_owned();
        fs::write(last.join("kendex.toml"), "min_kendex = '0.0.0'\n").unwrap();
        test_util::git(&last, &["add", "-A"]);
        test_util::git(&last, &["commit", "-q", "-m", "compatible replacement"]);
        let first_commit = test_util::git(&first, &["rev-parse", "HEAD"])
            .trim()
            .to_owned();
        let last_commit = test_util::git(&last, &["rev-parse", "HEAD"])
            .trim()
            .to_owned();
        let first_repo = format!("file://{}", first.display());
        let last_repo = format!("file://{}", last.display());
        fs::write(project.join("kendex.toml"), format!(
            "schema = 7\n[sources.first]\nrepo = '{first_repo}'\nrev = 'main'\n[sources.last]\nrepo = '{last_repo}'\nrev = 'main'\n[install]\nharnesses = ['claude']\nmethod = 'copy'\n[skills.held]\nsource = 'last'\n{}",
            if retained { "[skills.retained]\nsource = 'last'\n" } else { "" })).unwrap();
        let scope = Scope::Project {
            root: project.clone(),
        };
        kendex_core::remote::sync(&env, &first_repo, None).unwrap();
        kendex_core::remote::sync(&env, &last_repo, None).unwrap();
        let installed = engine::plan_apply(&env, &scope, &engine::PlanOptions::current()).unwrap();
        apply::execute(&env, &installed.plan).unwrap();
        kendex_core::remote::sync(&env, &last_repo, Some(&historical)).unwrap();
        let path = lock::lock_path(&env, &scope);
        let mut record = lock::load(&path).unwrap();
        for entry in record.entries.values_mut() {
            entry.source_commit = Some(historical.clone());
        }
        lock::save(&path, &record).unwrap();
        let collection = Collection {
            id: "i".to_owned(),
            name: "replacement".to_owned(),
            members: vec![
                member(&first_repo, "fresh", Some(&first_commit)),
                member(&last_repo, "held", Some(&last_commit)),
            ],
        };
        let mut steps = collection_steps(&env, &scope, &collection).unwrap();
        if reverse {
            steps.reverse();
        }
        let before_manifest = fs::read(project.join("kendex.toml")).unwrap();
        let before_record = fs::read(&path).unwrap();
        let outcome = source_ops::prepare_collection(&env, &scope, &steps)
            .and_then(|prepared| prepared.plan(&env))
            .and_then(|report| {
                apply::execute(&env, &report.plan)?;
                Ok(report)
            });
        if retained {
            assert!(matches!(outcome, Err(CoreError::CatalogNeedsEngine { .. })));
            assert_eq!(
                fs::read(project.join("kendex.toml")).unwrap(),
                before_manifest
            );
            assert_eq!(fs::read(&path).unwrap(), before_record);
            assert!(!project.join(".claude/skills/fresh").exists());
        } else {
            outcome.unwrap();
            let after = lock::load(&path).unwrap();
            for (name, commit) in [("fresh", &first_commit), ("held", &last_commit)] {
                assert!(
                    project
                        .join(format!(".claude/skills/{name}/SKILL.md"))
                        .is_file()
                );
                assert_eq!(
                    after
                        .entries
                        .values()
                        .find(|entry| entry.name == name)
                        .unwrap()
                        .source_commit
                        .as_ref(),
                    Some(commit)
                );
            }
        }
    }
}

struct AgentCollectionFixture {
    _tmp: tempfile::TempDir,
    env: Env,
    scope: Scope,
    repo: String,
    first: String,
    snapshot: String,
}

#[allow(clippy::unwrap_used)]
fn agent_collection_fixture(held: bool) -> AgentCollectionFixture {
    use kendex_core::{apply, engine, remote};
    let tmp = tempfile::tempdir().unwrap();
    let home = rooted(&tmp);
    let env = Env::fake(&home, FakeOs::Linux);
    let catalog = home.join("catalog");
    replacement_catalog(&catalog, &["automatic", "fresh"]);
    let first = test_util::git(&catalog, &["rev-parse", "HEAD"])
        .trim()
        .to_owned();
    fs::create_dir_all(catalog.join("agents")).unwrap();
    fs::write(
        catalog.join("agents/rust.md"),
        "---\nname: rust\ndescription: fixture\nrole: engineer\n---\nBody.\n",
    )
    .unwrap();
    fs::write(
        catalog.join("kendex.toml"),
        "min_kendex = '0.0.0'\n[role-skills]\nengineer = ['automatic', 'fresh']\n",
    )
    .unwrap();
    test_util::git(&catalog, &["add", "-A"]);
    test_util::git(&catalog, &["commit", "-q", "-m", "agent snapshot"]);
    let snapshot = test_util::git(&catalog, &["rev-parse", "HEAD"])
        .trim()
        .to_owned();
    let repo = format!("file://{}", catalog.display());
    let project = home.join("consumer");
    fs::create_dir_all(project.join(".claude")).unwrap();
    let pin = if held {
        format!("rev = '{first}'\n")
    } else {
        String::new()
    };
    fs::write(project.join("kendex.toml"), format!(
        "schema = 7\n[sources.cat]\nrepo = '{repo}'\n[install]\nharnesses = ['claude']\nmethod = 'copy'\n[skills.automatic]\nsource = 'cat'\n{pin}")).unwrap();
    let scope = Scope::Project { root: project };
    remote::sync(&env, &repo, Some(&first)).unwrap();
    remote::sync(&env, &repo, None).unwrap();
    let installed = engine::plan_apply(&env, &scope, &engine::PlanOptions::current()).unwrap();
    apply::execute(&env, &installed.plan).unwrap();
    AgentCollectionFixture {
        _tmp: tmp,
        env,
        scope,
        repo,
        first,
        snapshot,
    }
}

#[allow(clippy::unwrap_used)]
fn assert_agent_collection_holds(
    fixture: &AgentCollectionFixture,
    automatic_rev: Option<&str>,
    fresh_rev: Option<&str>,
) {
    use kendex_core::{lock, manifest};
    let after = manifest::load_current(&manifest::manifest_path(&fixture.env, &fixture.scope))
        .unwrap()
        .unwrap();
    assert_eq!(
        after.agents["rust"].rev.as_deref(),
        Some(fixture.snapshot.as_str())
    );
    assert_eq!(after.skills["automatic"].rev.as_deref(), automatic_rev);
    assert_eq!(after.skills["fresh"].rev.as_deref(), fresh_rev);
    let record = lock::load(&lock::lock_path(&fixture.env, &fixture.scope)).unwrap();
    for (kind, name, commit) in [
        (ItemKind::Agent, "rust", fixture.snapshot.as_str()),
        (
            ItemKind::Skill,
            "automatic",
            automatic_rev.unwrap_or(fixture.snapshot.as_str()),
        ),
        (ItemKind::Skill, "fresh", fixture.snapshot.as_str()),
    ] {
        assert_eq!(
            record
                .entries
                .values()
                .find(|entry| entry.kind == kind && entry.name == name)
                .unwrap()
                .source_commit
                .as_deref(),
            Some(commit)
        );
    }
}

/// A collection names an agent but expands its role skills automatically.
/// Only named members gain snapshot holds. A direct add --hold freezes its
/// automatic expansion too, including a skill already held elsewhere.
#[test]
#[allow(clippy::unwrap_used)]
fn collection_member_holds_preserve_automatic_skill_revision_choices() {
    crate::diagnostic::parent!(collection_member_holds_preserve_automatic_skill_revision_choices);
    use kendex_core::{apply, engine, source_ops};

    for (direct_hold, held, explicit_skill) in [
        (false, false, false),
        (false, true, false),
        (false, true, true),
        (true, false, false),
        (true, true, false),
    ] {
        let fixture = agent_collection_fixture(held);
        let AgentCollectionFixture {
            env,
            scope,
            repo,
            first,
            snapshot,
            ..
        } = &fixture;

        let report = if direct_hold {
            engine::ops::add(
                env,
                scope,
                &engine::ops::AddRequest {
                    source: Some("cat".to_owned()),
                    agents: vec!["rust".to_owned()],
                    hold: true,
                    ..Default::default()
                },
            )
            .unwrap()
        } else {
            let mut members = vec![CollectionMember {
                repo: repo.clone(),
                kind: ItemKind::Agent,
                name: "rust".to_owned(),
                commit: Some(snapshot.clone()),
            }];
            if explicit_skill {
                members.push(member(repo, "automatic", Some(snapshot)));
            }
            let collection = Collection {
                id: "i".to_owned(),
                name: "agent".to_owned(),
                members,
            };
            let steps = collection_steps(env, scope, &collection).unwrap();
            source_ops::prepare_collection(env, scope, &steps)
                .unwrap()
                .plan(env)
                .unwrap()
        };
        apply::execute(env, &report.plan).unwrap();
        let automatic_rev = if direct_hold || explicit_skill {
            Some(snapshot.as_str())
        } else if held {
            Some(first.as_str())
        } else {
            None
        };
        assert_agent_collection_holds(
            &fixture,
            automatic_rev,
            direct_hold.then_some(snapshot.as_str()),
        );
    }
}
