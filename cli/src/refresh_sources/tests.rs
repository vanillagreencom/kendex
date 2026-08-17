use super::records::tests::{lock_entry, make_vstack_source};
use super::*;
use std::time::{SystemTime, UNIX_EPOCH};

/// A throwaway directory for one test, shared with the records tests next
/// door — both halves build their fixtures under the same root name.
pub(super) fn tmpdir(label: &str) -> PathBuf {
    let nanos = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .expect("system clock before epoch")
        .as_nanos();
    std::env::temp_dir().join(format!(
        "vstack-refresh-source-{label}-{}-{nanos}",
        std::process::id()
    ))
}

// -----------------------------------------------------------------------
// Remote cache git hardening
// -----------------------------------------------------------------------

/// Test-side git: unhardened with respect to the ownership checks under
/// test, but never redirected by an inherited location override.
fn git(repo: &Path, args: &[&str]) {
    let mut command = std::process::Command::new("git");
    for key in GIT_INHERITED_ENV_VARS.iter().chain(GIT_CACHE_ONLY_ENV_VARS) {
        command.env_remove(key);
    }
    let output = command.args(args).current_dir(repo).output().unwrap();
    assert!(
        output.status.success(),
        "git {args:?} failed: {}",
        String::from_utf8_lossy(&output.stderr)
    );
}

fn git_stdout(repo: &Path, args: &[&str]) -> String {
    let mut command = std::process::Command::new("git");
    for key in GIT_INHERITED_ENV_VARS.iter().chain(GIT_CACHE_ONLY_ENV_VARS) {
        command.env_remove(key);
    }
    let output = command.args(args).current_dir(repo).output().unwrap();
    assert!(output.status.success(), "git {args:?} failed");
    String::from_utf8_lossy(&output.stdout).trim().to_string()
}

/// A committed repository at `dir` with `README.md` tracked.
fn init_git_repo(dir: &Path) {
    std::fs::create_dir_all(dir).unwrap();
    git(dir, &["init", "-q", "-b", "main"]);
    git(dir, &["config", "user.email", "test@example.com"]);
    git(dir, &["config", "user.name", "Test"]);
    git(dir, &["config", "commit.gpgsign", "false"]);
    std::fs::write(dir.join("README.md"), "upstream\n").unwrap();
    git(dir, &["add", "README.md"]);
    git(dir, &["commit", "-q", "-m", "init"]);
}

fn file_url(path: &Path) -> String {
    format!("file://{}", path.display())
}

/// A remote whose clone lives at `cache` and whose origin is `origin`.
fn remote_at(cache: &Path, origin: &Path) -> RemoteSource {
    RemoteSource {
        display: "owner/repo".to_string(),
        git_url: file_url(origin),
        cache_key: cache.file_name().unwrap().to_string_lossy().into_owned(),
        cache_dir: cache.to_path_buf(),
    }
}

/// Clone `origin` into `cache` the way vstack would have.
fn clone_into(origin: &Path, cache: &Path) {
    std::fs::create_dir_all(cache.parent().unwrap()).unwrap();
    git(
        cache.parent().unwrap(),
        &["clone", "-q", &file_url(origin), cache.to_str().unwrap()],
    );
}

/// The reproduced escape's fixture: a real cache directory owning a real
/// `.git` — so every filesystem check passes — cloned from `origin`, whose
/// own `core.worktree` names the victim directory. The victim holds a file
/// the upstream repo also tracks, with different contents.
struct RedirectedCache {
    root: PathBuf,
    remote: RemoteSource,
    victim: PathBuf,
}

fn redirected_cache_at(root: &Path, cache: &Path) -> RedirectedCache {
    let origin = root.join("origin");
    init_git_repo(&origin);
    let victim = root.join("victim");
    std::fs::create_dir_all(&victim).unwrap();
    std::fs::write(victim.join("README.md"), "precious\n").unwrap();
    clone_into(&origin, cache);
    git(
        cache,
        &["config", "core.worktree", victim.to_str().unwrap()],
    );
    RedirectedCache {
        root: root.to_path_buf(),
        remote: remote_at(cache, &origin),
        victim,
    }
}

fn redirected_cache(label: &str) -> RedirectedCache {
    let root = tmpdir(label);
    let cache = root.join("cache").join("owner_repo");
    redirected_cache_at(&root, &cache)
}

fn victim_readme(fx: &RedirectedCache) -> String {
    std::fs::read_to_string(fx.victim.join("README.md")).unwrap()
}

/// Control for the fixture: the unhardened update main used to run really
/// does overwrite the victim's file. Without this, the refusal tests below
/// would pass against a fixture that never reproduced the escape.
#[test]
fn control_unhardened_reset_in_a_worktree_redirected_cache_clobbers_the_victim() {
    let fx = redirected_cache("control-clobber");
    git(&fx.remote.cache_dir, &["reset", "--hard", "origin/HEAD"]);
    assert_eq!(
        victim_readme(&fx),
        "upstream\n",
        "the fixture must reproduce the escape for the refusal tests to mean anything"
    );
    let _ = std::fs::remove_dir_all(fx.root);
}

#[test]
fn update_cached_repo_refuses_a_cache_whose_worktree_points_outside_it() {
    let fx = redirected_cache("refuse-redirected-worktree");

    let err = update_cached_repo(&fx.remote).unwrap_err().to_string();
    assert!(err.contains("refusing cached source owner/repo"), "{err}");
    assert!(err.contains("does not resolve to its cache entry"), "{err}");
    assert!(err.contains("Remove its cache entry `owner_repo`"), "{err}");
    assert!(
        !err.contains(&fx.victim.display().to_string()),
        "the victim path may not be printed: {err}"
    );
    assert_eq!(victim_readme(&fx), "precious\n");
    let _ = std::fs::remove_dir_all(fx.root);
}

/// A cache entry whose `.git` is a real DIRECTORY — so every filesystem
/// check and `--show-toplevel` pass — that redirects git's COMMON metadata
/// at another repository, the shape a moved worktree administrative
/// directory has. Refs and objects a fetch writes land in the victim.
struct RedirectedCommonDir {
    root: PathBuf,
    remote: RemoteSource,
    victim: PathBuf,
    upstream_head: String,
}

fn commondir_redirected_cache(label: &str) -> RedirectedCommonDir {
    let root = tmpdir(label);
    let origin = root.join("origin");
    init_git_repo(&origin);
    let victim = root.join("victim");
    clone_into(&origin, &victim);
    // One commit the victim has not seen, so a fetch has something to move.
    std::fs::write(origin.join("README.md"), "newer\n").unwrap();
    git(&origin, &["commit", "-q", "-am", "update"]);
    let upstream_head = rev_parse(&origin, "HEAD");

    let cache = root.join("cache").join("owner_repo");
    std::fs::create_dir_all(cache.parent().unwrap()).unwrap();
    git(
        &victim,
        &["worktree", "add", "-q", "--detach", cache.to_str().unwrap()],
    );
    // Move the worktree's administrative directory into the entry: `.git`
    // becomes a real directory holding a `commondir` file, which no
    // filesystem check and no work-tree check distinguishes from a clone's.
    let admin = victim.join(".git").join("worktrees").join("owner_repo");
    let staged = root.join("admin");
    std::fs::rename(&admin, &staged).unwrap();
    std::fs::remove_file(cache.join(".git")).unwrap();
    std::fs::rename(&staged, cache.join(".git")).unwrap();
    std::fs::write(
        cache.join(".git").join("commondir"),
        format!("{}\n", victim.join(".git").display()),
    )
    .unwrap();

    RedirectedCommonDir {
        remote: remote_at(&cache, &origin),
        root,
        victim,
        upstream_head,
    }
}

/// Scrubbed exactly as the `git` fixture helper is: a runner exporting
/// `GIT_DIR` or a `GIT_CONFIG_*` override would otherwise point this read at
/// another repository, and the guard would be judged on the wrong answer.
fn rev_parse(repo: &Path, rev: &str) -> String {
    let mut command = std::process::Command::new("git");
    for key in GIT_INHERITED_ENV_VARS.iter().chain(GIT_CACHE_ONLY_ENV_VARS) {
        command.env_remove(key);
    }
    let output = command
        .args(["rev-parse", rev])
        .current_dir(repo)
        .output()
        .unwrap();
    assert!(output.status.success(), "git rev-parse {rev} failed");
    git_stdout_line(&output.stdout)
}

/// Control for the fixture: an unhardened fetch in this cache really does
/// advance the VICTIM's remote-tracking refs. Without it the refusal below
/// would pass against a fixture that never reproduced the escape.
#[test]
fn control_unhardened_fetch_in_a_commondir_redirected_cache_writes_to_the_victim() {
    let fx = commondir_redirected_cache("control-commondir");
    assert_ne!(rev_parse(&fx.victim, "origin/main"), fx.upstream_head);

    git(&fx.remote.cache_dir, &["fetch", "origin", "--quiet"]);

    assert_eq!(
        rev_parse(&fx.victim, "origin/main"),
        fx.upstream_head,
        "the fixture must reproduce the escape for the refusal test to mean anything"
    );
    let _ = std::fs::remove_dir_all(fx.root);
}

#[test]
fn update_cached_repo_refuses_a_cache_whose_common_git_dir_points_outside_it() {
    let fx = commondir_redirected_cache("refuse-commondir");
    let before = rev_parse(&fx.victim, "origin/main");

    let err = update_cached_repo(&fx.remote).unwrap_err().to_string();

    assert!(err.contains("refusing cached source owner/repo"), "{err}");
    assert!(
        err.contains("its git metadata resolves outside its cache entry"),
        "{err}"
    );
    assert!(err.contains("Remove its cache entry `owner_repo`"), "{err}");
    assert!(
        !err.contains(&fx.victim.display().to_string()),
        "the victim path may not be printed: {err}"
    );
    assert_eq!(
        rev_parse(&fx.victim, "origin/main"),
        before,
        "the victim's refs were advanced by the refused update"
    );
    let _ = std::fs::remove_dir_all(fx.root);
}

/// A cache entry whose config names a program git runs on its own behalf. The
/// entry is a real clone with a matching work tree, common dir and origin, so
/// every ownership check above it passes.
struct ExecutableCacheConfig {
    root: PathBuf,
    remote: RemoteSource,
    marker: PathBuf,
}

fn cache_with_executable_config(label: &str, key: &str) -> ExecutableCacheConfig {
    let root = tmpdir(label);
    let origin = root.join("origin");
    init_git_repo(&origin);
    let cache = root.join("cache").join("owner_repo");
    clone_into(&origin, &cache);
    // A commit the clone has not seen, so the fetch has work to do and the
    // reset has a revision to move to.
    std::fs::write(origin.join("README.md"), "newer\n").unwrap();
    git(&origin, &["commit", "-q", "-am", "update"]);

    let marker = root.join("executed.marker");
    let program = root.join("planted.sh");
    std::fs::write(
        &program,
        format!(
            "#!/usr/bin/env bash\ntouch {}\nexit 1\n",
            marker.to_str().unwrap()
        ),
    )
    .unwrap();
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        std::fs::set_permissions(&program, std::fs::Permissions::from_mode(0o755)).unwrap();
    }
    git(&cache, &["config", key, program.to_str().unwrap()]);

    ExecutableCacheConfig {
        remote: remote_at(&cache, &origin),
        root,
        marker,
    }
}

/// Control for the fixture: an unhardened fetch+reset in this cache really does
/// run the planted program. Without it the refusal below would pass against a
/// fixture that never reproduced the execution.
#[cfg(unix)]
#[test]
fn control_unhardened_reset_runs_a_cache_locals_fsmonitor() {
    let fx = cache_with_executable_config("control-fsmonitor", "core.fsmonitor");

    git(&fx.remote.cache_dir, &["fetch", "origin", "--quiet"]);
    let _ = std::process::Command::new("git")
        .args(["reset", "--hard", "origin/HEAD"])
        .current_dir(&fx.remote.cache_dir)
        .output()
        .unwrap();

    assert!(
        fx.marker.exists(),
        "the fixture must reproduce the execution for the refusal test to mean anything"
    );
    let _ = std::fs::remove_dir_all(fx.root);
}

/// The ownership checks answer where a cache entry IS; this one answers what it
/// will DO. A repository's own config names programs git runs while fetching
/// and resetting, so an entry that passes every location check could still
/// execute one.
#[cfg(unix)]
#[test]
fn update_cached_repo_refuses_a_cache_config_that_names_a_program() {
    for key in ["core.fsmonitor", "core.hooksPath", "filter.planted.smudge"] {
        let fx = cache_with_executable_config("refuse-executable-config", key);

        let err = update_cached_repo(&fx.remote).unwrap_err().to_string();

        assert!(err.contains("refusing cached source owner/repo"), "{err}");
        assert!(
            err.contains("which `git clone` does not write"),
            "{key}: {err}"
        );
        // Git lowercases the section and key name in its own listing.
        assert!(
            err.to_ascii_lowercase().contains(&key.to_ascii_lowercase()),
            "{key}: {err}"
        );
        assert!(err.contains("Remove its cache entry `owner_repo`"), "{err}");
        assert!(
            !fx.marker.exists(),
            "{key}: the planted program ran despite the refusal"
        );
        let _ = std::fs::remove_dir_all(fx.root);
    }
}

/// `.git/config` is the one file vstack writes, and git follows a symlink
/// there like any other: every check answers for the repository at the far end,
/// and then `remote set-url` edits ITS origin.
#[cfg(unix)]
#[test]
fn update_cached_repo_refuses_a_cache_whose_config_is_a_symlink() {
    let root = tmpdir("symlinked-config");
    let origin = root.join("origin");
    init_git_repo(&origin);
    let victim = root.join("victim");
    clone_into(&origin, &victim);
    let cache = root.join("cache").join("owner_repo");
    clone_into(&origin, &cache);

    let victim_config = victim.join(".git").join("config");
    let before = std::fs::read_to_string(&victim_config).unwrap();
    std::fs::remove_file(cache.join(".git").join("config")).unwrap();
    std::os::unix::fs::symlink(&victim_config, cache.join(".git").join("config")).unwrap();

    let remote = RemoteSource {
        git_url: format!("{}/", file_url(&origin)),
        ..remote_at(&cache, &origin)
    };
    let err = update_cached_repo(&remote).unwrap_err().to_string();

    assert!(err.contains("refusing cached source owner/repo"), "{err}");
    assert!(err.contains("redirects config elsewhere"), "{err}");
    assert_eq!(
        std::fs::read_to_string(&victim_config).unwrap(),
        before,
        "the victim's configuration was rewritten by the refused update"
    );
    // The read-only path refuses it too — reading the entry would read the
    // victim's repository.
    assert!(matches!(
        source_path_resolution(&format!("file://{}", origin.display())),
        SourceResolution::Absent | SourceResolution::Refused(_)
    ));

    // A hard link is the same file with no link to follow, so no path check
    // sees it — only the link count does.
    std::fs::remove_file(cache.join(".git").join("config")).unwrap();
    std::fs::hard_link(&victim_config, cache.join(".git").join("config")).unwrap();
    let err = update_cached_repo(&remote).unwrap_err().to_string();
    assert!(err.contains("shares config with another file"), "{err}");
    assert_eq!(
        std::fs::read_to_string(&victim_config).unwrap(),
        before,
        "the victim's configuration was rewritten through a hard link"
    );
    let _ = std::fs::remove_dir_all(root);
}

/// A hard link anywhere in the writable metadata is the same file under two
/// names: a fetch appending to the entry's reflog appends to the victim's.
#[cfg(unix)]
#[test]
fn update_cached_repo_refuses_a_hard_linked_metadata_descendant() {
    let root = tmpdir("hard-linked-metadata");
    let origin = root.join("origin");
    init_git_repo(&origin);
    let victim = root.join("victim");
    clone_into(&origin, &victim);
    let cache = root.join("cache").join("owner_repo");
    clone_into(&origin, &cache);
    std::fs::write(origin.join("README.md"), "newer\n").unwrap();
    git(&origin, &["commit", "-q", "-am", "update"]);

    let reflog = ["logs", "refs", "remotes", "origin", "HEAD"]
        .iter()
        .fold(std::path::PathBuf::from(".git"), |acc, part| acc.join(part));
    let victim_reflog = victim.join(&reflog);
    let before = std::fs::read_to_string(&victim_reflog).unwrap();
    let entry_reflog = cache.join(&reflog);
    std::fs::remove_file(&entry_reflog).unwrap();
    std::fs::hard_link(&victim_reflog, &entry_reflog).unwrap();

    let err = update_cached_repo(&remote_at(&cache, &origin))
        .unwrap_err()
        .to_string();

    assert!(err.contains("with another file"), "{err}");
    assert!(
        !err.contains(&victim.display().to_string()),
        "the victim path may not be printed: {err}"
    );
    assert_eq!(
        std::fs::read_to_string(&victim_reflog).unwrap(),
        before,
        "the victim's reflog was appended to by the refused update"
    );
    let _ = std::fs::remove_dir_all(root);
}

/// `--git-common-dir` answers for the `.git` ROOT only, so a redirect one level
/// down passes every check above it: a fetch writing refs through a symlinked
/// `.git/refs` advances the victim repository's remote-tracking branches.
#[cfg(unix)]
#[test]
fn update_cached_repo_refuses_a_redirected_metadata_descendant() {
    for redirected in ["refs", "logs", "objects"] {
        let root = tmpdir("redirected-metadata");
        let origin = root.join("origin");
        init_git_repo(&origin);
        let victim = root.join("victim");
        clone_into(&origin, &victim);
        let cache = root.join("cache").join("owner_repo");
        clone_into(&origin, &cache);
        std::fs::write(origin.join("README.md"), "newer\n").unwrap();
        git(&origin, &["commit", "-q", "-am", "update"]);

        let victim_dir = victim.join(".git").join(redirected);
        std::fs::create_dir_all(&victim_dir).unwrap();
        let entry_dir = cache.join(".git").join(redirected);
        if entry_dir.exists() {
            std::fs::remove_dir_all(&entry_dir).unwrap();
        }
        std::os::unix::fs::symlink(&victim_dir, &entry_dir).unwrap();
        let before = rev_parse(&victim, "origin/main");

        let err = update_cached_repo(&remote_at(&cache, &origin))
            .unwrap_err()
            .to_string();

        assert!(
            err.contains(&format!("redirects {redirected} elsewhere")),
            "{redirected}: {err}"
        );
        assert!(
            !err.contains(&victim.display().to_string()),
            "the victim path may not be printed: {err}"
        );
        assert_eq!(
            rev_parse(&victim, "origin/main"),
            before,
            "{redirected}: the victim's refs were advanced by the refused update"
        );
        let _ = std::fs::remove_dir_all(root);
    }
}

/// The gate is an allowlist, so it must still accept exactly what a clone
/// writes — otherwise every cache entry is refused and the refusal proves
/// nothing.
#[test]
fn a_plain_clone_passes_the_cache_configuration_check() {
    let root = tmpdir("clone-config-ok");
    let origin = root.join("origin");
    init_git_repo(&origin);
    let cache = root.join("cache").join("owner_repo");
    clone_into(&origin, &cache);

    reject_unowned_cache_config(&remote_at(&cache, &origin)).unwrap();

    let _ = std::fs::remove_dir_all(root);
}

#[test]
fn config_keys_normalize_their_subsection_away() {
    assert_eq!(normalized_config_key("core.fileMode"), "core.filemode");
    assert_eq!(normalized_config_key("remote.origin.url"), "remote.*.url");
    assert_eq!(normalized_config_key("branch.v1.2.merge"), "branch.*.merge");
    assert_eq!(
        normalized_config_key("Filter.LFS.smudge"),
        "filter.*.smudge"
    );
    assert_eq!(normalized_config_key("bare"), "bare");
}

#[test]
fn update_cached_repo_brings_an_owned_cache_to_origin_head() {
    let root = tmpdir("owned-update");
    let origin = root.join("origin");
    init_git_repo(&origin);
    let cache = root.join("cache").join("owner_repo");
    clone_into(&origin, &cache);
    std::fs::write(origin.join("README.md"), "newer\n").unwrap();
    git(&origin, &["commit", "-q", "-am", "update"]);
    // Local edits in the cache are vstack's to discard.
    std::fs::write(cache.join("README.md"), "scribble\n").unwrap();

    drop(update_cached_repo(&remote_at(&cache, &origin)).unwrap());

    assert_eq!(
        std::fs::read_to_string(cache.join("README.md")).unwrap(),
        "newer\n"
    );
    let _ = std::fs::remove_dir_all(root);
}

/// Reading a cache entry is how its content becomes the installed asset, so
/// the read-only resolution asks the same ownership questions the update does.
/// An entry that is a real clone of a DIFFERENT repository passes every shape
/// check; only the origin identity catches it — and `add`'s reconciliation
/// reads sources through this path.
#[test]
fn read_only_resolution_refuses_a_cache_entry_cloned_from_another_repository() {
    let root = tmpdir("read-only-foreign-origin");
    let home = root.join("home");
    let other = root.join("other-origin");
    init_git_repo(&other);
    std::fs::create_dir_all(other.join("skills/demo")).unwrap();

    crate::test_util::with_home_and_config(&home, &home.join(".config"), || {
        let remote = RemoteSource::parse("owner/repo").unwrap().unwrap();
        clone_into(&other, &remote.cache_dir);

        let resolution = source_path_resolution("owner/repo");

        let SourceResolution::Refused(reason) = resolution else {
            panic!("a clone of another repository resolved as this source: {resolution:?}");
        };
        assert!(reason.contains("its origin is"), "{reason}");
        assert!(reason.contains("not this source"), "{reason}");
    });
    let _ = std::fs::remove_dir_all(root);
}

/// The ownership check proves the entry is THIS repository's clone; it may
/// still hold the URL that first minted it. Fetching through that URL means a
/// user who selects a different transport — because the first one stopped
/// authenticating — keeps failing over the old one, and a failed fetch is
/// tolerated, so the selection silently never runs.
#[test]
fn update_fetches_through_the_url_this_invocation_selected() {
    let root = tmpdir("origin-retarget");
    let origin = root.join("origin");
    init_git_repo(&origin);
    let cache = root.join("cache").join("owner_repo");
    clone_into(&origin, &cache);
    std::fs::write(origin.join("README.md"), "newer\n").unwrap();
    git(&origin, &["commit", "-q", "-am", "update"]);

    // An identity-equal spelling of the same repository: the ownership check
    // accepts it, and it is not the URL the entry was cloned with.
    let selected = format!("{}/", file_url(&origin));
    let remote = RemoteSource {
        git_url: selected.clone(),
        ..remote_at(&cache, &origin)
    };

    drop(update_cached_repo(&remote).unwrap());

    let recorded = std::process::Command::new("git")
        .args(["remote", "get-url", "origin"])
        .current_dir(&cache)
        .output()
        .unwrap();
    assert_eq!(
        git_stdout_line(&recorded.stdout),
        selected,
        "the entry kept the URL it was minted with"
    );
    // And the update still did its work through it.
    assert_eq!(
        std::fs::read_to_string(cache.join("README.md")).unwrap(),
        "newer\n"
    );
    let _ = std::fs::remove_dir_all(root);
}

#[test]
fn update_tolerates_a_failed_fetch_and_keeps_the_stale_cache() {
    let root = tmpdir("fetch-fail");
    let origin = root.join("origin");
    init_git_repo(&origin);
    let cache = root.join("cache").join("owner_repo");
    clone_into(&origin, &cache);
    let remote = remote_at(&cache, &origin);
    std::fs::remove_dir_all(&origin).unwrap();

    drop(update_cached_repo(&remote).unwrap());
    assert_eq!(
        std::fs::read_to_string(cache.join("README.md")).unwrap(),
        "upstream\n"
    );
    let _ = std::fs::remove_dir_all(root);
}

#[test]
fn update_reports_a_failed_reset_as_an_error() {
    let root = tmpdir("reset-fail");
    let origin = root.join("origin");
    init_git_repo(&origin);
    let cache = root.join("cache").join("owner_repo");
    clone_into(&origin, &cache);
    // The fetch succeeds; the reset cannot take the index lock.
    std::fs::write(cache.join(".git").join("index.lock"), "").unwrap();

    let err = update_cached_repo(&remote_at(&cache, &origin))
        .unwrap_err()
        .to_string();
    assert!(err.contains("git reset failed"), "{err}");
    let _ = std::fs::remove_dir_all(root);
}

#[test]
fn update_refuses_a_cache_whose_origin_is_another_repository() {
    let root = tmpdir("origin-mismatch");
    let origin = root.join("origin");
    init_git_repo(&origin);
    let other = root.join("other");
    init_git_repo(&other);
    let cache = root.join("cache").join("owner_repo");
    clone_into(&other, &cache);

    let err = update_cached_repo(&remote_at(&cache, &origin))
        .unwrap_err()
        .to_string();
    assert!(err.contains("its origin is"), "{err}");
    assert!(err.contains("not this source"), "{err}");
    let _ = std::fs::remove_dir_all(root);
}

#[test]
fn update_refuses_a_cache_whose_origin_carries_a_credential() {
    let root = tmpdir("origin-credential");
    let origin = root.join("origin");
    init_git_repo(&origin);
    // A real clone, so its config is the one a clone writes — an `init`ed
    // repository carries the identity settings the ownership check refuses.
    let cache = root.join("cache").join("owner_repo");
    clone_into(&origin, &cache);
    // Identity-equal to the clean expected URL: userinfo normalizes away,
    // so the mismatch check alone would accept this and then fetch with
    // the token.
    git(
        &cache,
        &[
            "remote",
            "set-url",
            "origin",
            "https://cache-token@github.com/Owner/Repo.git",
        ],
    );
    let remote = RemoteSource::parse("owner/repo").unwrap().unwrap();
    let remote = RemoteSource {
        cache_dir: cache.clone(),
        ..remote
    };

    let err = update_cached_repo(&remote).unwrap_err().to_string();
    assert!(err.contains("carries a credential"), "{err}");
    assert!(!err.contains("cache-token"), "{err}");

    // A clean origin with the same identity passes the origin checks.
    git(
        &cache,
        &[
            "remote",
            "set-url",
            "origin",
            "https://github.com/Owner/Repo.git",
        ],
    );
    ensure_cache_entry_is_owned(&remote).unwrap();
    let _ = std::fs::remove_dir_all(root);
}

#[cfg(unix)]
#[test]
fn symlinked_cache_entry_is_refused_on_every_resolution_path() {
    // The fixture label shares no token with any asserted string: the
    // refusal ends with the cache root path, so a label containing one
    // would satisfy the assertions whichever refusal fired.
    let root = tmpdir("borrowed-worktree");
    let checkout = root.join("user-checkout");
    init_git_repo(&checkout);
    std::fs::write(checkout.join("uncommitted.txt"), "precious\n").unwrap();
    std::fs::write(checkout.join("README.md"), "precious\n").unwrap();
    let home = root.join("home");

    crate::test_util::with_home_and_config(&home, &home.join(".config"), || {
        let remote = RemoteSource::parse("owner/repo").unwrap().unwrap();
        std::fs::create_dir_all(remote.cache_dir.parent().unwrap()).unwrap();
        std::os::unix::fs::symlink(&checkout, &remote.cache_dir).unwrap();

        let err = reject_unowned_cache_entry(&remote).unwrap_err().to_string();
        assert!(err.contains("its cache entry is a symlink"), "{err}");
        let err = update_cached_repo(&remote).unwrap_err().to_string();
        assert!(err.contains("its cache entry is a symlink"), "{err}");
        // Neither the read-only nor the updating resolution returns the
        // linked checkout as the remote source, and both report the
        // refusal rather than an absent source.
        for leased in [
            resolve_single_source_with("owner/repo", false, false),
            resolve_single_source_with("owner/repo", true, true),
        ] {
            let resolution = leased.resolution;
            assert!(
                matches!(&resolution, SourceResolution::Refused(reason) if reason.contains("its cache entry is a symlink")),
                "{resolution:?}"
            );
        }
        assert_eq!(resolve_source_path("owner/repo"), None);
        assert!(recorded_source_exists("owner/repo"));
    });
    assert_eq!(
        std::fs::read_to_string(checkout.join("README.md")).unwrap(),
        "precious\n"
    );
    assert!(checkout.join("uncommitted.txt").exists());
    let _ = std::fs::remove_dir_all(root);
}

/// A cache entry that is not a directory at all. The callers all gate on
/// `.git` being present, which a plain file cannot satisfy, so this pins
/// the check's own contract: without it the entry falls through to the
/// git-metadata read and answers with an `inspecting` context error.
#[test]
fn a_cache_entry_that_is_not_a_directory_is_refused() {
    let root = tmpdir("plain-file");
    let home = root.join("home");
    crate::test_util::with_home_and_config(&home, &home.join(".config"), || {
        let remote = RemoteSource::parse("owner/repo").unwrap().unwrap();
        std::fs::create_dir_all(remote.cache_dir.parent().unwrap()).unwrap();
        std::fs::write(&remote.cache_dir, "not a clone\n").unwrap();

        for err in [
            reject_unowned_cache_entry(&remote),
            ensure_cache_entry_is_owned(&remote),
            update_cached_repo(&remote).map(|_| ()),
        ] {
            let err = format!("{:#}", err.unwrap_err());
            assert!(err.contains("its cache entry is not a directory"), "{err}");
        }
    });
    let _ = std::fs::remove_dir_all(root);
}

#[cfg(unix)]
#[test]
fn cache_entry_whose_git_metadata_is_redirected_is_refused() {
    let root = tmpdir("redirected-gitdir");
    let checkout = root.join("user-checkout");
    init_git_repo(&checkout);
    std::fs::write(checkout.join("README.md"), "precious\n").unwrap();
    // A plain directory, so the entry check passes, whose `.git` points at
    // the user's real repository.
    let cache = root.join("cache").join("owner_repo");
    std::fs::create_dir_all(&cache).unwrap();
    std::os::unix::fs::symlink(checkout.join(".git"), cache.join(".git")).unwrap();
    let remote = remote_at(&cache, &checkout);

    let err = update_cached_repo(&remote).unwrap_err().to_string();
    assert!(err.contains("does not own its git metadata"), "{err}");

    // A `gitdir:` file is the same redirection by another spelling.
    std::fs::remove_file(cache.join(".git")).unwrap();
    std::fs::write(
        cache.join(".git"),
        format!("gitdir: {}\n", checkout.join(".git").display()),
    )
    .unwrap();
    let err = update_cached_repo(&remote).unwrap_err().to_string();
    assert!(err.contains("does not own its git metadata"), "{err}");
    assert_eq!(
        std::fs::read_to_string(checkout.join("README.md")).unwrap(),
        "precious\n"
    );
    let _ = std::fs::remove_dir_all(root);
}

fn command_env(
    command: &std::process::Command,
) -> std::collections::BTreeMap<String, Option<String>> {
    command
        .get_envs()
        .map(|(key, value)| {
            (
                key.to_string_lossy().into_owned(),
                value.map(|v| v.to_string_lossy().into_owned()),
            )
        })
        .collect()
}

#[test]
fn every_git_invocation_is_non_interactive_and_drops_inherited_git_config() {
    let root = tmpdir("git-env");
    let home = root.join("home");
    crate::test_util::with_home_and_config(&home, &home.join(".config"), || {
        git_env_assertions(&root)
    });
    let _ = std::fs::remove_dir_all(root);
}

fn git_env_assertions(root: &Path) {
    let dir = remote_cache_root().join("owner_repo");
    init_git_repo(&dir);
    let project = command_env(&hardened_git_command(&dir));
    // Control: a bare `git` carries none of it, so the assertions below
    // are claims about the hardening and not about two empty maps.
    assert_ne!(command_env(&std::process::Command::new("git")), project);

    assert_eq!(
        project
            .get("GIT_TERMINAL_PROMPT")
            .cloned()
            .flatten()
            .as_deref(),
        Some("0")
    );
    // WHICH variables are cleared, and what clearing each one buys, is
    // asserted behaviourally in
    // `no_inherited_git_environment_reaches_the_commands_vstack_runs` — a
    // loop over the constant would take its own assertion away with any
    // entry deleted from it. What this asserts is the SHAPE the three
    // constructors share.
    let cache = command_env(&hardened_cache_git_command(&dir).unwrap());
    for (key, value) in &project {
        assert_eq!(cache.get(key), Some(value), "{key} differs for the cache");
    }

    // The network path is the cache path plus exactly one variable, whose
    // value is asserted against the same inputs the constructor reads.
    // Repository-scope values are set here as a control: they must NOT
    // appear, because the repository a cache command runs in is a cache
    // entry — see `the_cache_entrys_own_config_never_names_the_ssh_program`.
    git(&dir, &["config", "core.sshCommand", "/opt/vstack-test-ssh"]);
    git(&dir, &["config", "ssh.variant", "plink"]);
    let network = command_env(&hardened_git_network_command(&dir).unwrap());
    for (key, value) in &cache {
        assert_eq!(
            network.get(key),
            Some(value),
            "{key} differs on the network path"
        );
    }
    for (key, value) in &network {
        if key != "GIT_SSH_COMMAND" {
            assert_eq!(cache.get(key), Some(value), "{key} differs");
        }
    }
    // What the value should BE for given inputs is asserted against
    // literals in `the_network_command_carries_the_ssh_command_git_would_have_used`;
    // what this asserts is that the command carries it at all.
    let expected = network_ssh_command(&dir);
    // Control: the variable is always carried, so the equality below
    // cannot pass by both sides being absent.
    assert!(
        !expected.is_empty(),
        "the network command must always name an ssh command"
    );
    assert!(
        !expected.contains("/opt/vstack-test-ssh"),
        "the repository's own core.sshCommand reached the network command: {expected}"
    );
    assert_eq!(
        network.get("GIT_SSH_COMMAND").cloned().flatten(),
        Some(expected),
        "the network command must carry the ssh command built from git's own inputs"
    );

    // Cloning is as unattended as fetching and must be built by the same
    // constructor — for the cache root, which is where it runs.
    let remote = remote_at(&dir, &root.join("origin"));
    assert_eq!(
        command_env(&cache_clone_command(&remote, &remote.cache_dir).unwrap()),
        command_env(&hardened_git_network_command(&remote_cache_root()).unwrap())
    );
}

const INHERITED_ENV_HELPER: &str = "refresh_sources::tests::inherited_git_env_helper";
const SSH_WIRING_HELPER: &str = "refresh_sources::tests::network_ssh_command_helper";
const USER_SSH_CONFIG_HELPER: &str = "refresh_sources::tests::user_ssh_config_helper";

/// Every variable the constructor scrubs, proven by what git DOES with it
/// rather than by the name appearing in a list — a test that iterates the
/// constant it checks removes an entry from its own assertion.
///
/// Each row sets one variable in a child process and asserts the effect,
/// against an unhardened control in the same environment. The table must
/// name every entry of both constants, so adding one without covering it,
/// or deleting one, fails here.
#[test]
fn no_inherited_git_environment_reaches_the_commands_vstack_runs() {
    let root = tmpdir("inherited-git-env");
    let cache = root.join("cache-entry");
    init_git_repo(&cache);
    std::fs::create_dir_all(cache.join("sub")).unwrap();
    let project = root.join("project");
    init_git_repo(&project);
    std::fs::create_dir_all(project.join("sub")).unwrap();
    let alternate = root.join("alternate");
    init_git_repo(&alternate);
    // Content of its own, so its commit cannot be the byte-identical
    // object the cache repository already holds.
    std::fs::write(alternate.join("README.md"), "alternate\n").unwrap();
    git(&alternate, &["commit", "-q", "-am", "alternate"]);
    let alternate_sha = git_stdout(&alternate, &["rev-parse", "HEAD"]);

    let injected = root.join("evil-ssh");
    let config_file = root.join("injected.gitconfig");
    std::fs::write(
        &config_file,
        format!("[core]\n\tsshCommand = {}\n", injected.display()),
    )
    .unwrap();
    let parameters = format!("'core.sshCommand={}'", injected.display());
    let marker = root.join("marker-ran");
    let exec_dir = root.join("exec-path");
    write_marker_program(&exec_dir.join("git-remote-https"), &marker);
    let askpass = root.join("askpass.sh");
    write_marker_program(&askpass, &marker);
    let template = root.join("git-template");
    write_marker_program(&template.join("hooks/post-checkout"), &marker);
    let alternate_objects = alternate.join(".git/objects");
    let empty = root.join("empty-objects");
    std::fs::create_dir_all(&empty).unwrap();
    let empty_index = root.join("empty-index");
    std::fs::write(&empty_index, b"").unwrap();
    let port = serve_unauthorized();
    let port = port.to_string();
    let ceiling = format!("{}:{}", cache.display(), project.display());

    // One row per scrubbed variable: its name, and the value plus fixture
    // environment that make its effect observable. `None` is a variable whose
    // effect cannot be observed from a test, stated with the reason.
    type Env<'a> = Vec<(&'a str, &'a std::ffi::OsStr)>;
    let vectors: Vec<(&str, Option<(&str, Env<'_>)>)> = vec![
        // The location family is driven by path_safety's own child test,
        // whose environment sets all three and whose assertions require
        // every identity read to answer for the directory it was pointed
        // at rather than for the one they name.
        ("GIT_DIR", None),
        ("GIT_WORK_TREE", None),
        ("GIT_COMMON_DIR", None),
        (
            "GIT_INDEX_FILE",
            Some(("index", vec![("GIT_INDEX_FILE", empty_index.as_os_str())])),
        ),
        (
            "GIT_OBJECT_DIRECTORY",
            Some(("objects", vec![("GIT_OBJECT_DIRECTORY", empty.as_os_str())])),
        ),
        (
            "GIT_ALTERNATE_OBJECT_DIRECTORIES",
            Some((
                "alternates",
                vec![(
                    "GIT_ALTERNATE_OBJECT_DIRECTORIES",
                    alternate_objects.as_os_str(),
                )],
            )),
        ),
        (
            "GIT_NAMESPACE",
            Some((
                "namespace",
                vec![("GIT_NAMESPACE", std::ffi::OsStr::new("ns"))],
            )),
        ),
        (
            "GIT_CONFIG_PARAMETERS",
            Some((
                "config",
                vec![(
                    "GIT_CONFIG_PARAMETERS",
                    std::ffi::OsStr::new(parameters.as_str()),
                )],
            )),
        ),
        (
            "GIT_CONFIG",
            Some(("config", vec![("GIT_CONFIG", config_file.as_os_str())])),
        ),
        (
            "GIT_CONFIG_GLOBAL",
            Some((
                "config",
                vec![("GIT_CONFIG_GLOBAL", config_file.as_os_str())],
            )),
        ),
        (
            "GIT_CONFIG_SYSTEM",
            Some((
                "config",
                vec![("GIT_CONFIG_SYSTEM", config_file.as_os_str())],
            )),
        ),
        // Suppresses system config rather than injecting anything, so
        // there is no effect to observe: with it scrubbed and honoured
        // alike, git reads the system config vstack would have read.
        ("GIT_CONFIG_NOSYSTEM", None),
        (
            "GIT_CONFIG_COUNT",
            Some((
                "config",
                vec![
                    ("GIT_CONFIG_COUNT", std::ffi::OsStr::new("1")),
                    ("GIT_CONFIG_KEY_0", std::ffi::OsStr::new("core.sshCommand")),
                    ("GIT_CONFIG_VALUE_0", injected.as_os_str()),
                ],
            )),
        ),
        (
            "GIT_EXEC_PATH",
            Some(("exec-path", vec![("GIT_EXEC_PATH", exec_dir.as_os_str())])),
        ),
        (
            "GIT_TEMPLATE_DIR",
            Some(("template", vec![("GIT_TEMPLATE_DIR", template.as_os_str())])),
        ),
        (
            "GIT_ASKPASS",
            Some(("askpass", vec![("GIT_ASKPASS", askpass.as_os_str())])),
        ),
        (
            "SSH_ASKPASS",
            Some((
                "askpass",
                vec![
                    ("SSH_ASKPASS", askpass.as_os_str()),
                    // Set so the unhardened control fires on the variable
                    // git prefers. The hardened assertion still bites for
                    // the one this row is named for: with `GIT_ASKPASS`
                    // removed and `SSH_ASKPASS` left, git falls back to it.
                    ("GIT_ASKPASS", askpass.as_os_str()),
                ],
            )),
        ),
        (
            "GIT_CEILING_DIRECTORIES",
            Some((
                "ceiling",
                vec![(
                    "GIT_CEILING_DIRECTORIES",
                    std::ffi::OsStr::new(ceiling.as_str()),
                )],
            )),
        ),
        // Needs a filesystem boundary between a repository and its
        // working directory, which a test cannot create.
        ("GIT_DISCOVERY_ACROSS_FILESYSTEM", None),
    ];

    let covered: std::collections::BTreeSet<&str> = vectors.iter().map(|(name, _)| *name).collect();
    let scrubbed: std::collections::BTreeSet<&str> = GIT_INHERITED_ENV_VARS
        .iter()
        .chain(GIT_CACHE_ONLY_ENV_VARS)
        .copied()
        .collect();
    assert_eq!(
        covered, scrubbed,
        "every scrubbed variable needs a row here, and every row a variable"
    );

    for (name, vector) in &vectors {
        let Some((case, vector)) = vector else {
            continue;
        };
        let mut env = vector.clone();
        env.push(("VSTACK_TEST_VECTOR", std::ffi::OsStr::new(case)));
        env.push(("VSTACK_TEST_CACHE_REPO", cache.as_os_str()));
        env.push(("VSTACK_TEST_PROJECT_REPO", project.as_os_str()));
        env.push(("VSTACK_TEST_INJECTED_SSH", injected.as_os_str()));
        env.push(("VSTACK_TEST_MARKER", marker.as_os_str()));
        env.push((
            "VSTACK_TEST_ALTERNATE_SHA",
            std::ffi::OsStr::new(alternate_sha.as_str()),
        ));
        env.push(("VSTACK_TEST_HTTP_PORT", std::ffi::OsStr::new(port.as_str())));
        let _ = std::fs::remove_file(&marker);
        crate::test_util::run_test_helper(INHERITED_ENV_HELPER, &env, None);
        assert!(!marker.exists(), "{name}: a marker program ran");
    }
    let _ = std::fs::remove_dir_all(root);
}

/// A program that records that it ran, then fails.
fn write_marker_program(path: &Path, marker: &Path) {
    std::fs::create_dir_all(path.parent().unwrap()).unwrap();
    std::fs::write(
        path,
        format!(
            "#!/usr/bin/env bash\nprintf ran > {}\nexit 1\n",
            marker.display()
        ),
    )
    .unwrap();
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        std::fs::set_permissions(path, std::fs::Permissions::from_mode(0o755)).unwrap();
    }
}

/// A local HTTP endpoint that always demands basic auth — what makes git
/// reach for an askpass program. Returns its port.
fn serve_unauthorized() -> u16 {
    let listener = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
    let port = listener.local_addr().unwrap().port();
    std::thread::spawn(move || {
        use std::io::{Read, Write};
        for stream in listener.incoming().take(32) {
            let Ok(mut stream) = stream else { continue };
            let mut buffer = [0u8; 4096];
            let _ = stream.read(&mut buffer);
            let _ = stream.write_all(
                b"HTTP/1.1 401 Unauthorized\r\nWWW-Authenticate: Basic realm=\"vstack\"\r\nContent-Length: 0\r\n\r\n",
            );
        }
    });
    port
}

#[test]
#[ignore = "driven by no_inherited_git_environment_reaches_the_commands_vstack_runs, which sets one vector per run"]
fn inherited_git_env_helper() {
    // `None` only when run directly; a driver that lost an env entry
    // panics rather than asserting nothing.
    let Some(case) = crate::test_util::helper_fixture("VSTACK_TEST_VECTOR") else {
        return;
    };
    let cache = PathBuf::from(crate::test_util::helper_fixture("VSTACK_TEST_CACHE_REPO").unwrap());
    let unhardened = |dir: &Path, args: &[&str]| {
        std::process::Command::new("git")
            .args(args)
            .current_dir(dir)
            .output()
            .unwrap()
    };

    match case.as_str() {
        "config" => {
            let injected = crate::test_util::helper_fixture("VSTACK_TEST_INJECTED_SSH").unwrap();
            // Control: an unhardened `git config --get` in this environment
            // DOES return the injected program.
            assert_eq!(
                git_stdout_line(
                    &unhardened(&cache, &["config", "--get", "core.sshCommand"]).stdout
                ),
                injected,
                "the vector must reach an unhardened git for this to prove anything"
            );
            assert_ne!(
                configured_ssh_command(&cache).as_deref(),
                Some(injected.as_str()),
                "the injected core.sshCommand was read back"
            );
            let network = network_ssh_command(&cache);
            assert!(
                !network.contains(&injected),
                "the injected core.sshCommand was re-exported to the fetch: {network}"
            );
            // Scrubbing must leave a WORKING git: dropping the indexed
            // pairs while leaving `GIT_CONFIG_COUNT` set makes every
            // command exit "missing config key", which is not an answer.
            let probe = hardened_git_command(&cache)
                .args(["config", "--get", "core.noSuchKeyHere"])
                .output()
                .unwrap();
            assert_eq!(
                probe.status.code(),
                Some(1),
                "the hardened command is not a usable git: {}",
                git_output_summary(&probe)
            );
        }
        "index" => {
            let hardened = hardened_cache_git_command(&cache)
                .unwrap()
                .arg("ls-files")
                .output()
                .unwrap();
            assert_eq!(git_stdout_line(&hardened.stdout), "README.md");
            assert_ne!(
                git_stdout_line(&unhardened(&cache, &["ls-files"]).stdout),
                "README.md",
                "the vector must change an unhardened answer"
            );
        }
        "objects" => {
            assert!(
                hardened_cache_git_command(&cache)
                    .unwrap()
                    .args(["cat-file", "-e", "HEAD^{commit}"])
                    .status()
                    .unwrap()
                    .success()
            );
            assert!(
                !unhardened(&cache, &["cat-file", "-e", "HEAD^{commit}"])
                    .status
                    .success(),
                "the vector must change an unhardened answer"
            );
        }
        "alternates" => {
            let sha = crate::test_util::helper_fixture("VSTACK_TEST_ALTERNATE_SHA").unwrap();
            assert!(
                !hardened_cache_git_command(&cache)
                    .unwrap()
                    .args(["cat-file", "-e", &sha])
                    .status()
                    .unwrap()
                    .success(),
                "an inherited alternate object store answered for the cache"
            );
            assert!(
                unhardened(&cache, &["cat-file", "-e", &sha])
                    .status
                    .success(),
                "the vector must change an unhardened answer"
            );
        }
        "namespace" => {
            // The namespace applies to the refs a fetch is served, which is
            // what `update_cached_repo` runs.
            let hardened = hardened_git_network_command(&cache)
                .unwrap()
                .args(["ls-remote", "--"])
                .arg(&cache)
                .output()
                .unwrap();
            assert!(
                git_stdout_line(&hardened.stdout).contains("refs/heads/"),
                "no refs listed: {}",
                git_output_summary(&hardened)
            );
            assert!(
                unhardened(&cache, &["ls-remote", "--", &cache.to_string_lossy()])
                    .stdout
                    .is_empty(),
                "the vector must change an unhardened answer"
            );
        }
        "exec-path" => {
            let marker =
                PathBuf::from(crate::test_util::helper_fixture("VSTACK_TEST_MARKER").unwrap());
            let url = "https://127.0.0.1:1/x.git";
            // Control: git runs the helper program the inherited exec path
            // provides, on this exact command.
            let _ = unhardened(&cache, &["ls-remote", "--", url]);
            assert!(
                marker.exists(),
                "the vector must reach an unhardened git for this to prove anything"
            );
            std::fs::remove_file(&marker).unwrap();

            let _ = hardened_git_network_command(&cache)
                .unwrap()
                .args(["ls-remote", "--", url])
                .output()
                .unwrap();
            assert!(!marker.exists(), "git ran the inherited remote helper");
        }
        "template" => {
            let marker =
                PathBuf::from(crate::test_util::helper_fixture("VSTACK_TEST_MARKER").unwrap());
            let root = cache.parent().unwrap().join("template-vector");
            let origin = root.join("origin");
            std::fs::create_dir_all(&origin).unwrap();
            for args in [
                vec!["init", "-q", "-b", "main"],
                vec!["config", "user.email", "test@example.com"],
                vec!["config", "user.name", "Test"],
                vec!["config", "commit.gpgsign", "false"],
            ] {
                assert!(unhardened(&origin, &args).status.success(), "{args:?}");
            }
            std::fs::write(origin.join("README.md"), "upstream\n").unwrap();
            assert!(unhardened(&origin, &["add", "README.md"]).status.success());
            assert!(
                unhardened(&origin, &["commit", "-q", "-m", "init"])
                    .status
                    .success()
            );
            let url = format!("file://{}", origin.display());

            // Control: the inherited template's `post-checkout` hook is copied
            // into the new repository and RUN by an unhardened clone.
            let control = root.join("control-clone");
            std::fs::create_dir_all(&control).unwrap();
            let _ = unhardened(
                &control,
                &[
                    "clone",
                    "-q",
                    "--",
                    &url,
                    control.join("c").to_str().unwrap(),
                ],
            );
            assert!(
                marker.exists(),
                "the vector must reach an unhardened git for this to prove anything"
            );
            std::fs::remove_file(&marker).unwrap();

            let hardened_dest = root.join("hardened-clone");
            std::fs::create_dir_all(&hardened_dest).unwrap();
            let _ = hardened_git_network_command(&hardened_dest)
                .unwrap()
                .args(["clone", "-q", "--", &url])
                .arg(hardened_dest.join("c"))
                .output()
                .unwrap();
            assert!(
                !marker.exists(),
                "the clone ran a hook from the inherited template directory"
            );
        }
        "askpass" => {
            let marker =
                PathBuf::from(crate::test_util::helper_fixture("VSTACK_TEST_MARKER").unwrap());
            let port = crate::test_util::helper_fixture("VSTACK_TEST_HTTP_PORT").unwrap();
            let url = format!("http://127.0.0.1:{port}/x.git");
            let _ = unhardened(&cache, &["ls-remote", "--", &url]);
            assert!(
                marker.exists(),
                "the vector must reach an unhardened git for this to prove anything"
            );
            std::fs::remove_file(&marker).unwrap();

            let _ = hardened_git_network_command(&cache)
                .unwrap()
                .args(["ls-remote", "--", &url])
                .output()
                .unwrap();
            assert!(!marker.exists(), "git ran the inherited askpass program");
        }
        "ceiling" => {
            let project = PathBuf::from(
                crate::test_util::helper_fixture("VSTACK_TEST_PROJECT_REPO").unwrap(),
            );
            // Cleared for the cache, where vstack owns the repository.
            let hardened = hardened_cache_git_command(&cache.join("sub"))
                .unwrap()
                .args(["rev-parse", "--show-toplevel"])
                .output()
                .unwrap();
            assert!(
                hardened.status.success(),
                "an inherited ceiling stopped the cache read: {}",
                git_output_summary(&hardened)
            );
            assert!(
                !unhardened(&cache.join("sub"), &["rev-parse", "--show-toplevel"])
                    .status
                    .success(),
                "the vector must change an unhardened answer"
            );
            // Honoured for the user's own project, where it is their
            // configuration rather than something hostile.
            assert_eq!(
                crate::path_safety::git_toplevel(&project.join("sub")),
                None,
                "the project read must answer as the user's git would"
            );
        }
        other => panic!("unknown vector {other}"),
    }
}

/// The three environment inputs of [`network_ssh_command`] are only proven
/// against literals: an expectation recomputed from the same reads compares
/// a value with itself, and dropping any one read is a real regression —
/// losing the `GIT_SSH_COMMAND` read overwrites the user's own wrapper.
#[test]
fn the_network_command_carries_the_ssh_command_git_would_have_used() {
    let root = tmpdir("network-ssh-wiring");
    std::fs::create_dir_all(&root).unwrap();
    for (env, expected) in [
        (
            vec![("GIT_SSH_COMMAND", "/opt/user-ssh -i /keys/id")],
            "/opt/user-ssh -i /keys/id -o BatchMode=yes",
        ),
        // A `GIT_SSH` program is invoked with host and command arguments
        // only, so it takes no option — but it is still pinned, quoted as
        // one shell word.
        (vec![("GIT_SSH", "/opt/user-ssh")], "'/opt/user-ssh'"),
        (
            vec![("GIT_SSH_COMMAND", "ssh"), ("GIT_SSH_VARIANT", "plink")],
            "ssh -batch",
        ),
        // `simple` takes no options at all, and is pinned unchanged.
        (
            vec![("GIT_SSH_COMMAND", "ssh"), ("GIT_SSH_VARIANT", "simple")],
            "ssh",
        ),
    ] {
        let mut env: Vec<(&str, &std::ffi::OsStr)> = env
            .iter()
            .map(|(key, value)| (*key, std::ffi::OsStr::new(*value)))
            .collect();
        env.push(("VSTACK_TEST_EXPECTED_SSH", std::ffi::OsStr::new(expected)));
        env.push(("VSTACK_TEST_WORK_DIR", root.as_os_str()));
        crate::test_util::run_test_helper(SSH_WIRING_HELPER, &env, None);
    }
    let _ = std::fs::remove_dir_all(root);
}

#[test]
#[ignore = "driven by the_network_command_carries_the_ssh_command_git_would_have_used, which sets one input combination per run"]
fn network_ssh_command_helper() {
    let Some(expected) = crate::test_util::helper_fixture("VSTACK_TEST_EXPECTED_SSH") else {
        return;
    };
    let dir = PathBuf::from(crate::test_util::helper_fixture("VSTACK_TEST_WORK_DIR").unwrap());
    assert_eq!(network_ssh_command(&dir), expected);
    // And the value the command actually carries is that same one.
    let network = command_env(&hardened_git_network_command(&dir).unwrap());
    assert_eq!(
        network.get("GIT_SSH_COMMAND").cloned().flatten(),
        Some(expected)
    );
}

#[test]
fn batch_mode_ssh_command_follows_git_precedence() {
    // Nothing configured.
    assert_eq!(
        batch_mode_ssh_command(None, None, None, None, None),
        "ssh -o BatchMode=yes"
    );
    assert_eq!(
        batch_mode_ssh_command(Some("   "), None, None, None, None),
        "ssh -o BatchMode=yes"
    );
    // GIT_SSH_COMMAND outranks core.sshCommand.
    assert_eq!(
        batch_mode_ssh_command(Some("ssh"), Some("/opt/ssh"), Some("/x"), None, None),
        "ssh -o BatchMode=yes"
    );
    assert_eq!(
        batch_mode_ssh_command(None, Some("/opt/ssh"), Some("/x"), None, None),
        "/opt/ssh -o BatchMode=yes"
    );
    // A quoted program token is one token, whitespace and all.
    assert_eq!(
        batch_mode_ssh_command(Some("'/my ssh'"), None, None, None, None),
        "'/my ssh' -o BatchMode=yes"
    );
    // GIT_SSH_VARIANT outranks ssh.variant, as it does in git.
    assert_eq!(
        batch_mode_ssh_command(Some("/opt/ssh"), None, None, Some("plink"), Some("ssh")),
        "/opt/ssh -batch"
    );
    assert_eq!(
        batch_mode_ssh_command(
            Some("plink"),
            None,
            None,
            Some("ssh"),
            Some("tortoiseplink")
        ),
        "plink -o BatchMode=yes"
    );
    // An unknown or `auto` GIT_SSH_VARIANT falls through to ssh.variant,
    // and then to detection — again as in git.
    assert_eq!(
        batch_mode_ssh_command(Some("/opt/ssh"), None, None, Some("auto"), Some("plink")),
        "/opt/ssh -batch"
    );
    assert_eq!(
        batch_mode_ssh_command(Some("plink"), None, None, Some("auto"), None),
        "plink -batch"
    );
}

/// A `GIT_SSH_COMMAND` git runs through a shell may be anything —
/// `env FOO=bar ssh`, a wrapper with its own arguments — and inserting an
/// option after its first token corrupts it. Appending keeps the command
/// intact AND noninteractive: git puts the host and upload-pack arguments
/// after the whole string, so a trailing option is still an option.
#[test]
fn a_command_carrying_arguments_is_made_noninteractive_without_being_rewritten() {
    for command in [
        "ssh -i /keys/a",
        "env FOO=bar ssh",
        "'/my ssh' -v",
        "ssh -o StrictHostKeyChecking=accept-new -i k",
    ] {
        let expected = format!("{command} -o BatchMode=yes");
        assert_eq!(
            batch_mode_ssh_command(Some(command), None, None, None, None),
            expected,
            "{command}"
        );
        assert_eq!(
            batch_mode_ssh_command(None, Some(command), None, None, None),
            expected,
            "{command}"
        );
    }
    // The user's own explicit choice stands: OpenSSH takes the first value
    // it sees, and ours comes after theirs.
    assert_eq!(
        batch_mode_ssh_command(Some("ssh -o BatchMode=no -i k"), None, None, None, None),
        "ssh -o BatchMode=no -i k -o BatchMode=yes"
    );
    // Where an option goes is the plink family's business, so a plink
    // command carrying arguments keeps its own argument list — but it is
    // still PINNED, so the cache's own `core.sshCommand` cannot choose it.
    for command in ["plink -i key", "/usr/bin/tortoiseplink -P 22"] {
        assert_eq!(
            batch_mode_ssh_command(Some(command), None, None, None, None),
            command,
            "{command}"
        );
    }
    assert_eq!(
        batch_mode_ssh_command(Some("/opt/myssh -v"), None, None, None, Some("plink")),
        "/opt/myssh -v"
    );
}

/// `-o BatchMode=yes` is OpenSSH's spelling and nobody else's. Git drives
/// four ssh implementations; handing the wrong one OpenSSH's option — or
/// rewriting a `GIT_SSH` program into a command line at all — breaks the
/// connection instead of making it noninteractive.
#[test]
fn batch_mode_matches_the_ssh_variant_git_would_use() {
    // Auto-detected by program basename, as git detects it — case and
    // `.exe` suffix included.
    for program in [
        "plink",
        "/usr/bin/plink",
        "PuTTY.exe",
        "PLINK.EXE",
        "C:\\tools\\TortoisePlink.exe",
    ] {
        assert_eq!(
            batch_mode_ssh_command(Some(program), None, None, None, None),
            format!("{program} -batch"),
            "{program}"
        );
    }
    // A quoted program token is unquoted before its basename decides:
    // `'/usr/bin/plink'` ends in `plink'`, which detects as OpenSSH and
    // takes an option plink rejects.
    for program in ["'/usr/bin/plink'", "\"/usr/bin/plink\""] {
        assert_eq!(
            batch_mode_ssh_command(Some(program), None, None, None, None),
            format!("{program} -batch"),
            "{program}"
        );
    }
    // An explicit ssh.variant outranks detection in both directions, in
    // every spelling git accepts for it.
    for variant in ["tortoiseplink", "plink", "putty"] {
        assert_eq!(
            batch_mode_ssh_command(Some("/opt/myssh"), None, None, None, Some(variant)),
            "/opt/myssh -batch",
            "{variant}"
        );
    }
    assert_eq!(
        batch_mode_ssh_command(Some("plink"), None, None, None, Some("ssh")),
        "plink -o BatchMode=yes"
    );
    // `auto` and unknown values fall through to detection, as in git.
    for variant in ["auto", "nonsense"] {
        assert_eq!(
            batch_mode_ssh_command(Some("plink"), None, None, None, Some(variant)),
            "plink -batch",
            "{variant}"
        );
    }
    // `simple` accepts no options at all, and a GIT_SSH program is invoked
    // with host and command arguments only. Neither takes an option — and
    // both are still pinned, quoted where a program path needs it, because
    // an unset `GIT_SSH_COMMAND` is what lets a repository's own config
    // name the program instead.
    assert_eq!(
        batch_mode_ssh_command(Some("/opt/simple-ssh"), None, None, None, Some("simple")),
        "/opt/simple-ssh"
    );
    assert_eq!(
        batch_mode_ssh_command(None, None, Some("/path with space/ssh"), None, None),
        "'/path with space/ssh'"
    );
    assert_eq!(
        batch_mode_ssh_command(None, None, Some("/x"), None, Some("ssh")),
        "'/x'"
    );
    assert_eq!(
        batch_mode_ssh_command(None, None, Some("/o'ddly named/ssh"), None, None),
        r"'/o'\''ddly named/ssh'"
    );
}

/// The ssh program for a cache fetch comes from the USER — their
/// environment, their global git config — and never from the repository
/// the command runs in. That repository is a cache entry, whose
/// `.git/config` is content vstack cloned: `core.sshCommand` there names a
/// program git RUNS, so reading it back was arbitrary code execution from
/// a cache entry that passes every ownership check.
#[test]
fn the_cache_entrys_own_config_never_names_the_ssh_program() {
    let root = tmpdir("core-ssh-command");
    let home = root.join("home");
    std::fs::create_dir_all(&home).unwrap();
    // Written as a file, never through `git config --global`: that writes
    // to the HOME the process actually has, and a test must not edit the
    // developer's own git configuration.
    std::fs::write(
        home.join(".gitconfig"),
        "[core]\n\tsshCommand = /opt/user-ssh\n",
    )
    .unwrap();
    let repo = root.join("repo");
    init_git_repo(&repo);
    git(
        &repo,
        &["config", "core.sshCommand", "/opt/tampered -i /keys/id"],
    );
    git(&repo, &["config", "ssh.variant", "simple"]);

    crate::test_util::run_test_helper(
        USER_SSH_CONFIG_HELPER,
        &[
            ("HOME", home.as_os_str()),
            ("XDG_CONFIG_HOME", home.join(".config").as_os_str()),
            ("VSTACK_TEST_CACHE_REPO", repo.as_os_str()),
            // The environment inputs outrank config and would mask both
            // halves of this.
            ("GIT_SSH_COMMAND", std::ffi::OsStr::new("")),
            ("GIT_SSH", std::ffi::OsStr::new("")),
            ("GIT_SSH_VARIANT", std::ffi::OsStr::new("")),
        ],
        None,
    );
    let _ = std::fs::remove_dir_all(root);
}

#[test]
#[ignore = "driven by the_cache_entrys_own_config_never_names_the_ssh_program, which sets the HOME its assertions depend on"]
fn user_ssh_config_helper() {
    let Some(repo) = crate::test_util::helper_fixture("VSTACK_TEST_CACHE_REPO") else {
        return;
    };
    let repo = PathBuf::from(repo);
    // Control: an unhardened `git config --get` in this repository DOES
    // return the tampered program, so the refusals below cannot pass by
    // the vector never having landed.
    assert_eq!(
        git_stdout_line(
            &std::process::Command::new("git")
                .args(["config", "--get", "core.sshCommand"])
                .current_dir(&repo)
                .output()
                .unwrap()
                .stdout
        ),
        "/opt/tampered -i /keys/id",
        "the vector must reach an unhardened git for this to prove anything"
    );

    // The USER's own global config is what is read — so the repository
    // value below is refused, not merely discarded along with everything.
    assert_eq!(
        configured_ssh_command(&repo).as_deref(),
        Some("/opt/user-ssh")
    );
    assert_eq!(user_git_value(&repo, "ssh.variant"), None);
    assert_eq!(user_git_value(&repo, "core.noSuchKey"), None);
    // And the command the fetch would carry names the user's program, with
    // its batch flag — never the repository's.
    assert_eq!(
        network_ssh_command(&repo),
        "/opt/user-ssh -o BatchMode=yes",
        "the cache entry's own config reached the fetch"
    );
}

#[test]
fn remote_source_parse_derives_one_key_per_repository_identity() {
    let root = tmpdir("remote-parse");
    let home = root.join("home");
    crate::test_util::with_home_and_config(&home, &home.join(".config"), || {
        let cache_root = home.join(".vstack").join("cache");
        let shorthand = RemoteSource::parse("Owner/Repo").unwrap().unwrap();
        // Built from the canonical slug, never the raw spelling.
        assert_eq!(shorthand.git_url, "https://github.com/owner/repo.git");
        assert!(
            shorthand.cache_key.starts_with("owner_repo-"),
            "{}",
            shorthand.cache_key
        );
        assert_eq!(
            shorthand.cache_dir,
            cache_root.join(&shorthand.cache_key),
            "the clone lives under the cache root, one component down"
        );
        assert_eq!(shorthand.display, "Owner/Repo");

        // A shorthand carrying `.git` or a trailing slash names the same
        // repository and must not build `repo.git.git` or `repo/.git`.
        for spelling in ["Owner/Repo.git", "owner/repo/"] {
            let remote = RemoteSource::parse(spelling).unwrap().unwrap();
            assert_eq!(remote.git_url, shorthand.git_url, "{spelling}");
            assert_eq!(remote.cache_key, shorthand.cache_key, "{spelling}");
        }

        // Every spelling of the same GitHub repo shares the clone —
        // including a mixed-case HOST, which a case-sensitive prefix match
        // read as some other forge and gave a second clone of its own.
        for spelling in [
            "https://github.com/owner/repo.git",
            "https://github.com/Owner/Repo",
            "https://GitHub.com/Owner/Repo.git",
            "git@github.com:owner/repo.git",
            "git@GitHub.com:Owner/Repo.git",
            "ssh://git@github.com/owner/repo.git",
            "ssh://git@GitHub.COM/Owner/Repo.git",
            "git+ssh://git@github.com/owner/repo.git",
        ] {
            let remote = RemoteSource::parse(spelling).unwrap().unwrap();
            assert_eq!(remote.cache_key, shorthand.cache_key, "{spelling}");
        }
        assert_eq!(
            RemoteSource::parse("git+ssh://git@github.com/owner/repo.git")
                .unwrap()
                .unwrap()
                .git_url,
            "ssh://git@github.com/owner/repo.git"
        );

        // Another host never shares a key with GitHub, and two hosts never
        // share one with each other.
        let gitlab = RemoteSource::parse("https://gitlab.com/owner/repo.git")
            .unwrap()
            .unwrap();
        assert!(
            gitlab.cache_key.starts_with("https_gitlab_com_owner_repo-"),
            "{}",
            gitlab.cache_key
        );
        let gitea = RemoteSource::parse("ssh://git@gitea.example.org:2222/owner/repo.git")
            .unwrap()
            .unwrap();
        assert_ne!(gitea.cache_key, gitlab.cache_key);
        assert_ne!(gitea.cache_key, shorthand.cache_key);

        // Not remote-shaped.
        for local in ["/abs/path", "./vendor", "../vstack", "name", "", "~/x"] {
            assert_eq!(RemoteSource::parse(local).unwrap(), None, "{local}");
        }
    });
    let _ = std::fs::remove_dir_all(root);
}

/// On a non-GitHub host the account selects the repository: an scp-like
/// path is resolved relative to that account's home, so `alice@host:repo`
/// and `bob@host:repo` are two repositories. Sharing a cache entry between
/// them also passed the origin check, so the second source installed the
/// first's content.
#[test]
fn two_ssh_accounts_on_one_host_never_share_a_cache_entry() {
    let root = tmpdir("ssh-account-identity");
    let home = root.join("home");
    crate::test_util::with_home_and_config(&home, &home.join(".config"), || {
        let key = |source: &str| RemoteSource::parse(source).unwrap().unwrap().cache_key;
        for (alice, bob) in [
            ("alice@host.example:repo.git", "bob@host.example:repo.git"),
            (
                "ssh://alice@host.example/repo.git",
                "ssh://bob@host.example/repo.git",
            ),
        ] {
            assert_ne!(key(alice), key(bob), "{alice} vs {bob}");
        }
        // And the origin check asks the same question, so bob's source
        // cannot adopt alice's clone.
        assert_ne!(
            remote_identity("ssh://alice@host.example/repo.git"),
            remote_identity("ssh://bob@host.example/repo.git")
        );
        // GitHub stays the exception it always was: one repository reached
        // over two transports is one cache entry.
        assert_eq!(
            key("git@github.com:owner/repo.git"),
            key("https://github.com/owner/repo.git")
        );
    });
    let _ = std::fs::remove_dir_all(root);
}

/// Nothing says an arbitrary host serves the same tree at one path over https
/// and over ssh, so the transport is part of a non-GitHub identity too — while
/// the three spellings of ONE transport stay one entry.
#[test]
fn a_non_github_hosts_transports_never_share_a_cache_entry() {
    let root = tmpdir("transport-identity");
    let home = root.join("home");
    crate::test_util::with_home_and_config(&home, &home.join(".config"), || {
        let key = |source: &str| RemoteSource::parse(source).unwrap().unwrap().cache_key;
        assert_ne!(
            key("https://host.example/owner/repo.git"),
            key("ssh://host.example/owner/repo.git")
        );
        assert_ne!(
            key("https://host.example/owner/repo.git"),
            key("git@host.example:owner/repo.git")
        );
        // One transport, three spellings, one entry.
        let ssh = key("ssh://git@host.example/owner/repo.git");
        assert_eq!(key("git@host.example:owner/repo.git"), ssh);
        assert_eq!(key("git+ssh://git@host.example/owner/repo.git"), ssh);
        // And GitHub is still the documented exception.
        assert_eq!(
            key("git@github.com:owner/repo.git"),
            key("https://github.com/owner/repo.git")
        );
    });
    let _ = std::fs::remove_dir_all(root);
}

/// A cache key is one filesystem name, and a `file://` or self-hosted source
/// may carry an arbitrarily deep path. Past the common 255-byte limit
/// `git clone` fails on a source that is perfectly valid.
#[test]
fn a_deep_source_path_still_fits_one_filesystem_name() {
    let root = tmpdir("long-key");
    let home = root.join("home");
    crate::test_util::with_home_and_config(&home, &home.join(".config"), || {
        let deep = "seg".repeat(40);
        let key = |source: &str| RemoteSource::parse(source).unwrap().unwrap().cache_key;
        let long = key(&format!("https://host.example/{deep}/{deep}/repo.git"));
        assert!(long.len() <= 255, "{} bytes: {long}", long.len());
        // The digest is what keeps two repositories apart, so it survives the
        // bound: two sources sharing a truncated prefix still differ.
        assert_ne!(
            long,
            key(&format!("https://host.example/{deep}/{deep}/other.git"))
        );
    });
    let _ = std::fs::remove_dir_all(root);
}

/// The readable half of a cache key lowercases and collapses runs, so it
/// alone puts distinct repositories in one directory — and whichever
/// source populated it first would then decide what every later one
/// installs.
#[test]
fn distinct_repositories_never_share_a_cache_key() {
    let root = tmpdir("distinct-keys");
    let home = root.join("home");
    crate::test_util::with_home_and_config(&home, &home.join(".config"), || {
        let key = |source: &str| {
            RemoteSource::parse(source)
                .unwrap_or_else(|err| panic!("{source}: {err}"))
                .unwrap_or_else(|| panic!("{source} is not remote-shaped"))
                .cache_key
        };
        for (a, b) in [
            // Collapsing `_` and `/` alike.
            ("foo/bar_baz", "foo_bar/baz"),
            ("https://gitea.example/a/b_c", "https://gitea.example/a_b/c"),
            ("https://gitea.example/a.b/c", "https://gitea.example/a_b/c"),
            // Case is part of a path everywhere but GitHub.
            (
                "https://gitea.example/Owner/repo",
                "https://gitea.example/owner/repo",
            ),
        ] {
            let (ka, kb) = (key(a), key(b));
            assert_eq!(
                ka.rsplit_once('-').unwrap().0,
                kb.rsplit_once('-').unwrap().0,
                "{a} vs {b}: the readable prefixes must collide, or this pair proves nothing"
            );
            assert_ne!(ka, kb, "{a} vs {b}");
        }
        // Spellings of one repository still share theirs.
        for spelling in ["owner/repo.git", "owner/repo/", "Owner/Repo"] {
            assert_eq!(key(spelling), key("owner/repo"), "{spelling}");
        }
    });
    let _ = std::fs::remove_dir_all(root);
}

/// A remote-shaped source that git must not be handed is refused at parse,
/// before any process sees it — and stays a source, so no entry of its own
/// is quietly reinstalled from somewhere else.
#[test]
fn remote_sources_git_must_not_be_handed_are_refused_at_parse() {
    // The secret each case carries, where it carries one — bound per case
    // so the leak assertion cannot pass on a string that never held it.
    for (source, secret) in [
        // git reads a leading `-` as an option, not a repository.
        ("--upload-pack=evil@host:repo.git", None),
        // A malformed authority stops userinfo parsing, and the secret
        // then reaches git and every diagnostic unredacted.
        (
            "https://user:to ken@github.com/owner/repo.git",
            Some("to ken"),
        ),
        (
            "https://user:to\tken@github.com/owner/repo.git",
            Some("to\tken"),
        ),
    ] {
        let err = RemoteSource::parse(source).unwrap_err().to_string();
        if let Some(secret) = secret {
            assert!(source.contains(secret), "{source}: fixture");
            assert!(!err.contains(secret), "{source}: {err}");
            assert!(!err.contains("ken"), "{source}: {err}");
            // The whole authority is redacted for display even when it is
            // malformed, so no diagnostic can carry the secret.
            assert!(!remote_source_display(source).contains("ken"), "{source}");
        }
        assert!(looks_like_remote_source(source), "{source}");
        assert!(recorded_source_exists(source), "{source}");
    }
    // A bare local source starting with `-` is not remote-shaped at all:
    // the shape gate runs before the leading-dash refusal, so such a
    // directory is never reported as a refused remote.
    assert_eq!(RemoteSource::parse("-my-source-dir").unwrap(), None);
    assert!(!looks_like_remote_source("-my-source-dir"));
    assert!(!recorded_source_exists("-my-source-dir"));
}

#[test]
fn clone_never_lets_a_url_be_read_as_an_option() {
    let root = tmpdir("clone-args");
    let home = root.join("home");
    crate::test_util::with_home_and_config(&home, &home.join(".config"), || {
        let remote = remote_at(
            &remote_cache_root().join("owner_repo"),
            &root.join("origin"),
        );
        let args: Vec<String> = cache_clone_command(&remote, &remote.cache_dir)
            .unwrap()
            .get_args()
            .map(|arg| arg.to_string_lossy().into_owned())
            .collect();
        let end_of_options = args.iter().position(|arg| arg == "--").expect("`--`");
        assert!(
            args[end_of_options + 1..].contains(&remote.git_url),
            "{args:?}"
        );
    });
    let _ = std::fs::remove_dir_all(root);
}

#[test]
fn remote_source_cache_keys_are_always_one_safe_path_component() {
    let root = tmpdir("remote-keys");
    let home = root.join("home");
    crate::test_util::with_home_and_config(&home, &home.join(".config"), || {
        for source in [
            "a/..",
            "../x/y",
            "https://host/../..",
            "https://host/a/../b.git",
            "https://host/%2e%2e/x",
            "git@host:../x",
            "https://host/a\\b/c",
            "https://host//",
            "https://Ünïcode.example/o/r",
        ] {
            let Ok(Some(remote)) = RemoteSource::parse(source) else {
                continue;
            };
            let key = &remote.cache_key;
            assert!(!key.is_empty(), "{source}");
            assert!(!key.contains('/') && !key.contains('\\'), "{source}: {key}");
            assert!(key != "." && key != "..", "{source}: {key}");
            assert!(
                key.chars().all(|ch| ch.is_ascii_lowercase()
                    || ch.is_ascii_digit()
                    || matches!(ch, '_' | '-')),
                "{source}: {key}"
            );
            assert_eq!(
                remote.cache_dir.parent(),
                Some(remote_cache_root().as_path()),
                "{source}"
            );
        }
    });
    let _ = std::fs::remove_dir_all(root);
}

#[test]
fn remote_source_parse_refuses_credentials_and_plaintext_before_any_git_runs() {
    for source in [
        "https://token@github.com/Owner/Repo.git",
        "HTTPS://token@github.com/Owner/Repo.git",
        "https://user:token@github.com/Owner/Repo.git",
        "ssh://git:token@github.com/Owner/Repo.git",
        "git+ssh://git:token@github.com/Owner/Repo.git",
        "https://github.com/Owner/Repo.git?access_token=token",
        "https://github.com/Owner/Repo.git#token",
        "https://token@evil.example/Owner/Repo.git?k=token",
    ] {
        let err = RemoteSource::parse(source).unwrap_err().to_string();
        assert!(!err.contains("token"), "{source}: {err}");
        assert!(err.contains("<redacted>"), "{source}: {err}");
        assert!(looks_like_remote_source(source), "{source}");
    }
    let err = RemoteSource::parse("http://github.com/Owner/Repo.git")
        .unwrap_err()
        .to_string();
    assert!(err.contains("plaintext HTTP"), "{err}");

    // Legitimate usernames and shorthand are kept.
    for source in [
        "https://github.com/Owner/Repo.git",
        "ssh://git@github.com/Owner/Repo.git",
        "git+ssh://git@github.com/Owner/Repo.git",
        "git@github.com:Owner/Repo.git",
        "Owner/Repo",
    ] {
        RemoteSource::parse(source).unwrap_or_else(|err| panic!("{source}: {err}"));
    }
    assert_eq!(
        remote_source_display("https://user:token@github.com/Owner/Repo.git?k=secret"),
        "https://user:<redacted>@github.com/Owner/Repo.git?<redacted>"
    );
    assert_eq!(
        remote_source_display("ssh://git@github.com/Owner/Repo.git"),
        "ssh://git@github.com/Owner/Repo.git"
    );
    assert_eq!(remote_source_display("Owner/Repo"), "Owner/Repo");
}

/// The bare `owner/repo` shorthand is not URL-shaped, so it never reaches
/// the credential refusal: a query pasted onto it was carried straight into
/// the `https://github.com/{slug}.git` this builds, handing the secret to
/// `git clone`. Reserved URL characters are therefore not repository-name
/// characters.
#[test]
fn a_shorthand_carrying_a_query_never_becomes_a_github_url() {
    for source in [
        "owner/repo?access_token=ghp_SECRET.git",
        "owner/repo#ghp_SECRET",
        "owner/repo:ghp_SECRET",
        "owner/repo%2Fghp_SECRET",
    ] {
        assert_eq!(
            crate::config::parse_github_slug(source),
            None,
            "{source} still parses as a GitHub repository"
        );
        // No URL is built for it at all, so no process is handed one.
        assert_eq!(
            RemoteSource::parse(source).unwrap(),
            None,
            "{source} still became a remote source"
        );
        assert!(!looks_like_remote_source(source), "{source}");
    }
    // And the diagnostic that then names it as a missing local source does
    // not print what a query or fragment carries.
    for source in [
        "owner/repo?access_token=ghp_SECRET.git",
        "owner/repo#ghp_SECRET",
    ] {
        let reason = absent_source_reason(source);
        assert!(!reason.contains("ghp_SECRET"), "{source}: {reason}");
    }
    // The shapes GitHub really uses are untouched.
    for source in ["owner/repo", "Owner/Repo.git", "my-org/my_repo.v2"] {
        assert!(
            crate::config::parse_github_slug(source).is_some(),
            "{source}"
        );
    }
}

/// A recorded source is arbitrary text, so no single delimiter separates it
/// from a message: two distinct pairs concatenated with one collapse to the
/// same string, and one source's refusal then silently suppressed another's.
#[test]
fn one_sources_warning_cannot_suppress_another_sources() {
    // Distinct pairs whose concatenation under ANY one delimiter matches.
    let first = ("warn-dedup-test-a\u{1}shared", "tail");
    let second = ("warn-dedup-test-a", "shared\u{1}tail");

    assert!(warn_once_is_new(first.0, first.1));
    assert!(
        warn_once_is_new(second.0, second.1),
        "a second source's warning was suppressed by an unrelated one"
    );
    // A genuine repeat is still printed once.
    assert!(!warn_once_is_new(first.0, first.1));
    assert!(!warn_once_is_new(second.0, second.1));
}

/// A credential URL malformed enough to evade `parse_remote_url` is
/// classified as a local path, and that fallback used to print it
/// verbatim — so `check`, `verify` and `refresh` leaked legacy lock-file
/// secrets to their logs.
#[test]
fn a_malformed_credential_source_is_redacted_when_reported_missing() {
    for source in [
        "https:/user:ghp_SECRET@github.com/owner/repo",
        "user:ghp_SECRET@github.com/owner/repo",
        "/srv/user:ghp_SECRET@host/repo",
    ] {
        let reason = absent_source_reason(source);
        assert!(!reason.contains("ghp_SECRET"), "{source}: {reason}");
        assert!(reason.contains("<redacted>"), "{source}: {reason}");
    }
    // A plain missing path is still named in full.
    assert_eq!(
        absent_source_reason("/srv/vstack"),
        "source not found: /srv/vstack"
    );
}

/// The restoration command is meant to be PASTED, so the source arrives in it
/// as a shell word. `RemoteSource` accepts a URL whose path carries shell
/// syntax, and interpolating its display form handed the reader a command that
/// ran the substitution instead of naming the repository.
#[test]
fn a_restoration_command_passes_its_source_literally() {
    let hostile = "https://host.example/team/$(id).git";
    let reason = absent_source_reason(hostile);
    assert!(
        looks_like_remote_source(hostile),
        "the fixture must take the remote branch"
    );
    assert!(
        reason.contains(&format!("`vstack add '{hostile}'`")),
        "the argument must be single-quoted and inert: {reason}"
    );
    // And it really is one inert argument to a real shell.
    let arg = crate::display::command_arg(hostile);
    let out = std::process::Command::new("sh")
        .arg("-c")
        .arg(format!("printf '%s' {arg}"))
        .output()
        .expect("sh runs");
    assert_eq!(String::from_utf8_lossy(&out.stdout), hostile);

    // Control: the same source's PROSE mention is still scrubbed, and long
    // prose still truncates while the command never does.
    let long = format!("https://host.example/team/{}.git", "a".repeat(400));
    assert!(
        crate::display::display_text(&long).ends_with('…'),
        "prose truncates"
    );
    assert!(
        absent_source_reason(&long).contains(&long),
        "a command argument is never elided"
    );

    // Control: an ordinary source renders unquoted, exactly as before.
    assert_eq!(
        absent_source_reason("https://github.com/owner/repo"),
        "remote cache not present — run `vstack add https://github.com/owner/repo`"
    );
}

/// A remembered source that opens with a scheme is an attempt at a URL, so it
/// names something the chain must not walk past — even when it is malformed
/// enough that the strict parser cannot read it, which is exactly when
/// `looks_like_remote_source` says no.
#[test]
fn a_malformed_url_still_names_a_transport() {
    for source in [
        "https:/user:ghp_SECRET@host.example/owner/repo",
        "https:///ghp_SECRET@host.example/owner/repo",
        "ssh:/git@host.example/owner/repo",
        "git://host.example/owner/repo",
    ] {
        assert!(names_a_transport(source), "{source}");
    }
    // A path names no transport, whatever it contains — a Windows drive letter
    // is not a scheme, and `:` is an ordinary character in a POSIX path, so a
    // missing local directory stays a local candidate that names nothing.
    for source in [
        "/srv/checkouts/repo",
        "./vendor",
        "../vstack",
        "name",
        "",
        "C:/src/vstack",
        "owner/repo",
        "foo:bar",
        "notes:2026/vstack",
    ] {
        assert!(!names_a_transport(source), "{source}");
    }
}

/// A cache entry's `.git/hooks/` is a directory of programs git runs on its own
/// behalf, and no check on the entry's config or location sees it: a fetch runs
/// `reference-transaction` for every ref it writes.
#[cfg(unix)]
#[test]
fn a_cache_entrys_own_git_hooks_never_run() {
    let root = tmpdir("cache-hooks");
    let origin = root.join("origin");
    init_git_repo(&origin);
    let cache = root.join("cache").join("owner_repo");
    clone_into(&origin, &cache);
    std::fs::write(origin.join("README.md"), "newer\n").unwrap();
    git(&origin, &["commit", "-q", "-am", "update"]);

    let marker = root.join("hook-ran");
    for hook in ["reference-transaction", "post-checkout"] {
        write_marker_program(&cache.join(".git/hooks").join(hook), &marker);
    }

    // Control: an unhardened fetch in this entry really does run the hook. Not
    // asserted for success — running it is the point, and this hook aborts the
    // ref transaction, which is exactly what a planted one can do.
    let mut control = std::process::Command::new("git");
    for key in GIT_INHERITED_ENV_VARS.iter().chain(GIT_CACHE_ONLY_ENV_VARS) {
        control.env_remove(key);
    }
    let _ = control
        .args(["fetch", "origin", "--quiet"])
        .current_dir(&cache)
        .output()
        .unwrap();
    assert!(
        marker.exists(),
        "the fixture must reproduce the execution for the assertion below to mean anything"
    );
    std::fs::remove_file(&marker).unwrap();
    // And the entry is otherwise entirely ordinary: nothing else refuses it.
    ensure_cache_entry_is_owned(&remote_at(&cache, &origin)).unwrap();

    drop(update_cached_repo(&remote_at(&cache, &origin)).unwrap());

    assert!(!marker.exists(), "the cache entry's own git hook ran");
    // The hooks path is a regular FILE, so no `<hooksPath>/<name>` resolves on
    // any platform — a path that merely does not exist can be created by
    // whoever can write the cache root.
    let hooks_path = no_hooks_path().unwrap();
    assert!(hooks_path.is_file(), "{}", hooks_path.display());
    // The update still did its work.
    assert_eq!(
        std::fs::read_to_string(cache.join("README.md")).unwrap(),
        "newer\n"
    );
}

/// The revision an update installs is a fact about the SOURCE. An entry's
/// stored `remote.origin.fetch` and its `origin/HEAD` are values inside the
/// entry: a refspec mapping another branch onto `origin/main` passed every
/// name-based check and had its content installed.
#[test]
fn an_update_takes_its_revision_from_the_remote_not_from_the_entry() {
    let root = tmpdir("refspec-tamper");
    let origin = root.join("origin");
    init_git_repo(&origin);
    git(&origin, &["checkout", "-q", "-b", "other"]);
    std::fs::write(origin.join("README.md"), "other branch\n").unwrap();
    git(&origin, &["commit", "-q", "-am", "other"]);
    git(&origin, &["checkout", "-q", "main"]);
    let cache = root.join("cache").join("owner_repo");
    clone_into(&origin, &cache);
    std::fs::write(origin.join("README.md"), "newer\n").unwrap();
    git(&origin, &["commit", "-q", "-am", "update"]);

    // Both values an entry could carry, pointed at the other branch.
    git(
        &cache,
        &[
            "config",
            "remote.origin.fetch",
            "+refs/heads/other:refs/remotes/origin/main",
        ],
    );
    git(
        &cache,
        &[
            "symbolic-ref",
            "refs/remotes/origin/HEAD",
            "refs/remotes/origin/main",
        ],
    );

    drop(update_cached_repo(&remote_at(&cache, &origin)).unwrap());

    assert_eq!(
        std::fs::read_to_string(cache.join("README.md")).unwrap(),
        "newer\n",
        "the entry chose which revision it was updated to"
    );
    let _ = std::fs::remove_dir_all(root);
}

/// URL schemes are case-insensitive and the transport checks read them that
/// way; git does not — it reads `SSH://` as a request for a `git-remote-SSH`
/// helper and fails to clone.
#[test]
fn an_uppercase_scheme_reaches_git_in_the_spelling_git_knows() {
    let root = tmpdir("scheme-case");
    let home = root.join("home");
    crate::test_util::with_home_and_config(&home, &home.join(".config"), || {
        for (source, expected) in [
            (
                "SSH://git@host.example/owner/repo.git",
                "ssh://git@host.example/owner/repo.git",
            ),
            (
                "GIT+SSH://git@host.example/owner/repo.git",
                "ssh://git@host.example/owner/repo.git",
            ),
            (
                "git+ssh://git@host.example/owner/repo.git",
                "ssh://git@host.example/owner/repo.git",
            ),
            (
                "HTTPS://host.example/owner/repo.git",
                "https://host.example/owner/repo.git",
            ),
            (
                "https://host.example/owner/repo.git",
                "https://host.example/owner/repo.git",
            ),
        ] {
            assert_eq!(
                RemoteSource::parse(source).unwrap().unwrap().git_url,
                expected,
                "{source}"
            );
        }
        // Case is a spelling, not an identity: one repository, one entry.
        let key = |source: &str| RemoteSource::parse(source).unwrap().unwrap().cache_key;
        assert_eq!(
            key("SSH://git@host.example/owner/repo.git"),
            key("ssh://git@host.example/owner/repo.git")
        );
    });
    let _ = std::fs::remove_dir_all(root);
}

/// The disabled-hooks sentinel is what keeps a cache command from running the
/// entry's own hooks, so a directory in its place is not something to work
/// around: every cache command refuses to run at all.
#[test]
fn a_directory_at_the_disabled_hooks_path_refuses_every_cache_command() {
    let root = tmpdir("no-hooks-directory");
    let home = root.join("home");
    crate::test_util::with_home_and_config(&home, &home.join(".config"), || {
        // The ordinary case first, so the refusal below is the planted
        // directory and not a missing cache root.
        let path = no_hooks_path().unwrap();
        assert!(path.is_file());

        std::fs::remove_file(&path).unwrap();
        std::fs::create_dir_all(path.join("hooks-would-live-here")).unwrap();

        let err = no_hooks_path().unwrap_err().to_string();
        assert!(err.contains("must be a regular file"), "{err}");
        // And no cache command is built while that is true.
        let origin = root.join("origin");
        init_git_repo(&origin);
        let remote = RemoteSource::parse("owner/repo").unwrap().unwrap();
        clone_into(&origin, &remote.cache_dir);
        let err = update_cached_repo(&remote).unwrap_err().to_string();
        assert!(err.contains("must be a regular file"), "{err}");
    });
    let _ = std::fs::remove_dir_all(root);
}

/// A bare `user@host` is an ssh remote's spelling and a token-only
/// credential's spelling both. Which one it is comes from the transport, not
/// from the punctuation: a hostless `https:///TOKEN@host/repo` is refused, and
/// the refusal prints it.
#[test]
fn a_token_only_userinfo_is_redacted_wherever_the_transport_is_not_ssh() {
    for source in [
        "https:///ghp_SECRET@host.example/owner/repo",
        "https://ghp_SECRET@host.example/owner/repo",
        "https:/ghp_SECRET@host.example/owner/repo",
    ] {
        let shown = remote_source_display(source);
        assert!(!shown.contains("ghp_SECRET"), "{source}: {shown}");
        assert!(shown.contains("<redacted>"), "{source}: {shown}");
        assert!(
            !absent_source_reason(source).contains("ghp_SECRET"),
            "{source}"
        );
    }
    // An ssh remote's username is not a secret and is kept in every spelling,
    // as is a local path that merely contains an `@`.
    for source in [
        "ssh://git@host.example/owner/repo.git",
        "git+ssh://git@host.example/owner/repo.git",
        "git@host.example:owner/repo.git",
        "/srv/checkouts/git@host/repo",
    ] {
        assert_eq!(remote_source_display(source), source, "{source}");
    }
}

/// The scp-like spelling is the same grammar with different punctuation,
/// and it used to be parsed by different code: a `user:secret@host:path`
/// source had no authority by one splitter and no userinfo by another, so
/// its secret was neither refused nor redacted and became a cache
/// directory name.
#[test]
fn scp_like_sources_are_refused_and_redacted_like_any_other_url() {
    for source in [
        "user:ghp_SECRET@github.com:owner/repo.git",
        "u:ghp_SECRET@host:owner/repo.git",
        "git:ghp_SECRET@github.com:owner/repo.git",
    ] {
        let err = RemoteSource::parse(source).unwrap_err().to_string();
        assert!(!err.contains("ghp_SECRET"), "{source}: {err}");
        assert!(err.contains("<redacted>"), "{source}: {err}");
        assert!(
            !remote_source_display(source).contains("ghp_SECRET"),
            "{source}"
        );
        assert!(looks_like_remote_source(source), "{source}");
    }
    // Whitespace and control characters inside the userinfo are caught by
    // the authority guard, which used to inspect an empty string here.
    let err = RemoteSource::parse("u:tok\nen@host:owner/repo.git")
        .unwrap_err()
        .to_string();
    assert!(!err.contains("tok"), "{err}");
    // A credential-free whitespace source: the credential check cannot
    // stand in for the authority guard, so this is what proves it fires.
    let err = RemoteSource::parse("https://git hub.com/owner/repo.git")
        .unwrap_err()
        .to_string();
    assert!(err.contains("whitespace or control characters"), "{err}");
    // And a control character that is NOT whitespace, which every other
    // input here is: `\t` and `\n` are both, so they prove only half the
    // guard.
    for control in ['\u{1}', '\u{7f}'] {
        let source = format!("https://git{control}hub.com/owner/repo.git");
        let err = RemoteSource::parse(&source).unwrap_err().to_string();
        assert!(
            err.contains("whitespace or control characters"),
            "{control:?}: {err}"
        );
        assert!(!err.contains(control), "{control:?}: {err}");
    }
    // The ssh username every scp remote carries is still kept.
    let remote = RemoteSource::parse("git@github.com:Owner/Repo.git")
        .unwrap()
        .unwrap();
    assert_eq!(remote.display, "git@github.com:Owner/Repo.git");
}

/// A lock file records source strings verbatim, so a refusal or warning
/// that echoed one would put its terminal escapes on vstack's own stderr
/// with no cache entry and no network involved.
#[test]
fn control_characters_never_reach_a_diagnostic() {
    let escaped = remote_source_display("git@github.com:owner/re\u{1b}[31mpo.git");
    assert!(!escaped.contains('\u{1b}'), "{escaped}");
    assert!(escaped.contains("\\u{1b}"), "{escaped}");
    let err = RemoteSource::parse("-\u{1b}[31m@github.com:owner/repo.git")
        .unwrap_err()
        .to_string();
    assert!(!err.contains('\u{1b}'), "{err}");
    // A direction override reads as part of the surrounding line, so it is
    // escaped too.
    assert!(!remote_source_display("owner/re\u{202e}po").contains('\u{202e}'));
}

/// A URL git must not be handed is refused before a process sees it, and
/// the refusal cannot be the place the credential appears.
#[test]
fn unsupported_transports_and_hostless_urls_are_refused_before_git_runs() {
    // An empty authority puts the credential in the PATH, where neither the
    // authority redaction nor the credential refusal could see it: git was
    // handed the token and every diagnostic echoed it.
    let err = RemoteSource::parse("https:///user:ghp_LEAKTEST@host/repo")
        .unwrap_err()
        .to_string();
    assert!(!err.contains("ghp_LEAKTEST"), "{err}");
    assert!(err.contains("<redacted>"), "{err}");
    assert!(err.contains("names no host"), "{err}");
    assert!(
        !remote_source_display("https:///user:ghp_LEAKTEST@host/repo").contains("ghp_LEAKTEST")
    );

    for source in [
        "https:///owner/repo",
        "ssh:///owner/repo.git",
        "git@:owner/repo.git",
    ] {
        let err = RemoteSource::parse(source).unwrap_err().to_string();
        assert!(err.contains("names no host"), "{source}: {err}");
    }

    // `git://` is unauthenticated and unencrypted; an unknown scheme makes
    // git run a `git-remote-<scheme>` helper.
    for source in [
        "git://github.com/owner/repo",
        "ftp://host/owner/repo.git",
        "weird://host/owner/repo",
    ] {
        let err = RemoteSource::parse(source).unwrap_err().to_string();
        assert!(err.contains("transport"), "{source}: {err}");
        assert!(looks_like_remote_source(source), "{source}");
        assert!(recorded_source_exists(source), "{source}");
    }

    // The supported transports, in every spelling, still parse.
    for source in [
        "https://github.com/Owner/Repo.git",
        "ssh://git@github.com/Owner/Repo.git",
        "git+ssh://git@github.com/Owner/Repo.git",
        "git@github.com:Owner/Repo.git",
        "file:///srv/mirror/repo.git",
        "Owner/Repo",
    ] {
        RemoteSource::parse(source).unwrap_or_else(|err| panic!("{source}: {err}"));
    }
}

/// An entry minted before the transport policy can hold an origin vstack
/// would refuse as a source; fetching it pulls this source's content over
/// that transport anyway.
#[test]
fn a_cache_entry_whose_origin_uses_an_unsupported_transport_is_refused() {
    let root = tmpdir("origin-transport");
    let origin = root.join("origin");
    init_git_repo(&origin);
    let home = root.join("home");

    crate::test_util::with_home_and_config(&home, &home.join(".config"), || {
        let remote = RemoteSource::parse("owner/repo").unwrap().unwrap();
        clone_into(&origin, &remote.cache_dir);
        // Control: an https origin for the same repository is accepted.
        git(
            &remote.cache_dir,
            &["remote", "set-url", "origin", &remote.git_url],
        );
        ensure_cache_entry_is_owned(&remote).unwrap();

        git(
            &remote.cache_dir,
            &[
                "remote",
                "set-url",
                "origin",
                "git://github.com/owner/repo.git",
            ],
        );
        let err = ensure_cache_entry_is_owned(&remote)
            .unwrap_err()
            .to_string();
        assert!(err.contains("its origin is unusable"), "{err}");
        assert!(err.contains("transport"), "{err}");
        // And the update refuses before fetching over it.
        let err = update_cached_repo(&remote).unwrap_err().to_string();
        assert!(err.contains("its origin is unusable"), "{err}");
    });
    let _ = std::fs::remove_dir_all(root);
}

#[test]
fn git_output_summary_redacts_query_tokens_and_userinfo_in_urls() {
    let output = std::process::Output {
        status: std::process::ExitStatus::default(),
        stdout: Vec::new(),
        stderr: b"fatal: unable to access 'https://x@github.com/o/r.git?access_token=secret/': 403\nhint: see https://docs.example/help#anchor".to_vec(),
    };
    let summary = git_output_summary(&output);
    assert!(!summary.contains("secret"), "{summary}");
    assert!(!summary.contains("x@"), "{summary}");
    assert!(summary.contains("fatal: unable to access"), "{summary}");
    assert!(
        summary.contains("'https://<redacted>@github.com/o/r.git?<redacted>':"),
        "{summary}"
    );
    // A fragment is redacted; the surrounding prose is untouched.
    assert!(
        summary.contains("hint: see https://docs.example/help#<redacted>"),
        "{summary}"
    );
}

/// Every git failure this module reports runs its output through
/// `redact_token`. A repository or path name whose last character before a
/// trailing quote is multi-byte turned that handled error into a panic.
#[test]
fn redaction_survives_multi_byte_characters_at_a_url_boundary() {
    for token in [
        "'https://github.com/owner/rep\u{00f6}'",
        "https://github.com/owner/rep\u{00f6}",
        "\u{00e9}",
        "'https://github.com/o/r.git':",
    ] {
        let redacted = redact_token(token);
        assert!(!redacted.is_empty(), "{token}");
    }
    assert_eq!(
        redact_token("'https://user:tok@github.com/owner/rep\u{00f6}'"),
        "'https://user:<redacted>@github.com/owner/rep\u{00f6}'"
    );
}

/// Git prints the remote it failed on verbatim, and the scp-like spelling
/// carries its secret where no `://` appears — so a summary gated on that
/// separator leaked the token to stderr.
#[test]
fn git_output_summary_redacts_an_scp_like_remote() {
    let output = std::process::Output {
        status: std::process::ExitStatus::default(),
        stdout: Vec::new(),
        stderr: b"fatal: could not read from 'user:ghp_SECRET@host.example:owner/repo.git'\n"
            .to_vec(),
    };

    let summary = git_output_summary(&output);

    assert!(!summary.contains("ghp_SECRET"), "{summary}");
    assert!(
        summary.contains("'user:<redacted>@host.example:owner/repo.git'"),
        "{summary}"
    );
    assert!(summary.contains("fatal: could not read from"), "{summary}");
    // Prose that merely carries a colon is not a remote and is untouched.
    for token in ["fatal:", "error:", "2026-08-16T04:51:03Z", "a:b"] {
        assert_eq!(redact_token(token), token, "{token}");
    }
}

/// `git clone` follows a symlink at its destination, so the clone path had
/// to prove the entry is vstack's own directory before running git — every
/// other write path already does.
#[cfg(unix)]
#[test]
fn clone_refuses_a_cache_entry_that_is_not_an_empty_directory_of_its_own() {
    let root = tmpdir("clone-destination");
    let origin = root.join("origin");
    init_git_repo(&origin);
    let outside = root.join("user-checkout");
    std::fs::create_dir_all(&outside).unwrap();
    std::fs::write(outside.join("precious.txt"), "precious\n").unwrap();
    let home = root.join("home");

    crate::test_util::with_home_and_config(&home, &home.join(".config"), || {
        let remote = remote_at(&remote_cache_root().join("owner_repo"), &origin);
        std::fs::create_dir_all(remote.cache_dir.parent().unwrap()).unwrap();
        std::os::unix::fs::symlink(&outside, &remote.cache_dir).unwrap();

        let err = clone_cached_repo(&remote).unwrap_err().to_string();
        assert!(
            err.contains("not a directory vstack can clone into"),
            "{err}"
        );
        assert!(
            !outside.join(".git").exists(),
            "the clone was written into the link target"
        );
        assert_eq!(
            std::fs::read_to_string(outside.join("precious.txt")).unwrap(),
            "precious\n"
        );
        std::fs::remove_file(&remote.cache_dir).unwrap();

        // A directory holding someone else's files is refused too; an
        // empty one is what a fresh clone lands in.
        std::fs::create_dir_all(&remote.cache_dir).unwrap();
        std::fs::write(remote.cache_dir.join("stray.txt"), "x\n").unwrap();
        let err = clone_cached_repo(&remote).unwrap_err().to_string();
        assert!(err.contains("not an empty directory"), "{err}");
        std::fs::remove_file(remote.cache_dir.join("stray.txt")).unwrap();
        drop(clone_cached_repo(&remote).unwrap());
        assert!(remote.cache_dir.join(".git").is_dir());
    });
    let _ = std::fs::remove_dir_all(root);
}

#[test]
fn clone_cached_repo_makes_a_shallow_clone_in_the_cache_root() {
    let root = tmpdir("clone");
    let origin = root.join("origin");
    init_git_repo(&origin);
    std::fs::write(origin.join("README.md"), "second\n").unwrap();
    git(&origin, &["commit", "-q", "-am", "second"]);
    let home = root.join("home");
    crate::test_util::with_home_and_config(&home, &home.join(".config"), || {
        let cache = remote_cache_root().join("owner_repo");
        assert!(!cache.exists());
        drop(clone_cached_repo(&remote_at(&cache, &origin)).unwrap());
        assert_eq!(
            std::fs::read_to_string(cache.join("README.md")).unwrap(),
            "second\n"
        );
        assert_eq!(
            git_stdout(&cache, &["rev-parse", "--is-shallow-repository"]),
            "true"
        );
        // The fresh clone is owned and updatable.
        drop(update_cached_repo(&remote_at(&cache, &origin)).unwrap());
    });
    let _ = std::fs::remove_dir_all(root);
}

/// The whole-lock best-effort refresh the TUI runs at startup uses the same
/// guarded update: a redirected cache entry is refused and the victim
/// stays untouched; an owned entry is updated. Asserted directly after the
/// call, so a no-op loop body cannot pass on the strength of later calls.
#[test]
fn refresh_remote_caches_refuses_a_redirected_entry_and_updates_an_owned_one() {
    let root = tmpdir("refresh-remote-caches");
    let home = root.join("home");
    let cache_root = home.join(".vstack").join("cache");
    let fx = redirected_cache_at(&root, &cache_root.join("owner_repo"));
    // An owned entry for `other/repo` with a newer origin.
    let origin = root.join("other-origin");
    init_git_repo(&origin);
    let owned = cache_root.join("other_repo");
    clone_into(&origin, &owned);
    std::fs::write(origin.join("README.md"), "newer\n").unwrap();
    git(&origin, &["commit", "-q", "-am", "update"]);
    // The origin check runs against the recorded source, so record the
    // sources these clones really came from.
    let mut lock = config::LockFile::default();
    lock.add(lock_entry("demo", &file_url(&root.join("origin"))));
    lock.add(lock_entry("scout", &file_url(&origin)));

    crate::test_util::with_home_and_config(&home, &home.join(".config"), || {
        // Pin the fixture clones to the keys the recorded sources derive.
        let demo = RemoteSource::parse(&file_url(&root.join("origin")))
            .unwrap()
            .unwrap();
        let scout = RemoteSource::parse(&file_url(&origin)).unwrap().unwrap();
        std::fs::rename(&fx.remote.cache_dir, &demo.cache_dir).unwrap();
        std::fs::rename(&owned, &scout.cache_dir).unwrap();

        refresh_remote_caches(&lock);

        assert_eq!(
            victim_readme(&fx),
            "precious\n",
            "the redirected worktree must be untouched"
        );
        assert_eq!(
            std::fs::read_to_string(scout.cache_dir.join("README.md")).unwrap(),
            "newer\n",
            "the owned entry must be updated by refresh_remote_caches itself"
        );
    });
    let _ = std::fs::remove_dir_all(root);
}

/// A refused remote is a source that exists: no entry falls back to another
/// loaded source, and no CWD or registry fallback stands in for it.
#[test]
fn refused_remote_source_is_never_substituted() {
    let root = tmpdir("refused-no-substitute");
    let home = root.join("home");
    let other_source = make_vstack_source(&root, "other");
    std::fs::create_dir_all(other_source.join("skills/demo")).unwrap();

    crate::test_util::with_home_and_config(&home, &home.join(".config"), || {
        // Control: the test process runs inside a vstack checkout, so a
        // lock whose sole source resolves to nothing does fall back to it.
        let mut absent = config::LockFile::default();
        absent.add(lock_entry("demo", "/nowhere/at/all"));
        assert!(
            !resolve_source_records(&absent).sources.is_empty(),
            "control: the CWD fallback must be reachable for the refusal case to prove anything"
        );

        let cache = RemoteSource::parse("owner/repo")
            .unwrap()
            .unwrap()
            .cache_dir;
        let fx = redirected_cache_at(&root, &cache);

        let mut lock = config::LockFile::default();
        lock.add(lock_entry("demo", "owner/repo"));
        let records = resolve_source_records(&lock);
        assert!(records.sources.is_empty());
        assert!(
            records
                .refused
                .reason("owner/repo")
                .is_some_and(|reason| reason.contains("does not resolve to its cache entry")),
            "{:?}",
            records.refused
        );

        // With another source loaded, the refused entry does not rebind
        // to it.
        let sources = vec![RefreshSource::from_root(&other_source)];
        assert!(refresh_source_for_entry(&sources, &lock_entry("demo", "owner/repo")).is_none());
        assert_eq!(victim_readme(&fx), "precious\n");
    });
    let _ = std::fs::remove_dir_all(root);
}
