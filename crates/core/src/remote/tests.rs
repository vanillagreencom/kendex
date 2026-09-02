use std::fs;
use std::path::{Path, PathBuf};
use std::time::SystemTime;

use super::*;
use crate::env::FakeOs;
use crate::process::Hardened;

mod sync;

fn git(dir: &Path, args: &[&str]) {
    let output = Hardened::git(args, Some(dir)).run().unwrap();
    assert!(output.status.success(), "git {args:?}");
}

/// An upstream repository reachable as `owner/repo`, plus the environment
/// whose cache the store writes into.
struct Fixture {
    _tmp: tempfile::TempDir,
    env: Env,
    upstream: PathBuf,
}

const REPO: &str = "owner/repo";

fn fixture() -> Fixture {
    let tmp = tempfile::tempdir().unwrap();
    let upstream = tmp.path().join("base/owner/repo");
    fs::create_dir_all(upstream.join("skills/gh")).unwrap();
    write_skill(&upstream, "v1");
    git(&upstream, &["init", "--quiet", "-b", "main"]);
    commit(&upstream, "one");
    git(&upstream, &["tag", "release"]);
    let base = format!("file://{}", tmp.path().join("base").display());
    let env = Env::fake(tmp.path(), FakeOs::Linux).with_var("KENDEX_GIT_BASE", &base);
    Fixture {
        _tmp: tmp,
        env,
        upstream,
    }
}

fn write_skill(dir: &Path, body: &str) {
    fs::write(
        dir.join("skills/gh/SKILL.md"),
        format!("---\nname: gh\n---\n{body}\n"),
    )
    .unwrap();
}

fn head(dir: &Path) -> String {
    let output = Hardened::git(&["rev-parse", "HEAD"], Some(dir))
        .run()
        .unwrap();
    String::from_utf8_lossy(&output.stdout).trim().to_owned()
}

fn commit(dir: &Path, message: &str) -> String {
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
    head(dir)
}

fn body(root: &Path) -> String {
    fs::read_to_string(root.join("skills/gh/SKILL.md")).unwrap()
}

fn modified(root: &Path) -> SystemTime {
    fs::metadata(root.join("skills/gh/SKILL.md"))
        .unwrap()
        .modified()
        .unwrap()
}

fn key_for(env: &Env) -> String {
    store::repo_key(&clone_url(env, REPO))
}

#[test]
fn shorthand_becomes_a_github_url_and_urls_pass_through() {
    let tmp = tempfile::tempdir().unwrap();
    let env = Env::fake(tmp.path(), FakeOs::Linux);
    assert_eq!(clone_url(&env, "a/b"), "https://github.com/a/b.git");
    assert_eq!(clone_url(&env, "https://x/y.git"), "https://x/y.git");
    assert_eq!(
        clone_url(&env, "git@github.com:a/b.git"),
        "git@github.com:a/b.git"
    );
    let rebased = env.with_var("KENDEX_GIT_BASE", "file:///fixtures/");
    assert_eq!(clone_url(&rebased, "a/b"), "file:///fixtures/a/b");
    assert_eq!(clone_url(&rebased, "https://x/y.git"), "https://x/y.git");
}

/// Only a full object id promises one commit forever. An abbreviation names
/// a commit but tracks like a tag, and two hosts serving one `owner/repo`
/// never share a cache entry.
#[test]
fn a_pin_is_the_full_commit_id_and_keys_are_per_url() {
    assert!(store::is_pin(&"a".repeat(40)));
    assert!(!store::is_pin("abc1234"));
    assert!(!store::is_pin("release"));
    assert!(!store::is_pin(&"z".repeat(40)));
    assert_ne!(
        store::repo_key("file:///one/owner/repo"),
        store::repo_key("file:///two/owner/repo")
    );
}

/// The plan's test: two scopes pinning different revisions of one
/// repository each read their own bytes, and neither disturbs the other.
#[test]
fn two_pins_of_one_repo_coexist() {
    let f = fixture();
    let first = head(&f.upstream);
    write_skill(&f.upstream, "v2");
    let second = commit(&f.upstream, "two");

    let old = sync(&f.env, REPO, Some(&first)).unwrap();
    let new = sync(&f.env, REPO, Some(&second)).unwrap();
    assert_ne!(old.root, new.root);
    assert!(body(&old.root).contains("v1"));
    assert!(body(&new.root).contains("v2"));

    // Resolving the older pin again still finds the older bytes.
    assert!(body(&sync(&f.env, REPO, Some(&first)).unwrap().root).contains("v1"));
}

/// A pin the cache holds is answered without touching the network — which
/// is what makes a pinned install work on a plane.
#[test]
fn a_cached_pin_resolves_offline_and_an_uncached_one_is_a_hard_error() {
    let f = fixture();
    let pinned = head(&f.upstream);
    sync(&f.env, REPO, Some(&pinned)).unwrap();

    // A commit made after the mirror was cloned, then put out of reach.
    write_skill(&f.upstream, "v2");
    let never_fetched = commit(&f.upstream, "two");
    fs::remove_dir_all(&f.upstream).unwrap();
    let offline = sync(&f.env, REPO, Some(&pinned)).unwrap();
    assert!(body(&offline.root).contains("v1"));
    assert!(offline.warning.is_none());

    let error = sync(&f.env, REPO, Some(&never_fetched)).unwrap_err();
    let CoreError::PinUnavailable { pin, .. } = &error else {
        panic!("expected a pin error, got {error}");
    };
    assert_eq!(pin, &never_fetched);
    assert!(error.to_string().contains(&never_fetched));
}

/// A tag that moved upstream is followed on the next refresh, and the
/// commit it used to point at keeps its own directory, unchanged.
#[test]
fn a_moved_tag_re_resolves_without_disturbing_the_old_commit() {
    let f = fixture();
    let before = sync(&f.env, REPO, Some("release")).unwrap();
    assert!(body(&before.root).contains("v1"));

    write_skill(&f.upstream, "v2");
    commit(&f.upstream, "two");
    git(&f.upstream, &["tag", "-f", "release"]);

    let after = sync(&f.env, REPO, Some("release")).unwrap();
    assert_ne!(after.commit, before.commit);
    assert!(body(&after.root).contains("v2"));
    assert!(
        body(&before.root).contains("v1"),
        "the old commit's checkout must not be rewritten"
    );
}

/// No selector tracks the default branch — v0.1 behavior, now through a
/// per-commit directory instead of a checkout that is reset in place.
#[test]
fn the_default_branch_is_tracked_and_a_failed_refresh_keeps_serving() {
    let f = fixture();
    let first = sync(&f.env, REPO, None).unwrap();
    write_skill(&f.upstream, "v2");
    let second_commit = commit(&f.upstream, "two");

    let second = sync(&f.env, REPO, None).unwrap();
    assert_eq!(second.commit, second_commit);
    assert!(body(&second.root).contains("v2"));
    assert_ne!(second.root, first.root);

    // The remote vanishes: the fetch fails, the cache still answers.
    fs::remove_dir_all(&f.upstream).unwrap();
    let offline = sync(&f.env, REPO, None).unwrap();
    assert_eq!(offline.commit, second_commit);
    assert!(offline.warning.unwrap().contains("using cached version"));
    assert!(body(&offline.root).contains("v2"));
}

/// Resolving a commit that is already published rewrites nothing: same
/// directory, same bytes, same timestamps.
#[test]
fn republishing_a_commit_leaves_its_bytes_alone() {
    let f = fixture();
    let first = sync(&f.env, REPO, None).unwrap();
    let stamp = modified(&first.root);

    let again = sync(&f.env, REPO, None).unwrap();
    assert_eq!(again.root, first.root);
    assert_eq!(modified(&again.root), stamp);
    assert_eq!(
        cached(&f.env, REPO, None).unwrap().unwrap().root,
        first.root
    );
    assert_eq!(modified(&first.root), stamp);
}

/// A checkout someone edited is no longer that commit, so it is rebuilt
/// from the mirror rather than read as if it were.
#[test]
fn a_tampered_checkout_is_detected_and_rebuilt() {
    let f = fixture();
    let published = sync(&f.env, REPO, None).unwrap();
    write_skill(&published.root, "tampered");
    assert!(store::published(&f.env, &key_for(&f.env), &published.commit).is_none());

    let repaired = cached(&f.env, REPO, None).unwrap().unwrap();
    assert_eq!(repaired.root, published.root);
    assert!(body(&repaired.root).contains("v1"));
}

/// A checkout an older kendex published is self-consistent with whatever it
/// wrote, so matching its own signature proves nothing about the rules that
/// wrote it. Its receipt is the bare signature, the form before those rules
/// were recorded, and it is rebuilt rather than served.
#[test]
fn a_checkout_published_before_the_rules_were_recorded_is_rebuilt() {
    let f = fixture();
    let published = sync(&f.env, REPO, None).unwrap();
    let key = key_for(&f.env);
    fs::write(
        store::receipt_path(&f.env, &key, &published.commit),
        store::tree_signature(&published.root).unwrap(),
    )
    .unwrap();

    assert!(store::published(&f.env, &key, &published.commit).is_none());

    let repaired = cached(&f.env, REPO, None).unwrap().unwrap();
    assert_eq!(repaired.root, published.root);
    assert!(body(&repaired.root).contains("v1"));
    assert!(store::published(&f.env, &key, &published.commit).is_some());
}

/// Callers test `published` before taking the lock, so two of them can
/// miss the same receipt and both go on to publish. The one that wakes
/// second finds the commit already there and hands back what is in place,
/// rather than materializing over a directory the first caller is reading.
/// Removing the mirror is what makes the answer observable: materializing
/// again is then the one thing that cannot quietly succeed.
#[test]
fn a_publisher_that_wakes_to_a_published_commit_leaves_it_alone() {
    let f = fixture();
    let first = sync(&f.env, REPO, None).unwrap();
    let key = key_for(&f.env);
    let mirror = store::mirror_dir(&f.env, &key);
    fs::remove_dir_all(&mirror).unwrap();

    let again = store::publish(&f.env, &key, &mirror, &first.commit).unwrap();

    assert_eq!(again, first.root);
    assert!(body(&again).contains("v1"));
}

/// Two trees of one commit can share a signature, so a receipt visible
/// while the old directory is still in place would vouch for the directory
/// about to be moved out from under a reader. The order is observable at
/// the step between: a receipt write that cannot land finds the old
/// checkout already gone rather than still being served.
#[test]
fn the_old_checkout_leaves_view_before_the_receipt_names_the_new_one() {
    let f = fixture();
    let first = sync(&f.env, REPO, None).unwrap();
    let key = key_for(&f.env);
    let mirror = store::mirror_dir(&f.env, &key);

    // Nothing renames a file onto a directory, so the receipt write fails
    // at exactly the step after the old checkout is moved aside.
    let receipt = store::receipt_path(&f.env, &key, &first.commit);
    fs::remove_file(&receipt).unwrap();
    fs::create_dir(&receipt).unwrap();

    assert!(store::publish(&f.env, &key, &mirror, &first.commit).is_err());
    assert!(!first.root.exists(), "the old checkout was still in view");
}

/// A checkout that fails half way leaves nothing readable behind: the
/// directory only ever appears complete, by rename.
#[test]
fn a_failed_checkout_publishes_nothing() {
    let f = fixture();
    sync(&f.env, REPO, None).unwrap();
    let key = key_for(&f.env);
    let missing = "0".repeat(40);

    let mirror = store::mirror_dir(&f.env, &key);
    assert!(store::publish(&f.env, &key, &mirror, &missing).is_err());
    assert!(!store::checkout_dir(&f.env, &key, &missing).exists());
    let leftovers: Vec<PathBuf> = fs::read_dir(f.env.source_cache_dir().join("commits").join(&key))
        .unwrap()
        .flatten()
        .map(|entry| entry.path())
        .filter(|path| {
            path.file_name()
                .is_some_and(|name| name.to_string_lossy().starts_with('.'))
        })
        .collect();
    assert!(leftovers.is_empty(), "staging left behind: {leftovers:?}");
}

/// A catalog checks out the bytes it committed, whatever its own
/// `.gitattributes` asks for. The two rules are placed to be told apart:
/// `eol.txt` is converted by the root file and `SKILL.md` is rewritten by
/// the nested one, so a checkout that honoured either says which. The
/// second is the one that made this a defect rather than a preference —
/// the driver's `smudge` command lives in configuration, so honouring it
/// gives one commit different bytes on two machines.
///
/// The hash is the whole claim, and it is one number for all three
/// platforms: `tree_signature` spells every path with `/` and records only
/// the one permission bit git keeps, so nothing in this tree — no link, no
/// executable, no separator — is spelled differently on Windows.
///
/// A control keeps it from passing for the wrong reason: the same commit
/// written with its own tree as the attribute source, against the same
/// mirror and the same host configuration, comes out converted and
/// rewritten.
#[test]
fn a_catalogs_own_attributes_do_not_decide_what_it_checks_out() {
    const SKILL: &str = "---\nname: gh\n---\nv1\n";
    let f = fixture();
    fs::write(f.upstream.join(".gitattributes"), "eol.txt text eol=crlf\n").unwrap();
    fs::write(f.upstream.join("eol.txt"), "one\ntwo\n").unwrap();
    fs::write(
        f.upstream.join("skills/.gitattributes"),
        "gh/SKILL.md filter=demo\n",
    )
    .unwrap();
    commit(&f.upstream, "attributes");
    let published = sync(&f.env, REPO, None).unwrap();
    let key = key_for(&f.env);
    let mirror = store::mirror_dir(&f.env, &key);

    // The host half of the arrangement: a machine that defines the driver
    // the catalog reaches for. `git hash-object` stands in for a smudge
    // command because it is the one program every host running this
    // already has.
    let smudge = "git hash-object -t blob --stdin";
    let set = Hardened::git_bare(&mirror, &["config", "filter.demo.smudge", smudge])
        .run()
        .unwrap();
    assert!(set.status.success());

    // The pin is not the mirror's HEAD, and the tree HEAD names holds no
    // attributes file at all: the guarantee must be about the commit being
    // written and not about what the repository points at now.
    fs::remove_file(f.upstream.join(".gitattributes")).unwrap();
    fs::remove_file(f.upstream.join("skills/.gitattributes")).unwrap();
    commit(&f.upstream, "no attributes");
    sync(&f.env, REPO, None).unwrap();

    // Published before the driver existed, so it is re-materialized under
    // it rather than served from the receipt.
    fs::remove_dir_all(&published.root).unwrap();
    fs::remove_file(store::receipt_path(&f.env, &key, &published.commit)).unwrap();
    let root = store::publish(&f.env, &key, &mirror, &published.commit).unwrap();

    assert_eq!(fs::read(root.join("eol.txt")).unwrap(), b"one\ntwo\n");
    assert_eq!(
        fs::read(root.join("skills/gh/SKILL.md")).unwrap(),
        SKILL.as_bytes()
    );
    assert_eq!(
        fs::read(root.join(".gitattributes")).unwrap(),
        b"eol.txt text eol=crlf\n"
    );
    assert_eq!(
        fs::read(root.join("skills/.gitattributes")).unwrap(),
        b"gh/SKILL.md filter=demo\n"
    );
    assert_eq!(
        store::tree_signature(&root).unwrap(),
        "4a7d5d6b36d50b5095a29d7da4e051ba354c3a9e00595d9fa40611eee51b9057"
    );

    // The control: the same commit written with its own tree as the
    // attribute source, which is the catalog getting what it asked for.
    let elsewhere = tempfile::tempdir().unwrap();
    let control = elsewhere.path().join("control");
    fs::create_dir_all(&control).unwrap();
    assert!(
        Hardened::git_bare(&mirror, &["read-tree", &published.commit])
            .run()
            .unwrap()
            .status
            .success()
    );
    assert!(
        Hardened::git_into(
            &mirror,
            &control,
            &published.commit,
            &["checkout-index", "--all", "--force"],
        )
        .run()
        .unwrap()
        .status
        .success()
    );
    assert_eq!(
        fs::read(control.join("eol.txt")).unwrap(),
        b"one\r\ntwo\r\n",
        "the eol rule was not live, so the checkout proves nothing"
    );
    assert_ne!(
        fs::read(control.join("skills/gh/SKILL.md")).unwrap(),
        SKILL.as_bytes(),
        "the smudge driver was not live, so the checkout proves nothing"
    );
}

/// The attribute source is named or the checkout does not happen. A
/// commit id whose length belongs to no object format leaves nothing to
/// name the empty tree with, and the one outcome that must not be
/// reachable is a write git converted because nothing told it not to — so
/// it is refused, loudly, rather than written unpinned.
#[test]
fn a_commit_id_of_no_known_object_format_is_refused() {
    let f = fixture();
    let published = sync(&f.env, REPO, None).unwrap();
    let key = key_for(&f.env);
    let mirror = store::mirror_dir(&f.env, &key);
    let abbreviated = &published.commit[..7];

    let error = store::publish(&f.env, &key, &mirror, abbreviated).unwrap_err();

    let refusal = error.to_string();
    assert!(
        refusal.starts_with(&format!("materializing {abbreviated} failed:")),
        "the refusal names something other than what kendex declined: {refusal}"
    );
    assert!(
        refusal.contains("attribute source"),
        "refused for some other reason: {refusal}"
    );
    assert!(!store::checkout_dir(&f.env, &key, abbreviated).exists());
}

/// The host's git templates reach no mirror. A template directory is
/// copied into every repository git creates, and one holding
/// `info/attributes` puts a rule beside the object store where no setting
/// on the checkout can reach it — not the global attributes file, not the
/// system one, and not the attribute source, which names a tree rather
/// than a file. Both halves are here: an `info/attributes` in a mirror
/// really does convert past everything the write settles, and the mirror
/// kendex clones carries no `info` directory for one to sit in.
#[test]
fn the_hosts_git_templates_reach_no_mirror() {
    let f = fixture();
    let published = sync(&f.env, REPO, None).unwrap();
    let key = key_for(&f.env);
    let mirror = store::mirror_dir(&f.env, &key);
    assert!(
        !mirror.join("info").exists(),
        "the mirror carries an info directory a host template could fill"
    );

    // The threat, made real in the one place a template would have put it.
    fs::create_dir_all(mirror.join("info")).unwrap();
    fs::write(mirror.join("info/attributes"), "* text eol=crlf\n").unwrap();
    fs::remove_dir_all(&published.root).unwrap();
    fs::remove_file(store::receipt_path(&f.env, &key, &published.commit)).unwrap();
    let converted = store::publish(&f.env, &key, &mirror, &published.commit).unwrap();
    assert_eq!(
        body(&converted),
        "---\r\nname: gh\r\n---\r\nv1\r\n",
        "an info/attributes in the mirror no longer converts, so an empty \
         template proves nothing"
    );
}

/// The receipt's rules line is what rebuilds a checkout an older kendex
/// wrote, and it is the whole upgrade path for a machine that already
/// holds a converted tree: the directory is there, its signature matches
/// what was written, and only the rules line says those were not today's
/// rules.
///
/// It has to be a well-formed older receipt to reach that comparison at
/// all — a rules line, a newline, and a signature that does match the
/// directory. A receipt missing the newline is refused a step earlier, for
/// having no rules line to read.
#[test]
fn a_checkout_published_under_older_rules_is_rebuilt() {
    let f = fixture();
    let published = sync(&f.env, REPO, None).unwrap();
    let key = key_for(&f.env);
    let receipt = store::receipt_path(&f.env, &key, &published.commit);
    let signature = store::tree_signature(&published.root).unwrap();
    fs::write(&receipt, format!("kendex-checkout 1\n{signature}\n")).unwrap();

    assert!(
        store::published(&f.env, &key, &published.commit).is_none(),
        "a checkout written under older rules was served as if it were today's"
    );

    let rebuilt = cached(&f.env, REPO, None).unwrap().unwrap();
    assert_eq!(rebuilt.root, published.root);
    assert!(store::published(&f.env, &key, &published.commit).is_some());
    assert_eq!(
        fs::read_to_string(&receipt).unwrap(),
        format!("kendex-checkout 2\n{signature}\n")
    );
}

/// Two resolvers must not materialize one repository at once. A refresh is
/// told the cache is busy rather than sitting on someone else's download,
/// while a read — which never has to write anything — answers what it can
/// without failing the whole scope over a neighbour.
#[test]
fn a_busy_repository_cache_is_reported_not_waited_on() {
    let f = fixture();
    let guard = store::lock_repo(&f.env, &key_for(&f.env)).unwrap();
    assert!(matches!(
        sync(&f.env, REPO, None),
        Err(CoreError::CacheBusy { .. })
    ));
    assert!(cached(&f.env, REPO, None).unwrap().is_none());
    drop(guard);
    sync(&f.env, REPO, None).unwrap();
}

/// One repository written three ways is one repository: the endings that
/// name no repository of their own share a mirror, a checkout tree and a
/// lock, and a different host never shares any of them.
#[test]
fn one_repository_spelled_three_ways_keeps_one_cache_entry() {
    let key = store::repo_key("https://example.test/owner/repo");
    assert_eq!(key, store::repo_key("https://example.test/owner/repo.git"));
    assert_eq!(key, store::repo_key("https://example.test/owner/repo/"));
    assert_ne!(key, store::repo_key("https://other.test/owner/repo"));
}

/// The lock lives as long as its guard and not a moment longer — an
/// abandoned lock file would wedge a repository until someone deleted it.
#[test]
fn the_cache_lock_is_released_with_its_guard() {
    let tmp = tempfile::tempdir().unwrap();
    let env = Env::fake(tmp.path(), FakeOs::Linux);
    let guard = store::lock_repo(&env, "catalog").unwrap();
    assert!(store::lock_repo(&env, "catalog").is_err());
    drop(guard);
    store::lock_repo(&env, "catalog").expect("the lock releases with its guard");
}

/// As with the scope lock: a child forked by any thread holds a copy of
/// this fd's open file description until it execs, so a release relying on
/// close alone stays held for the length of that spawn window — here paid
/// as the full LOCK_WAIT and then a false CacheBusy. The try_clone is that
/// fork copy at the description level: dropping the guard must release the
/// lock while the copy still exists.
#[cfg(unix)]
#[test]
fn the_cache_lock_releases_while_a_description_copy_exists() {
    let tmp = tempfile::tempdir().unwrap();
    let env = Env::fake(tmp.path(), FakeOs::Linux);
    let guard = store::lock_repo(&env, "catalog").unwrap();
    let copy = guard.file().try_clone().unwrap();
    drop(guard);
    let relock = store::lock_repo(&env, "catalog");
    drop(copy);
    relock.expect("drop released the lock despite the live description copy");
}

/// A scope's last check is the newest of its mirrors, never the oldest: a
/// source that keeps failing must not read as "never checked" over mirrors
/// that came current minutes ago. Sources with nothing to fetch — a local
/// path, a disabled declaration — hold no opinion either way.
#[test]
fn the_scope_last_fetched_is_the_newest_of_its_mirrors() {
    let tmp = tempfile::tempdir().unwrap();
    let env = Env::fake(tmp.path(), FakeOs::Linux);
    let source = |repo: Option<&str>, enabled: bool| SourceDecl {
        repo: repo.map(str::to_owned),
        path: None,
        rev: None,
        enabled,
    };
    let mut manifest = Manifest {
        schema: crate::manifest::MANIFEST_SCHEMA,
        ..Manifest::default()
    };
    manifest
        .sources
        .insert("cat".into(), source(Some("owner/cat"), true));
    manifest
        .sources
        .insert("dog".into(), source(Some("owner/dog"), true));
    manifest
        .sources
        .insert("off".into(), source(Some("owner/off"), false));
    manifest.sources.insert("here".into(), source(None, true));
    // Enabled and remote, but nothing installs from it — a subscription
    // somebody is only browsing.
    manifest
        .sources
        .insert("shop".into(), source(Some("owner/shop"), true));
    for (name, from) in [("gh", "cat"), ("jj", "dog"), ("here-one", "here")] {
        manifest
            .skills
            .insert(name.into(), crate::manifest::ItemDecl::from_source(from));
    }

    assert_eq!(
        last_fetched(&env, &manifest),
        None,
        "no mirror has ever fetched: the scope has never been checked"
    );

    let stamp = |repo: &str, at: u64| {
        crate::drift::stamps::record_success(&env, &cache_key(&env, repo), None, at).unwrap();
    };
    stamp("owner/cat", 1_000);
    assert_eq!(last_fetched(&env, &manifest), Some(1_000));
    stamp("owner/dog", 2_000);
    assert_eq!(last_fetched(&env, &manifest), Some(2_000));
    // The older mirror failing since does not move the answer backwards,
    // and its failure is reported on its own.
    crate::drift::stamps::record_failure(&env, &cache_key(&env, "owner/cat"), "offline", 3_000)
        .unwrap();
    assert_eq!(last_fetched(&env, &manifest), Some(2_000));

    // A disabled source and a local one are not fetched, so a stamp under
    // one of their names cannot answer for the scope.
    stamp("owner/off", 9_000);
    assert_eq!(
        last_fetched(&env, &manifest),
        Some(2_000),
        "a source nothing fetches says nothing about when the scope was checked"
    );

    // The rows come from the sources the scope installs from. Merely
    // opening a subscription fetches its mirror, and dating the page from
    // that would call the standing fresh while every source behind it had
    // gone unreached for days.
    stamp("owner/shop", 8_000);
    assert_eq!(
        last_fetched(&env, &manifest),
        Some(2_000),
        "a source no row comes from cannot date the standing"
    );

    // A stamp ahead of the clock is a clock that ran backwards, which the
    // drift check already refuses to read as fresh. The newest mirror is
    // now the future one, so an unfiltered maximum would both date the
    // page as current and bury the one mirror still answering honestly —
    // cat's last success at 1_000, kept under its later failure.
    stamp("owner/dog", crate::clock::unix_now() + 86_400);
    assert_eq!(
        last_fetched(&env, &manifest),
        Some(1_000),
        "a future stamp neither dates the scope nor hides a valid one"
    );
}
