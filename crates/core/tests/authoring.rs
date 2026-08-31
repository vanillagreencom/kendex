//! The Mine flows: registering folders, the byte-stable scaffold, and
//! use-existing's zero-writes promise.

use std::fs;
use std::path::{Path, PathBuf};

use kendex_core::author::{self, CreateRequest, License};
use kendex_core::env::{Env, FakeOs};

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

/// The golden pin: these exact tree digests, per licence. Any byte change
/// in the scaffold must land here alongside a SCAFFOLD_VERSION bump —
/// comparing two calls of the same code can never catch drift, a
/// checked-in digest can.
#[test]
#[allow(clippy::unwrap_used)]
fn the_scaffold_matches_its_checked_in_golden_digest() {
    assert_eq!(kendex_core::author::scaffold::SCAFFOLD_VERSION, 1);
    for (license, expected) in [
        (
            License::Mit,
            "df65c4e972e7fcf85459c2030b2933ecf5d9af06f26f321f663d1843a6ea1ded",
        ),
        (
            License::Apache2,
            "7f8703f6999631efc692e1bfe9db21dfa5636e96a930177f74ba1ecf957093e8",
        ),
        (
            License::NoneYet,
            "f99f2b34f98f9a480b34e1b3b543d2ddf731dc27c783c61aaa109d61b5c1116e",
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
