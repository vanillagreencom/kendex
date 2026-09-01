//! The community directory client: strict parse with caps, the
//! ETag/TTL/offline ladder, and the skills.sh adapter.

#[path = "../../test_util.rs"]
mod test_util;
use test_util::rooted;

use kendex_core::env::{Env, FakeOs};
use kendex_core::error::CoreError;
use kendex_core::registry::{Fetch, FetchResponse, cache, index, skillssh};
use std::cell::RefCell;
use std::path::Path;

/// A canned transport: each call pops the next scripted answer and the
/// test can count how often the network was asked at all.
struct Canned {
    answers: RefCell<Vec<kendex_core::error::Result<FetchResponse>>>,
    calls: RefCell<u32>,
    saw_etag: RefCell<Option<String>>,
    saw_body: RefCell<Option<String>>,
}

impl Canned {
    fn new(answers: Vec<kendex_core::error::Result<FetchResponse>>) -> Canned {
        Canned {
            answers: RefCell::new(answers),
            calls: RefCell::new(0),
            saw_etag: RefCell::new(None),
            saw_body: RefCell::new(None),
        }
    }
}

impl Fetch for Canned {
    fn post_json_auth(
        &self,
        url: &str,
        body: &str,
        _bearer: Option<&str>,
    ) -> kendex_core::error::Result<FetchResponse> {
        *self.saw_body.borrow_mut() = Some(body.to_owned());
        self.get(url, None)
    }

    fn get_auth(
        &self,
        _url: &str,
        if_none_match: Option<&str>,
        _bearer: Option<&str>,
    ) -> kendex_core::error::Result<FetchResponse> {
        *self.calls.borrow_mut() += 1;
        *self.saw_etag.borrow_mut() = if_none_match.map(str::to_string);
        if self.answers.borrow().is_empty() {
            panic!("the test scripted fewer answers than the code asked for");
        }
        self.answers.borrow_mut().remove(0)
    }
}

fn ok(status: u16, etag: Option<&str>, body: &str) -> kendex_core::error::Result<FetchResponse> {
    Ok(FetchResponse {
        status,
        etag: etag.map(str::to_string),
        body: body.as_bytes().to_vec(),
    })
}

fn body_with(marketplaces: &str) -> String {
    format!(
        r#"{{"schema":1,"generated_at":"2026-08-19T00:00:00Z","marketplaces":[{marketplaces}]}}"#
    )
}

fn env_in(dir: &Path) -> Env {
    Env::fake(dir, FakeOs::Linux)
}

#[test]
fn a_malformed_manifest_fails_the_directory_subscription_join() {
    let dir = tempfile::tempdir().unwrap();
    let root = rooted(&dir);
    let env = env_in(&root);
    let manifest = env.global_manifest_file();
    std::fs::create_dir_all(manifest.parent().unwrap()).unwrap();
    std::fs::write(&manifest, "schema = [broken\n").unwrap();
    let fetch = Canned::new(vec![ok(
        200,
        None,
        &body_with(r#"{"repo":"owner/repo","name":"repo"}"#),
    )]);

    assert!(matches!(
        kendex_core::registry::view::directory(&env, &fetch, true),
        Err(CoreError::TomlParse { .. })
    ));
}

#[test]
fn parse_caps_and_drops_unusable_rows() {
    let many_tags: Vec<String> = (0..20).map(|n| format!(r#""t{n}""#)).collect();
    let body = body_with(&format!(
        r#"{{"repo":"good/repo","name":"{}","tags":[{}],"status":"featured",
            "head_commit":"abc123","counts":{{"packages":9,"bundles":1}},
            "packages":[{{"kind":"skill","name":"a","safety":{{"score":150.0}}}}],
            "bundles":[{{"name":"b","members":[1,2,3]}}]}},
           {{"repo":"../evil","name":"x"}},
           {{"repo":"no-slash","name":"y"}}"#,
        "n".repeat(300),
        many_tags.join(",")
    ));
    let parsed = index::parse(body.as_bytes()).expect("parses");
    assert_eq!(parsed.marketplaces.len(), 1, "unusable repos are dropped");
    let market = &parsed.marketplaces[0];
    assert_eq!(market.name.as_deref().map(str::len), Some(120));
    assert_eq!(market.tags.len(), 12);
    assert!(market.featured);
    assert_eq!(market.package_count, 9);
    assert_eq!(market.packages[0].safety_score, Some(100));
    assert_eq!(market.bundles[0].member_count, 3);
}

#[test]
fn parse_refuses_malformed_and_unknown_schema() {
    assert!(matches!(
        index::parse(b"not json"),
        Err(CoreError::RegistryMalformed { .. })
    ));
    assert!(matches!(
        index::parse(br#"{"schema":2,"marketplaces":[]}"#),
        Err(CoreError::RegistryMalformed { .. })
    ));
}

#[test]
fn fresh_cache_is_served_without_the_network() {
    let dir = tempfile::tempdir().expect("tempdir");
    let env = env_in(dir.path());
    let first = Canned::new(vec![ok(
        200,
        Some("\"v1\""),
        &body_with(r#"{"repo":"a/b","name":"b"}"#),
    )]);
    let loaded = cache::load(&env, &first, false).expect("first load");
    assert!(!loaded.stale);
    assert_eq!(loaded.index.marketplaces.len(), 1);
    assert_eq!(*first.calls.borrow(), 1);

    let second = Canned::new(vec![]);
    let again = cache::load(&env, &second, false).expect("cached load");
    assert_eq!(
        *second.calls.borrow(),
        0,
        "within the TTL nothing is fetched"
    );
    assert!(!again.stale);
}

#[test]
fn refresh_revalidates_with_the_etag_and_304_keeps_the_body() {
    let dir = tempfile::tempdir().expect("tempdir");
    let env = env_in(dir.path());
    let first = Canned::new(vec![ok(
        200,
        Some("\"v1\""),
        &body_with(r#"{"repo":"a/b","name":"b"}"#),
    )]);
    cache::load(&env, &first, false).expect("first load");

    let revalidate = Canned::new(vec![ok(304, None, "")]);
    let again = cache::load(&env, &revalidate, true).expect("revalidated");
    assert_eq!(revalidate.saw_etag.borrow().as_deref(), Some("\"v1\""));
    assert!(!again.stale);
    assert_eq!(again.index.marketplaces.len(), 1);
}

#[test]
fn network_failure_serves_the_last_fetch_as_stale() {
    let dir = tempfile::tempdir().expect("tempdir");
    let env = env_in(dir.path());
    let first = Canned::new(vec![ok(
        200,
        None,
        &body_with(r#"{"repo":"a/b","name":"b"}"#),
    )]);
    let loaded = cache::load(&env, &first, false).expect("first load");
    let fetched_at = loaded.fetched_at;

    let down = Canned::new(vec![Err(CoreError::RegistryUnavailable {
        why: "no route".into(),
    })]);
    let offline = cache::load(&env, &down, true).expect("stale copy");
    assert!(offline.stale);
    assert_eq!(
        offline.fetched_at, fetched_at,
        "the 'as of' is the real fetch time"
    );
}

#[test]
fn no_cache_and_no_network_is_an_error() {
    let dir = tempfile::tempdir().expect("tempdir");
    let env = env_in(dir.path());
    let down = Canned::new(vec![Err(CoreError::RegistryUnavailable {
        why: "no route".into(),
    })]);
    assert!(cache::load(&env, &down, false).is_err());
}

#[test]
fn malformed_refresh_keeps_the_stale_copy() {
    let dir = tempfile::tempdir().expect("tempdir");
    let env = env_in(dir.path());
    let first = Canned::new(vec![ok(
        200,
        None,
        &body_with(r#"{"repo":"a/b","name":"b"}"#),
    )]);
    cache::load(&env, &first, false).expect("first load");

    let garbled = Canned::new(vec![ok(200, None, "<!doctype html>")]);
    let kept = cache::load(&env, &garbled, true).expect("stale survives");
    assert!(kept.stale);
    assert_eq!(kept.index.marketplaces.len(), 1);
}

#[test]
fn skillssh_parses_the_pinned_shape_and_drops_bad_rows() {
    let canned = Canned::new(vec![ok(
        200,
        None,
        r#"{"query":"react","skills":[
            {"id":"o/r/x","skillId":"x","name":"react-best","installs":642000,"source":"vercel-labs/agent-skills"},
            {"id":"bad","name":"noslash","installs":1,"source":"norepo"},
            {"id":"o/r/y","name":"quiet","source":"o/r"}
        ],"count":3}"#,
    )]);
    let hits = skillssh::search(&canned, "react").expect("search");
    assert_eq!(hits.len(), 2);
    assert_eq!(hits[0].repo, "vercel-labs/agent-skills");
    assert_eq!(hits[0].installs, 642_000);
    assert_eq!(
        hits[1].installs, 0,
        "missing installs read as zero, not dropped"
    );
}

#[test]
fn skillssh_refuses_a_shape_it_does_not_know() {
    let canned = Canned::new(vec![ok(200, None, r#"{"results":[]}"#)]);
    assert!(matches!(
        skillssh::search(&canned, "react"),
        Err(CoreError::RegistryMalformed { .. })
    ));
}

#[test]
fn skillssh_empty_query_asks_nothing() {
    let canned = Canned::new(vec![]);
    let hits = skillssh::search(&canned, "   ").expect("empty");
    assert!(hits.is_empty());
    assert_eq!(*canned.calls.borrow(), 0);
}

#[test]
fn skillssh_refuses_names_its_install_url_cannot_carry() {
    let canned = Canned::new(vec![ok(
        200,
        None,
        r#"{"skills":[
            {"id":"o/r/a","name":"good-skill","installs":5,"source":"o/r"},
            {"id":"o/r/b","name":"foo/bar","installs":5,"source":"o/r"},
            {"id":"o/r/c","name":"has space","installs":5,"source":"o/r"},
            {"id":"o/r/d","name":"..","installs":5,"source":"o/r"},
            {"id":"o/r/e","name":"ok","installs":5,"source":"o/r/extra"}
        ]}"#,
    )]);
    let hits = skillssh::search(&canned, "x").expect("search");
    assert_eq!(hits.len(), 1, "only the URL-safe hit survives");
    assert_eq!(hits[0].skill, "good-skill");
}

#[test]
fn etag_and_body_are_one_generation_on_disk() {
    let dir = tempfile::tempdir().expect("tempdir");
    let env = env_in(dir.path());
    let first = Canned::new(vec![ok(
        200,
        Some("\"v1\""),
        &body_with(r#"{"repo":"a/b","name":"b"}"#),
    )]);
    cache::load(&env, &first, false).expect("first load");
    let raw = std::fs::read_to_string(env.registry_cache_dir().join("index.cache.json"))
        .expect("cache file");
    assert!(
        raw.contains("v1") && raw.contains("a/b"),
        "one file holds both"
    );
}

#[test]
fn leaderboard_parses_the_proxy_shape_and_absence_hides_it() {
    let canned = Canned::new(vec![ok(
        200,
        None,
        r#"{"data":[{"id":"o/r/x","slug":"x","name":"find-skills","source":"vercel-labs/skills","installs":24531}],"pagination":{"page":0}}"#,
    )]);
    let view = skillssh::LeaderboardView::parse("trending").expect("view");
    let hits = skillssh::leaderboard(&canned, view).expect("leaderboard");
    assert_eq!(hits.len(), 1);
    assert_eq!(hits[0].skill, "find-skills");

    let absent = Canned::new(vec![ok(404, None, "")]);
    assert!(matches!(
        skillssh::leaderboard(&absent, view),
        Err(CoreError::RegistryUnavailable { .. })
    ));
    assert!(skillssh::LeaderboardView::parse("evil").is_none());
}

#[test]
fn login_start_and_poll_speak_the_device_protocol() {
    let canned = Canned::new(vec![ok(
        200,
        None,
        r#"{"device_code":"kxd_x","user_code":"AAAA-BBBB","verification_url":"https://kendex.ai/device","interval":5,"expires_in":900}"#,
    )]);
    let started = kendex_core::registry::login::start(&canned, "kendex CLI").expect("start");
    assert_eq!(started.user_code, "AAAA-BBBB");
    assert_eq!(started.interval_seconds, 5);
    let asked = canned.saw_body.borrow().clone().expect("a body was sent");
    assert!(
        asked.contains(r#""client":"kendex CLI""#),
        "the request names the asking surface: {asked}"
    );

    use kendex_core::registry::login::{Poll, poll_once};
    let pending = Canned::new(vec![ok(400, None, r#"{"error":"authorization_pending"}"#)]);
    assert!(matches!(poll_once(&pending, "kxd_x"), Ok(Poll::Pending)));
    let slow = Canned::new(vec![ok(400, None, r#"{"error":"slow_down"}"#)]);
    assert!(matches!(poll_once(&slow, "kxd_x"), Ok(Poll::SlowDown)));
    let denied = Canned::new(vec![ok(400, None, r#"{"error":"denied"}"#)]);
    assert!(poll_once(&denied, "kxd_x").is_err());
    let signed = Canned::new(vec![ok(
        200,
        None,
        r#"{"access_token":"kxa_a","refresh_token":"kxr_r","capabilities":["submission:write"]}"#,
    )]);
    match poll_once(&signed, "kxd_x").expect("signed") {
        Poll::Signed(pair) => assert_eq!(pair.access_token, "kxa_a"),
        other => panic!("expected tokens, got {other:?}"),
    }
}
