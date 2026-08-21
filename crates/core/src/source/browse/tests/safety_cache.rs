//! The pre-install safety cache: written once per resolved commit, verified
//! before reuse, and never the verdict — thresholds judge at read time.

use std::fs;
use std::path::{Path, PathBuf};

use super::super::{Catalog, PackageSafety, package_safety};
use crate::env::{Env, FakeOs};
use crate::model::{ItemKind, Scope};
use crate::process::Hardened;
use crate::quality::Verdict;

pub(super) const REPO: &str = "owner/repo";

fn git(dir: &Path, args: &[&str]) {
    let output = Hardened::git(args, Some(dir)).run().unwrap();
    assert!(output.status.success(), "git {args:?}");
}

pub(super) fn commit(dir: &Path, message: &str) {
    git(dir, &["add", "-A"]);
    git(
        dir,
        &[
            "-c",
            "user.email=t@t",
            "-c",
            "user.name=t",
            "commit",
            "--quiet",
            "-m",
            message,
        ],
    );
}

/// An upstream repository whose one skill scores below 100 without any
/// Critical finding, subscribed as `cat` and already synced into the store.
pub(super) fn fixture() -> (tempfile::TempDir, Env, Scope) {
    let tmp = tempfile::tempdir().unwrap();
    let upstream = tmp.path().join("base/owner/repo");
    fs::create_dir_all(upstream.join("skills/gh")).unwrap();
    fs::write(
        upstream.join("skills/gh/SKILL.md"),
        "---\nname: gh\n---\nchmod 777 /tmp/x\n",
    )
    .unwrap();
    git(&upstream, &["init", "--quiet", "-b", "main"]);
    commit(&upstream, "one");
    let base = format!("file://{}", tmp.path().join("base").display());
    let env = Env::fake(tmp.path(), FakeOs::Linux).with_var("KENDEX_GIT_BASE", &base);
    let root = tmp.path().join("app");
    fs::create_dir_all(&root).unwrap();
    fs::write(
        root.join("kendex.toml"),
        format!("schema = 5\n[sources.cat]\nrepo = \"{REPO}\"\n"),
    )
    .unwrap();
    crate::remote::sync(&env, REPO, None).unwrap();
    (tmp, env, Scope::Project { root })
}

/// The one record the fixture's skill caches.
fn cache_file(env: &Env) -> PathBuf {
    let key = crate::remote::cache_key(env, REPO);
    let commit = crate::remote::cached(env, REPO, None)
        .unwrap()
        .expect("synced")
        .commit;
    crate::remote::store::safety_cache_dir(env, &key, &commit)
        .join("skill")
        .join(format!("gh-{}.json", crate::hash::fnv1a_hex(b"gh")))
}

fn score(env: &Env, scope: &Scope) -> PackageSafety {
    package_safety(
        env,
        &Catalog::Subscription {
            scope: scope.clone(),
            source: "cat".to_owned(),
        },
        ItemKind::Skill,
        "gh",
    )
    .unwrap()
}

/// The same, for the agent the project-contribution test browses.
fn agent_safety(env: &Env, scope: &Scope) -> PackageSafety {
    package_safety(
        env,
        &Catalog::Subscription {
            scope: scope.clone(),
            source: "cat".to_owned(),
        },
        ItemKind::Agent,
        "helper",
    )
    .unwrap()
}

#[test]
fn a_second_call_reads_the_verified_cache_and_a_moved_hash_rescores() {
    let (_tmp, env, scope) = fixture();
    let first = score(&env, &scope);
    assert!(!first.from_cache);
    assert!(first.safety.score < 100);
    let path = cache_file(&env);
    let written = fs::read_to_string(&path).unwrap();

    let second = score(&env, &scope);
    assert!(second.from_cache);
    assert_eq!(second.safety, first.safety);
    assert_eq!(fs::read_to_string(&path).unwrap(), written);

    // The record is what answers: an edited record with an intact key comes
    // back as written, which is only observable because nothing re-scored.
    let mut record: serde_json::Value = serde_json::from_str(&written).unwrap();
    record["safety"]["score"] = 7.into();
    fs::write(&path, record.to_string()).unwrap();
    let reread = score(&env, &scope);
    assert!(reread.from_cache);
    assert_eq!(reread.safety.score, 7);

    // A content hash that no longer names the bytes — a parser change that
    // moves bytes between items — is a miss: re-scored, and the record
    // healed on disk.
    record["contentHash"] = "not-these-bytes".into();
    fs::write(&path, record.to_string()).unwrap();
    let rescored = score(&env, &scope);
    assert!(!rescored.from_cache);
    assert_eq!(rescored.safety, first.safety);
    assert!(score(&env, &scope).from_cache);
}

/// A record from an older scanner is not trusted: a bump of the record
/// format, the rule set, or the discovery table each invalidates the cached
/// findings, so a scoring change never serves a stale verdict forever. Each
/// version field is checked on its own — dropping any one from the key would
/// leave that whole class of change unnoticed.
#[test]
fn a_version_bump_in_any_key_field_re_scores() {
    let (_tmp, env, scope) = fixture();
    let first = score(&env, &scope);
    assert!(!first.from_cache);
    let path = cache_file(&env);
    let written = fs::read_to_string(&path).unwrap();

    for field in ["format", "ruleset", "discovery"] {
        // Plant a stale version under an otherwise valid record.
        let mut record: serde_json::Value = serde_json::from_str(&written).unwrap();
        record[field] = 9999.into();
        fs::write(&path, record.to_string()).unwrap();

        let rescored = score(&env, &scope);
        assert!(
            !rescored.from_cache,
            "a stale `{field}` version must miss the cache"
        );
        assert_eq!(rescored.safety, first.safety, "and re-score to the same");
        // The healed record reads from cache again.
        assert!(score(&env, &scope).from_cache, "and heals `{field}`");
    }
}

#[test]
fn thresholds_move_the_verdict_without_touching_the_cache() {
    let (_tmp, env, scope) = fixture();
    let first = score(&env, &scope);
    assert_eq!(first.verdict, Verdict::Warn);
    let path = cache_file(&env);
    let written = fs::read_to_string(&path).unwrap();
    let modified = fs::metadata(&path).unwrap().modified().unwrap();

    let mut settings = crate::settings::load(&env).unwrap();
    settings.safety.block_below = first.safety.score + 1;
    crate::settings::save(&env, &settings).unwrap();

    let judged = score(&env, &scope);
    assert_eq!(judged.verdict, Verdict::Block);
    assert!(judged.from_cache);
    assert_eq!(judged.safety, first.safety);
    assert_eq!(fs::read_to_string(&path).unwrap(), written);
    assert_eq!(fs::metadata(&path).unwrap().modified().unwrap(), modified);
}

/// Browse is a preview of the same verdict, never a second gate: a finding
/// the publisher has already settled stops counting here exactly as it does
/// at the install gate, and is still shown with their name and reason.
///
/// The record is read at read time, beside the thresholds — a cache hit
/// still applies it, which is why the cache can hold findings and scores
/// alone.
#[test]
#[allow(clippy::unwrap_used, clippy::expect_used)]
fn a_settled_finding_stops_counting_in_the_preview_too() {
    let (tmp, env, scope) = fixture();
    let before = score(&env, &scope);
    assert_eq!(before.verdict, Verdict::Warn);
    assert!(before.findings.iter().all(|row| row.settled.is_none()));
    assert!(before.publisher.is_none());

    // The maintainer records their decision and publishes it.
    let upstream = tmp.path().join("base/owner/repo");
    let sealed = crate::source_read::SealedSource::open(&upstream).unwrap();
    let item = upstream.join("skills/gh");
    let hash = crate::quality::author::content_hash(&sealed, &item).unwrap();
    let fingerprint = before.findings[0].finding.fingerprint();
    crate::check_catalog::dismissals::record(
        &sealed,
        ItemKind::Skill,
        "gh",
        &hash,
        &[(
            fingerprint,
            crate::quality::reviews::DismissReason::Intended,
        )],
    )
    .unwrap();
    commit(&upstream, "reviewed");
    crate::remote::sync(&env, REPO, None).unwrap();

    let after = score(&env, &scope);
    assert_eq!(after.verdict, Verdict::Clean);
    assert_eq!(after.safety.score, 100);
    // Reported, not hidden, and it says whose judgement settled it.
    assert_eq!(
        after
            .findings
            .iter()
            .map(|row| &row.finding)
            .collect::<Vec<_>>(),
        before
            .findings
            .iter()
            .map(|row| &row.finding)
            .collect::<Vec<_>>()
    );
    let settled = after.findings[0]
        .settled
        .as_ref()
        .expect("the record settles it");
    assert_eq!(
        settled.reason,
        crate::quality::reviews::DismissReason::Intended
    );
    assert_eq!(after.publisher.as_deref(), Some(REPO));

    // And a cache hit says the same, because the record is applied here and
    // not baked into what was cached.
    let cached = score(&env, &scope);
    assert!(cached.from_cache);
    assert_eq!(cached.verdict, Verdict::Clean);
    assert!(cached.findings[0].settled.is_some());
}

/// A reviews file the catalog cannot parse settles nothing here either, and
/// the page says so: a preview that quietly showed a package held back over
/// findings its publisher reviewed would send a person after a problem
/// somebody already answered.
#[test]
#[allow(clippy::unwrap_used, clippy::expect_used)]
fn a_reviews_file_that_will_not_parse_is_named_on_the_page() {
    let (tmp, env, scope) = fixture();
    let upstream = tmp.path().join("base/owner/repo");
    fs::write(
        upstream.join("kendex-reviews.toml"),
        "this is not toml [[[\n",
    )
    .unwrap();
    commit(&upstream, "broken reviews");
    crate::remote::sync(&env, REPO, None).unwrap();

    let scored = score(&env, &scope);
    assert_eq!(scored.verdict, Verdict::Warn);
    assert!(
        scored
            .reasons
            .iter()
            .any(|reason| reason.contains("kendex-reviews.toml")
                && reason.contains("could not be read")),
        "{:?}",
        scored.reasons
    );
}

/// The preview reads catalog bytes, so anything this project adds to the
/// rendering is missing from the number it shows. It says so — for every
/// input the rendering counts as the project's, not only the ones that read
/// as prose.
#[test]
#[allow(clippy::unwrap_used)]
fn a_preview_says_what_this_projects_own_settings_add() {
    let (tmp, env, scope) = fixture();
    let upstream = tmp.path().join("base/owner/repo");
    fs::create_dir_all(upstream.join("agents")).unwrap();
    fs::write(
        upstream.join("agents/helper.md"),
        "---\nname: helper\ndescription: helps\nrole: engineer\n---\n\nBody.\n",
    )
    .unwrap();
    commit(&upstream, "an agent");
    crate::remote::sync(&env, REPO, None).unwrap();
    let quiet = agent_safety(&env, &scope);
    assert!(
        !quiet
            .reasons
            .iter()
            .any(|reason| reason.contains("adds its own instructions")),
        "{:?}",
        quiet.reasons
    );

    // Frontmatter alone, which is not an instruction table.
    let Scope::Project { root } = &scope else {
        unreachable!()
    };
    let manifest = root.join("kendex.toml");
    let text = fs::read_to_string(&manifest).unwrap()
        + "\n[agent-frontmatter.claude.helper]\nnickname-candidates = [\"Scout\"]\n";
    fs::write(&manifest, text).unwrap();

    let loud = agent_safety(&env, &scope);
    assert!(
        loud.reasons
            .iter()
            .any(|reason| reason.contains("adds its own instructions")),
        "{:?}",
        loud.reasons
    );
}
