//! Collections: the strict resolver parse, the link recognizer, and the
//! reuse-or-refuse rule — a collection never re-pins an existing
//! subscription as a side effect.

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
    let (_tmp, env, scope) = scoped("schema = 6\n");
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

#[test]
fn a_malformed_manifest_refuses_collection_planning() {
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
    let (_tmp, env, scope) = scoped(
        "schema = 6\n[sources.kit]\nrepo = \"acme/kit\"\nrev = \"ab12cd34ef12345678901234567890123456abcd\"\n",
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
    let (_tmp, env, scope) =
        scoped("schema = 6\n[sources.kit]\nrepo = \"acme/kit\"\nrev = \"1111111111\"\n");
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
    let (_tmp, env, scope) = scoped("schema = 6\n");
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
