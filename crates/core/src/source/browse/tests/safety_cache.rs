//! The pre-install safety cache: written once per resolved commit and
//! verified before reuse.

use std::fs;
use std::path::{Path, PathBuf};

use super::super::{Catalog, PackageSafety, package_safety};
use crate::env::{Env, FakeOs};
use crate::model::{ItemKind, Scope};
use crate::process::Hardened;

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
        format!("schema = 6\n[sources.cat]\nrepo = \"{REPO}\"\n"),
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
        None,
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
        None,
    )
    .unwrap()
}

#[test]
fn a_second_call_reads_the_verified_cache_and_a_moved_hash_rescores() {
    let (_tmp, env, scope) = fixture();
    let first = score(&env, &scope);
    assert!(!first.from_cache);
    assert!(first.advisory.safety.score < 100);
    let path = cache_file(&env);
    let written = fs::read_to_string(&path).unwrap();

    let second = score(&env, &scope);
    assert!(second.from_cache);
    assert_eq!(second.advisory.safety, first.advisory.safety);
    assert_eq!(fs::read_to_string(&path).unwrap(), written);

    // The record is what answers: an edited record with an intact key comes
    // back as written, which is only observable because nothing re-scored.
    let mut record: serde_json::Value = serde_json::from_str(&written).unwrap();
    record["safety"]["score"] = 7.into();
    fs::write(&path, record.to_string()).unwrap();
    let reread = score(&env, &scope);
    assert!(reread.from_cache);
    assert_eq!(reread.advisory.safety.score, 7);

    // A content hash that no longer names the bytes — a parser change that
    // moves bytes between items — is a miss: re-scored, and the record
    // healed on disk.
    record["contentHash"] = "not-these-bytes".into();
    fs::write(&path, record.to_string()).unwrap();
    let rescored = score(&env, &scope);
    assert!(!rescored.from_cache);
    assert_eq!(rescored.advisory.safety, first.advisory.safety);
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
        assert_eq!(
            rescored.advisory.safety, first.advisory.safety,
            "and re-score to the same"
        );
        // The healed record reads from cache again.
        assert!(score(&env, &scope).from_cache, "and heals `{field}`");
    }
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
            .notes
            .iter()
            .any(|note| note.contains("adds its own instructions")),
        "{:?}",
        quiet.notes
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
        loud.notes
            .iter()
            .any(|note| note.contains("adds its own instructions")),
        "{:?}",
        loud.notes
    );
}
