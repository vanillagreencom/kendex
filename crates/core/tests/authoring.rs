//! The Mine flows: registering folders, the byte-stable scaffold, and
//! use-existing's zero-writes promise.

use std::fs;
use std::path::{Path, PathBuf};

use kendex_core::author::{self, CreateRequest, License};
use kendex_core::env::{Env, FakeOs};

#[path = "../../test_util.rs"]
mod test_util;
use test_util::rooted;

#[allow(clippy::unwrap_used)]
fn fake() -> (tempfile::TempDir, Env) {
    let tmp = tempfile::tempdir().unwrap();
    let env = Env::fake(tmp.path(), FakeOs::Linux);
    (tmp, env)
}

#[allow(clippy::unwrap_used)]
fn skills_repo(root: &Path) {
    let dir = root.join(".claude/skills/review");
    fs::create_dir_all(&dir).unwrap();
    fs::write(
        dir.join("SKILL.md"),
        "---\nname: review\ndescription: reviews things\n---\nBody.\n",
    )
    .unwrap();
}

/// Everything under a directory, path → bytes, for before/after compares.
#[allow(clippy::unwrap_used)]
fn tree(root: &Path) -> Vec<(PathBuf, Vec<u8>)> {
    let mut files = Vec::new();
    let mut stack = vec![root.to_path_buf()];
    while let Some(dir) = stack.pop() {
        for entry in fs::read_dir(&dir).unwrap() {
            let path = entry.unwrap().path();
            match path.is_dir() {
                true => stack.push(path),
                false => files.push((path.clone(), fs::read(&path).unwrap())),
            }
        }
    }
    files.sort();
    files
}

/// "Use existing" changes zero bytes inside the selected repository: the
/// whole tree is byte-identical before and after, and the row still knows
/// what the folder offers.
#[test]
#[allow(clippy::unwrap_used)]
fn use_existing_registers_with_zero_writes() {
    let (tmp, env) = fake();
    let repo = tmp.path().join("their-repo");
    skills_repo(&repo);
    let before = tree(&repo);

    let row = author::use_existing(&env, &repo).unwrap();
    assert_eq!(tree(&repo), before, "use-existing must write nothing");
    assert_eq!(row.counts.get("skill"), Some(&1));
    assert!(!row.declared);
    assert_eq!(
        author::list(&env).unwrap(),
        [repo.canonicalize().unwrap()],
        "the row is app-owned state, not a byte in the folder"
    );
}

#[test]
#[allow(clippy::unwrap_used)]
fn an_empty_folder_is_refused_with_the_next_step_named() {
    let (tmp, env) = fake();
    let empty = tmp.path().join("empty");
    fs::create_dir_all(&empty).unwrap();
    let refused = author::use_existing(&env, &empty).unwrap_err().to_string();
    assert!(refused.contains("nothing kendex can offer"), "{refused}");
    assert!(author::list(&env).unwrap().is_empty());
}

#[test]
#[allow(clippy::unwrap_used)]
fn registering_twice_names_the_existing_row() {
    let (tmp, env) = fake();
    let repo = tmp.path().join("repo");
    skills_repo(&repo);
    author::register(&env, &repo).unwrap();
    let refused = author::register(&env, &repo).unwrap_err().to_string();
    assert!(refused.contains("already under Mine"), "{refused}");
    author::unregister(&env, &repo).unwrap();
    assert!(author::list(&env).unwrap().is_empty());
    assert!(repo.exists(), "unregister forgets, never deletes");
}

fn request(dir: &Path, license: License) -> CreateRequest {
    CreateRequest {
        name: "my-marketplace".to_owned(),
        description: "Skills for the whole team".to_owned(),
        author: "Jane Doe".to_owned(),
        license,
        dir: dir.to_path_buf(),
    }
}

/// The scaffold is byte-stable: identical inputs produce identical bytes,
/// across every licence option — the golden the create dialog rests on.
#[test]
#[allow(clippy::unwrap_used)]
fn the_scaffold_is_byte_stable_for_every_licence() {
    for license in [License::Mit, License::Apache2, License::NoneYet] {
        let first = author::plan(&request(Path::new("/a"), license)).unwrap();
        let second = author::plan(&request(Path::new("/b"), license)).unwrap();
        assert_eq!(first, second, "{license:?} scaffold drifted between runs");
        let files: Vec<&str> = first.iter().map(|(rel, _)| rel.as_str()).collect();
        assert!(files.contains(&"kendex.toml"));
        assert!(files.contains(&"README.md"));
        assert!(files.contains(&".github/workflows/kendex-check.yml"));
        match license {
            License::NoneYet => assert!(!files.contains(&"LICENSE")),
            _ => assert!(files.contains(&"LICENSE")),
        }
        for (rel, bytes) in &first {
            assert!(
                !bytes.contains('\r'),
                "{rel} carries a platform newline — the scaffold writes \\n only"
            );
        }
    }
}

/// MIT carries the author's copyright line; the manifest carries the SPDX id.
#[test]
#[allow(clippy::unwrap_used)]
fn the_scaffold_writes_the_licence_evidence() {
    let files = author::plan(&request(Path::new("/x"), License::Mit)).unwrap();
    let license = &files.iter().find(|(rel, _)| rel == "LICENSE").unwrap().1;
    assert!(license.contains("Copyright (c) Jane Doe"));
    let manifest = &files
        .iter()
        .find(|(rel, _)| rel == "kendex.toml")
        .unwrap()
        .1;
    assert!(manifest.contains("license = \"MIT\""));
}

/// The scaffold teaches the `[bundles]` grammar in a commented-out example,
/// and the only other check over it pins bytes. Bytes are happy to pin a
/// shape no reader looks at, which is how kendex's own four sets shipped
/// installing nothing. The example is generated from the reader's own list,
/// so the question left is whether the round trip closes: uncomment what the
/// scaffold wrote and the reader has to get every kind back out of it.
#[test]
#[allow(clippy::unwrap_used)]
fn the_scaffolded_bundle_example_is_a_set_the_reader_accepts() {
    let files = author::plan(&request(Path::new("/x"), License::Mit)).unwrap();
    let manifest = &files
        .iter()
        .find(|(rel, _)| rel == "kendex.toml")
        .unwrap()
        .1;

    let example: String = manifest
        .lines()
        .skip_while(|line| !line.starts_with("# [bundles."))
        .map(|line| format!("{}\n", line.trim_start_matches('#').trim_start()))
        .collect();
    assert!(
        !example.is_empty(),
        "the scaffold writes no [bundles.<name>] example:\n{manifest}"
    );

    let tmp = tempfile::tempdir().unwrap();
    let root = rooted(&tmp);
    fs::write(root.join("kendex.toml"), &example).unwrap();
    let sealed = kendex_core::source_read::SealedSource::open(&root).unwrap();
    let config = kendex_core::source::source_config(&sealed, "scaffolded").unwrap();
    let sets = kendex_core::source::bundles::offered(&sealed, &config).unwrap();

    let members: Vec<String> = sets
        .iter()
        .flat_map(|set| set.members.iter())
        .map(|member| format!("{} {}", member.kind.name(), member.name))
        .collect();
    // What the example is expected to yield is the example itself, read back
    // through the reader: every kind, under the name the scaffold wrote for
    // it. A kind added to the grammar extends both sides at once, and a kind
    // the reader stops seeing shortens only one.
    let expected: Vec<String> = kendex_core::source::bundles::member_list_example()
        .lines()
        .map(|line| {
            let name = line
                .split('"')
                .nth(1)
                .unwrap_or_else(|| panic!("the example line '{line}' names a member"));
            format!("{} {name}", name.trim_start_matches("my-"))
        })
        .collect();
    // Both sides come out of the same generator, so both go empty together
    // and compare equal. The grammar sentence is the third party: one member
    // per key it lists, or the example is not the example it describes.
    let keys = kendex_core::source::bundles::member_list_keys();
    let listed = keys.split(", ").count();
    assert!(
        !keys.is_empty(),
        "the grammar sentence lists no keys at all"
    );
    assert_eq!(
        expected.len(),
        listed,
        "the example carries {} member(s) and the grammar sentence lists {listed} \
         key(s) ({keys})",
        expected.len()
    );
    assert_eq!(
        members, expected,
        "the scaffolded example, uncommented, is not a set the reader gets every kind \
         out of:\n{example}"
    );
}

#[test]
#[allow(clippy::unwrap_used)]
fn create_writes_the_plan_registers_and_checks_clean() {
    let (tmp, env) = fake();
    let dir = tmp.path().join("made");
    let row = author::create(&env, &request(&dir, License::Mit)).unwrap();
    assert!(dir.join("kendex.toml").exists());
    assert!(dir.join("README.md").exists());
    assert!(row.declared, "the scaffold declares the layout");
    assert_eq!(row.name, "my-marketplace");
    assert_eq!(row.breakage, 0, "{:?}", row.findings);
    assert_eq!(author::list(&env).unwrap(), [dir.canonicalize().unwrap()]);

    let again = author::create(&env, &request(&dir, License::Mit)).unwrap_err();
    assert!(again.to_string().contains("already exists"), "{again}");
}

/// `nope/..` names no folder of its own. Left unrefused it is a create
/// into the directory the command was run in, and the failure path's
/// removal then takes that directory with it.
#[test]
#[allow(clippy::unwrap_used)]
fn a_path_whose_last_component_is_not_a_name_refuses_and_writes_nothing() {
    let (tmp, env) = fake();
    let work = tmp.path().join("work");
    fs::create_dir_all(work.join("sub")).unwrap();
    fs::write(work.join("keep.txt"), "somebody's file").unwrap();
    fs::write(work.join("sub/also.txt"), "and another").unwrap();

    let refused = author::create(&env, &request(&work.join("nope/.."), License::Mit)).unwrap_err();
    assert!(
        refused.to_string().contains("not a creatable folder path"),
        "{refused}"
    );
    assert_eq!(
        fs::read_to_string(work.join("keep.txt")).unwrap(),
        "somebody's file"
    );
    assert_eq!(
        fs::read_to_string(work.join("sub/also.txt")).unwrap(),
        "and another"
    );
    assert!(!work.join("kendex.toml").exists(), "nothing was scaffolded");
    assert!(
        author::list(&env).unwrap().is_empty(),
        "nothing was registered"
    );
}

/// A folder is made inside one that is already there, and a containing
/// folder that is not gets a refusal naming it rather than being brought
/// into being. `CreateRequest.dir` has said "its parent must exist" all
/// along; before this the create made the whole chain instead.
#[test]
#[allow(clippy::unwrap_used)]
fn a_containing_folder_that_does_not_exist_refuses_and_makes_nothing() {
    let (tmp, env) = fake();
    let work = tmp.path().join("work");
    fs::create_dir_all(&work).unwrap();

    let refused = author::create(&env, &request(&work.join("absent/made"), License::Mit))
        .unwrap_err()
        .to_string();

    assert!(refused.contains("is not a folder that exists"), "{refused}");
    assert!(
        refused.contains(&work.join("absent").display().to_string()),
        "the refusal names the folder that is missing: {refused}"
    );
    assert!(
        !work.join("absent").exists(),
        "no part of the chain was brought into being"
    );
    assert!(
        author::list(&env).unwrap().is_empty(),
        "nothing was registered"
    );
}

/// A parent that exists and cannot be traversed is not an absent one.
/// Told it must make the folder first, a person would find it already
/// there; the failure the path actually met is what they can act on.
#[cfg(unix)]
#[test]
#[allow(clippy::unwrap_used)]
fn a_parent_that_cannot_be_reached_is_not_reported_as_missing() {
    use std::os::unix::fs::PermissionsExt as _;
    let (tmp, env) = fake();
    let locked = tmp.path().join("locked");
    fs::create_dir_all(locked.join("inner")).unwrap();
    fs::set_permissions(&locked, fs::Permissions::from_mode(0o600)).unwrap();
    let unlock = || fs::set_permissions(&locked, fs::Permissions::from_mode(0o700)).unwrap();
    if locked.join("inner").metadata().is_ok() {
        // Permissions do not bind this user (root): the traversal cannot
        // be made to fail here.
        unlock();
        return;
    }

    let outcome = author::create(&env, &request(&locked.join("inner/made"), License::Mit));
    unlock();
    let refused = outcome.unwrap_err().to_string();

    assert!(
        !refused.contains("is not a folder that exists"),
        "an unreachable parent is not an absent one: {refused}"
    );
    assert!(
        refused.contains(&locked.join("inner").display().to_string()),
        "the refusal names the parent it could not reach: {refused}"
    );
}

/// A link whose target is gone answers `exists` with false, and the
/// failure path's `remove_dir_all` deletes the link itself.
///
/// Asked of the three spellings that reach one place, because they do not
/// all resolve alike: `made` stops at the link, while `made/` and
/// `made/.` send the kernel through it and answer NotFound. A guard on
/// the caller's spelling passes for the last two while the build and the
/// removal work on the place all three name.
#[cfg(unix)]
#[test]
#[allow(clippy::unwrap_used)]
fn a_dangling_link_at_the_destination_refuses_in_every_spelling() {
    for spelling in ["made", "made/", "made/."] {
        let (tmp, env) = fake();
        let link = tmp.path().join("made");
        std::os::unix::fs::symlink(tmp.path().join("nowhere-at-all"), &link).unwrap();

        let asked = tmp.path().join(spelling);
        let refused = author::create(&env, &request(&asked, License::Mit)).unwrap_err();
        assert!(
            refused.to_string().contains("already exists"),
            "{spelling}: {refused}"
        );
        assert!(
            link.is_symlink(),
            "{spelling}: the link somebody made is still there"
        );
        assert!(
            author::list(&env).unwrap().is_empty(),
            "{spelling}: nothing was registered"
        );
    }
}

/// A registry that refuses after the build takes the folder back, and
/// takes nothing else.
///
/// The refusal has to land after `build_in`, or the removal this pins
/// never runs: `can_register` only reads the registry, so the fixture
/// makes the write fail instead, by taking write permission off the
/// directory `authored.toml` sits in once the read has been satisfied.
#[cfg(unix)]
#[test]
#[allow(clippy::unwrap_used)]
fn a_registry_refusal_after_the_build_removes_only_the_folder_it_made() {
    use std::os::unix::fs::PermissionsExt as _;
    let (tmp, env) = fake();
    let work = tmp.path().join("work");
    fs::create_dir_all(work.join("sub")).unwrap();
    fs::write(work.join("keep.txt"), "somebody's file").unwrap();

    // One registration, so the registry file and its directory exist.
    let other = tmp.path().join("other");
    fs::create_dir_all(&other).unwrap();
    author::register(&env, &other).unwrap();

    let registry = env.settings_file().parent().unwrap().to_path_buf();
    fs::set_permissions(&registry, fs::Permissions::from_mode(0o500)).unwrap();
    let unlock = || fs::set_permissions(&registry, fs::Permissions::from_mode(0o700)).unwrap();
    if fs::write(registry.join("probe"), "").is_ok() {
        // Permissions do not bind this user (root): the write cannot be
        // made to fail here.
        unlock();
        return;
    }

    let made = work.join("made");
    let outcome = author::create(&env, &request(&made, License::Mit));
    unlock();
    let refused = outcome.unwrap_err();

    // The refusal has to be the registry's own write, because only that
    // one lands after `build_in` and reaches the removal this fixture
    // exists to pin. Said positively, naming the file the write failed
    // on: `atomic_write` reports its sibling temp name, so the assertion
    // is on the stem both spellings share, and a refusal arriving from
    // anywhere else reds this rather than passing quietly. The negative
    // stands beside it because `can_register` and `register` word a
    // duplicate row identically, so that string alone says nothing about
    // which of them fired.
    let said = refused.to_string();
    assert!(
        said.contains(&registry.join("authored").display().to_string()),
        "the refusal has to be the registry's own write: {said}"
    );
    assert!(
        !said.contains("already under Mine"),
        "and not its duplicate check, which refuses before the build: {said}"
    );
    assert!(
        !said.contains("left behind"),
        "and the folder came back, so the error is the registry's own: {said}"
    );
    assert!(!made.exists(), "the folder this call made is gone");
    assert_eq!(
        fs::read_to_string(work.join("keep.txt")).unwrap(),
        "somebody's file"
    );
    assert!(work.join("sub").is_dir(), "nothing else was removed");
    assert!(other.is_dir(), "and nothing of anybody else's");
}

#[test]
#[allow(clippy::unwrap_used)]
fn a_name_no_harness_accepts_refuses_before_any_write() {
    let (tmp, env) = fake();
    let dir = tmp.path().join("bad");
    let mut bad = request(&dir, License::NoneYet);
    bad.name = "My Marketplace!".to_owned();
    assert!(author::create(&env, &bad).is_err());
    assert!(!dir.exists(), "a refused create must write nothing");
}

struct NoNetwork;
impl kendex_core::registry::Fetch for NoNetwork {
    fn get_auth(
        &self,
        _url: &str,
        _etag: Option<&str>,
        _bearer: Option<&str>,
    ) -> kendex_core::error::Result<kendex_core::registry::FetchResponse> {
        panic!("the preflight must not touch the network without a GitHub remote");
    }
    fn post_json_auth(
        &self,
        _url: &str,
        _body: &str,
        _bearer: Option<&str>,
    ) -> kendex_core::error::Result<kendex_core::registry::FetchResponse> {
        panic!("the preflight never posts");
    }
}

/// A fresh scaffold is honest about what is missing: local rows pass, the
/// remote rows fail or wait, and nothing asks the network before a GitHub
/// remote exists.
#[test]
#[allow(clippy::unwrap_used)]
fn the_preflight_stays_local_until_a_remote_exists() {
    let (tmp, env) = fake();
    let dir = tmp.path().join("made");
    author::create(&env, &request(&dir, License::Mit)).unwrap();
    let preflight = author::submit_preflight(&dir, &NoNetwork).unwrap();
    assert!(!preflight.ready);
    assert_eq!(preflight.candidate, None);
    let row = |label: &str| {
        preflight
            .checks
            .iter()
            .find(|check| check.label.starts_with(label))
            .unwrap_or_else(|| panic!("no row {label}"))
            .ok
    };
    assert_eq!(row("Passes the check"), Some(true));
    assert_eq!(row("No safety findings"), Some(true));
    assert_eq!(row("Has a licence"), Some(true));
    assert_eq!(row("Has a GitHub remote"), Some(false));
    assert_eq!(row("Repository is public"), None);
}

/// git in a fixture, with the caller's git environment dropped: run from a
/// commit hook, `GIT_DIR` and friends point at the repository being
/// committed to and every command here would act on that one instead.
#[allow(clippy::unwrap_used)]
fn git(dir: &Path, args: &[&str]) {
    let output = std::process::Command::new("git")
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

/// What a submit would send, out of the remote the folder actually has.
///
/// A remote is a URL. The `owner/repo` shorthand a manifest may carry is
/// not one, and a path remote — `../bare.git`, or an absolute one — has
/// that same two-segment shape, so folding it would offer a folder with no
/// GitHub anywhere near it as a repository ready to submit. Every URL
/// spelling GitHub answers to is one candidate, folded to lowercase like
/// every other repository string in the tree, so what a submit sends and
/// what the Community tab matches subscriptions by are the same string.
///
/// Driven through `status`, not `submit_preflight`: the preflight fetches
/// from `origin` and asks GitHub whether the repository is public, so a
/// table of remotes there would be a table of network calls.
#[test]
#[allow(clippy::unwrap_used)]
fn only_a_github_url_is_a_candidate_to_submit() {
    let (tmp, _env) = fake();
    let absolute = tmp.path().join("bare.git").display().to_string();
    for (remote, candidate) in [
        // The path shapes, which have the shorthand's two segments and
        // name no host at all.
        ("../bare.git", None),
        (absolute.as_str(), None),
        // Every transport GitHub answers to, and the endings and case that
        // say nothing about which repository it is.
        ("https://github.com/Owner/Repo.git", Some("owner/repo")),
        ("https://www.github.com/Owner/Repo/", Some("owner/repo")),
        ("git@github.com:Owner/Repo.git", Some("owner/repo")),
        ("ssh://git@github.com/Owner/Repo", Some("owner/repo")),
        // A URL, and a repository — on a host a submit cannot name.
        ("https://gitlab.com/owner/repo.git", None),
    ] {
        let repo = tmp.path().join("theirs");
        let _ = fs::remove_dir_all(&repo);
        skills_repo(&repo);
        git(&repo, &["init", "--quiet", "-b", "main"]);
        git(&repo, &["remote", "add", "origin", remote]);

        let row = author::status(&repo).unwrap();
        assert!(row.git.repository, "{remote}: not read as a repository");
        assert_eq!(
            row.git.remote.as_deref(),
            Some(remote),
            "{remote}: the remote was not reported as written"
        );
        assert_eq!(
            row.git.candidate.as_deref(),
            candidate,
            "{remote}: wrong candidate"
        );
    }
}

/// The golden pin: these exact tree digests, per licence. Any byte change
/// in the scaffold must land here alongside a SCAFFOLD_VERSION bump —
/// comparing two calls of the same code can never catch drift, a
/// checked-in digest can.
#[test]
#[allow(clippy::unwrap_used)]
fn the_scaffold_matches_its_checked_in_golden_digest() {
    assert_eq!(kendex_core::author::scaffold::SCAFFOLD_VERSION, 2);
    for (license, expected) in [
        (
            License::Mit,
            "98a5e948dac921d6cba4cae5b07e514a9e6cba1a638fa6c45ce30ff45aa55f79",
        ),
        (
            License::Apache2,
            "4e63fd7bba05248e94e5247a5749c9ff51d5cbfd791468bd2b0f0838b99c0deb",
        ),
        (
            License::NoneYet,
            "171067bedea26065af8967fb445f306fb97e322c989325d2d97e52e404d19741",
        ),
    ] {
        let files: Vec<(std::path::PathBuf, Vec<u8>)> =
            author::plan(&request(Path::new("/golden"), license))
                .unwrap()
                .into_iter()
                .map(|(rel, bytes)| (std::path::PathBuf::from(rel), bytes.into_bytes()))
                .collect();
        let digest = kendex_core::hash::hash_files(&files);
        assert_eq!(digest, expected, "{license:?} scaffold bytes drifted");
    }
}
