//! The pre-install safety cache: written once per resolved commit, verified
//! before reuse, and never the verdict — thresholds judge at read time.

use std::fs;
use std::path::{Path, PathBuf};

use super::super::{Catalog, PackageSafety, package_safety};
use crate::env::{Env, FakeOs};
use crate::model::{ItemKind, Scope};
use crate::process::Hardened;
use crate::quality::Verdict;

const REPO: &str = "owner/repo";

fn git(dir: &Path, args: &[&str]) {
    let output = Hardened::git(args, Some(dir)).run().unwrap();
    assert!(output.status.success(), "git {args:?}");
}

fn commit(dir: &Path, message: &str) {
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
fn fixture() -> (tempfile::TempDir, Env, Scope) {
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
