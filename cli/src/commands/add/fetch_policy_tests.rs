//! Which source revision `add` reads: the fetch policy is derived from what
//! the user NAMED, not from whether the run may prompt.

use super::*;
use crate::config::REMOTE_CACHE_TTL;
use std::path::Path;

pub(super) fn tmproot(label: &str) -> PathBuf {
    let nanos = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .expect("system clock before epoch")
        .as_nanos();
    std::env::temp_dir().join(format!(
        "vstack-fetch-policy-{label}-{}-{nanos}",
        std::process::id()
    ))
}

/// Test-side git, scrubbed exactly as production's is: a runner exporting
/// `GIT_DIR` or a `GIT_CONFIG_*` override would point the fixture at another
/// repository.
fn git(repo: &Path, args: &[&str]) {
    let output = crate::refresh_sources::hardened_git_command(repo)
        .args(args)
        .output()
        .expect("git is required to run this regression test");
    assert!(
        output.status.success(),
        "git {args:?}: {}",
        String::from_utf8_lossy(&output.stderr)
    );
}

/// A committed vstack source repository, and the `file://` URL naming it. Two
/// item roots, because that is what makes a directory a vstack source — and
/// the clone is refused otherwise, before any of this is reached.
pub(super) fn origin_repo(dir: &Path) -> String {
    std::fs::create_dir_all(dir.join("agents")).unwrap();
    std::fs::write(
        dir.join("agents").join("scout.md"),
        "---\nname: scout\ndescription: scout\nmodel: sonnet\nrole: analyst\n---\nbody\n",
    )
    .unwrap();
    publish_skill(dir, "alpha");
    git(dir, &["init", "-q", "-b", "main"]);
    git(dir, &["config", "user.email", "test@example.com"]);
    git(dir, &["config", "user.name", "Test"]);
    git(dir, &["config", "commit.gpgsign", "false"]);
    git(dir, &["add", "-A"]);
    git(dir, &["commit", "-q", "-m", "init"]);
    format!("file://{}", dir.display())
}

/// Move upstream on: one more skill, committed.
pub(super) fn publish_skill(dir: &Path, name: &str) {
    let skill = dir.join("skills").join(name);
    std::fs::create_dir_all(&skill).unwrap();
    std::fs::write(
        skill.join("SKILL.md"),
        format!("---\nname: {name}\ndescription: {name}\n---\nbody\n"),
    )
    .unwrap();
    if dir.join(".git").is_dir() {
        git(dir, &["add", "-A"]);
        git(dir, &["commit", "-q", "-m", name]);
    }
}

/// The skills the resolved source would install — the content, not whether a
/// fetch was attempted.
fn resolved_skills(
    source: &str,
    project_root: &Path,
    fetch: SourceFetch,
) -> anyhow::Result<Vec<String>> {
    let registry = config::SourceRegistry::default();
    let resolved = resolve_source_for_app(Some(source), &registry, project_root, fetch)?;
    let names = crate::catalog::discover_skills(&resolved.dir)?
        .into_iter()
        .map(|skill| skill.name)
        .collect();
    // The lease keeps the cache still for as long as this value lives, and a
    // caller holding one already is served without a fetch. Released here so
    // the next resolution in this test is a fresh decision, exactly as a
    // separate `vstack add` would be.
    drop(resolved);
    Ok(names)
}

/// An interactive `vstack add <source>` names the source it wants. Under the
/// derivation this replaces — the fetch policy read off the interactivity flag
/// — the six-hour TTL applied to it: a cache stamped minutes ago installed its
/// own revision even though upstream had moved, and the fresh stamp it left
/// read as current to `check` until the TTL expired.
#[test]
fn a_named_source_installs_the_current_upstream_revision_interactively() {
    let root = tmproot("named-source");
    let origin = root.join("origin");
    let home = root.join("home");
    let config_dir = root.join("config");
    let project_root = root.join("project");
    for dir in [&origin, &home, &config_dir, &project_root] {
        std::fs::create_dir_all(dir).unwrap();
    }
    let source = origin_repo(&origin);

    crate::test_util::with_home_and_config(&home, &config_dir, || {
        // The interactive `vstack add <source>` policy, derived the way `run`
        // derives it — the fixture must exercise the derivation, not restate
        // its answer.
        let named_interactive = SourceFetch::for_invocation(Some(source.as_str()), true);

        // First run clones the cache and stamps it fetched-now.
        let first = resolved_skills(&source, &project_root, named_interactive).unwrap();
        assert_eq!(first, vec!["alpha".to_string()]);

        // Upstream moves while that stamp is still fresh.
        publish_skill(&origin, "beta");
        let after_upstream_moved =
            resolved_skills(&source, &project_root, named_interactive).unwrap();
        assert_eq!(
            after_upstream_moved,
            vec!["alpha".to_string(), "beta".to_string()],
            "a source named on the command line is fetched, not served from a fresh cache"
        );

        // Control: `-y` names the same source and is fetched the same way.
        publish_skill(&origin, "gamma");
        let non_interactive = SourceFetch::for_invocation(Some(source.as_str()), false);
        assert_eq!(
            resolved_skills(&source, &project_root, non_interactive).unwrap(),
            vec!["alpha".to_string(), "beta".to_string(), "gamma".to_string()]
        );

        // Control: an unchanged upstream is a no-op fetch that installs the
        // same content.
        assert_eq!(
            resolved_skills(&source, &project_root, named_interactive).unwrap(),
            vec!["alpha".to_string(), "beta".to_string(), "gamma".to_string()]
        );
    });

    let _ = std::fs::remove_dir_all(root);
}

/// Control: the wizard's own source browsing keeps the TTL and the bound. It
/// repaints a menu, so an unroutable remote must not hang it, and `check`
/// reports the staleness that leaves behind.
#[test]
fn a_source_the_wizard_looked_up_is_served_from_a_fresh_cache() {
    let root = tmproot("wizard-lookup");
    let origin = root.join("origin");
    let home = root.join("home");
    let config_dir = root.join("config");
    let project_root = root.join("project");
    for dir in [&origin, &home, &config_dir, &project_root] {
        std::fs::create_dir_all(dir).unwrap();
    }
    let source = origin_repo(&origin);

    crate::test_util::with_home_and_config(&home, &config_dir, || {
        // Nothing named on the command line: the catalog the wizard opens on.
        let lookup = SourceFetch::for_invocation(None, true);
        assert_eq!(lookup, SourceFetch::CachedWhileFresh);
        assert_eq!(
            resolved_skills(&source, &project_root, lookup).unwrap(),
            vec!["alpha".to_string()]
        );

        publish_skill(&origin, "beta");
        assert_eq!(
            resolved_skills(&source, &project_root, lookup).unwrap(),
            vec!["alpha".to_string()],
            "a cache inside its TTL paints the menu; check reports the staleness"
        );

        // Control: the same cache, resolved for a source the user named, is
        // fetched — the cache is not what made the difference.
        assert_eq!(
            resolved_skills(&source, &project_root, SourceFetch::Now).unwrap(),
            vec!["alpha".to_string(), "beta".to_string()]
        );
    });

    let _ = std::fs::remove_dir_all(root);
}

/// The policy each intent carries, at the one place it is chosen.
#[test]
fn each_intent_states_its_own_ttl_and_bound() {
    assert_eq!(
        SourceFetch::Now.policy(),
        (None, crate::config::FetchBound::Unbounded)
    );
    assert_eq!(
        SourceFetch::CachedWhileFresh.policy(),
        (
            Some(REMOTE_CACHE_TTL),
            crate::config::FetchBound::INTERACTIVE
        )
    );
    // A named source is fetched however the run was started; only a lookup
    // nobody typed, with a menu waiting on it, is served from the cache.
    assert_eq!(
        SourceFetch::for_invocation(Some("owner/repo"), true),
        SourceFetch::Now
    );
    assert_eq!(
        SourceFetch::for_invocation(Some("owner/repo"), false),
        SourceFetch::Now
    );
    // A run with no source named still fetches when nothing is waiting on a
    // menu: a scripted `vstack add -y` installs what upstream has now.
    assert_eq!(SourceFetch::for_invocation(None, false), SourceFetch::Now);
    assert_eq!(
        SourceFetch::for_invocation(None, true),
        SourceFetch::CachedWhileFresh
    );
}
