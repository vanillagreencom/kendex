//! What a source offers is a fact about the source, so a project whose lock
//! this build cannot read still lists every catalog it subscribes to.
//!
//! The lock only answers what is already installed here. Loading it as a
//! precondition of listing meant one project's damaged or older-generation
//! record hid every package on the Packages tab while the Subscribed tab,
//! which never reads the lock, went on counting the same catalogs. The rows
//! come through with their installed state answered as unknown — never
//! guessed as available, which would offer an install the engine refuses
//! for the same unreadable record.
//!
//! Which scope's record is the question the tests at the bottom hold to.
//! A page browsing a personal subscription can redirect the install into a
//! project, and the engine mutates the project it is handed — so the state
//! the page gates on has to be the destination's, in both directions: an
//! unreadable destination refuses, and an unreadable scope being browsed
//! does not refuse an install landing somewhere readable.
#![cfg(unix)]

#[path = "../../test_util.rs"]
mod test_util;
use test_util::rooted;

use std::fs;
use std::path::Path;

use kendex_core::env::{Env, FakeOs};
use kendex_core::model::{ItemKind, Scope};
use kendex_core::source::browse::{self, Catalog, InstallState};

struct Fixture {
    _tmp: tempfile::TempDir,
    env: Env,
    scope: Scope,
    source: std::path::PathBuf,
    lock_path: std::path::PathBuf,
}

impl Fixture {
    fn manifest_path(&self) -> std::path::PathBuf {
        kendex_core::manifest::manifest_path(&self.env, &self.scope)
    }
}

#[allow(clippy::unwrap_used)]
fn put(path: &Path, text: &str) {
    fs::create_dir_all(path.parent().unwrap()).unwrap();
    fs::write(path, text).unwrap();
}

/// A project subscribed to one local catalog offering a single skill, with
/// no lock written yet.
#[allow(clippy::unwrap_used)]
fn fixture() -> Fixture {
    let tmp = tempfile::tempdir().unwrap();
    let home = rooted(&tmp);
    let project = home.join("dev/app");
    let source = home.join("catalog");
    put(
        &source.join("skills/gh/SKILL.md"),
        "---\nname: gh\ndescription: work a pull request\n---\n\nBody.\n",
    );
    put(
        &source.join("kendex.toml"),
        "[bundles.starter]\ndescription = \"the starter set\"\nskills = [\"gh\"]\n",
    );
    put(
        &project.join("kendex.toml"),
        &format!(
            "schema = {}\n\n[sources.cat]\npath = \"{}\"\n\n[install]\nharnesses = [\"claude\"]\nmethod = \"symlink\"\n",
            kendex_core::manifest::MANIFEST_SCHEMA,
            source.display()
        ),
    );
    Fixture {
        env: Env::fake(&home, FakeOs::Linux),
        scope: Scope::Project {
            root: project.clone(),
        },
        source,
        lock_path: project.join(".kendex-lock.json"),
        _tmp: tmp,
    }
}

fn catalog(scope: &Scope) -> Catalog {
    Catalog::Subscription {
        scope: scope.clone(),
        source: "cat".to_owned(),
    }
}

#[allow(clippy::unwrap_used)]
fn offered(f: &Fixture) -> Vec<(String, InstallState)> {
    browse::packages(&f.env, &catalog(&f.scope))
        .unwrap()
        .into_iter()
        .map(|package| (package.name, package.state))
        .collect()
}

#[allow(clippy::unwrap_used)]
fn detail(f: &Fixture) -> browse::BundleDetail {
    browse::bundle(&f.env, &catalog(&f.scope), "starter", None).unwrap()
}

#[allow(clippy::unwrap_used)]
fn members(f: &Fixture) -> Vec<(String, InstallState)> {
    detail(f)
        .members
        .into_iter()
        .map(|member| (member.name, member.state))
        .collect()
}

/// Renames the catalog's only skill out from under the set, so `starter`
/// names a member nothing offers — what an upstream rename or removal
/// leaves behind.
#[allow(clippy::unwrap_used)]
fn drop_the_member(f: &Fixture) {
    fs::rename(
        f.source.join("skills/gh"),
        f.source.join("skills/gh-renamed"),
    )
    .unwrap();
}

/// Damaged bytes reach the same answer by the same route: the read that
/// lists is not the read that judges installed state.
#[test]
#[allow(clippy::unwrap_used)]
fn a_damaged_lock_still_lists_what_the_catalog_offers() {
    let f = fixture();
    fs::write(&f.lock_path, "{not json").unwrap();
    assert_eq!(offered(&f), [("gh".to_owned(), InstallState::Unknown)]);
}

/// One project's unreadable record is that project's alone — a second
/// scope subscribed to the same catalog answers exactly as before.
#[test]
#[allow(clippy::unwrap_used)]
fn another_scope_reading_the_same_catalog_is_untouched() {
    let broken = fixture();
    fs::write(&broken.lock_path, "{not json").unwrap();
    let healthy = fixture();

    assert_eq!(offered(&broken), [("gh".to_owned(), InstallState::Unknown)]);
    assert_eq!(
        offered(&healthy),
        [("gh".to_owned(), InstallState::Available)]
    );
}

/// The manifest can say a member was removed on purpose without the lock,
/// but the row it draws offers Restore, and a restore lands on the record
/// this read could not open. So the unreadable lock answers first for every
/// member the catalog still offers: no standing claimed, no button offered.
#[test]
#[allow(clippy::unwrap_used)]
fn a_suppressed_member_under_an_unreadable_lock_offers_no_restore() {
    let f = fixture();
    let manifest = fs::read_to_string(f.manifest_path()).unwrap();
    put(
        &f.manifest_path(),
        &format!("{manifest}\n[suppressed]\nskill = [\"gh\"]\n"),
    );
    assert_eq!(
        members(&f),
        [("gh".to_owned(), InstallState::RemovedByYou)],
        "the control: with a readable record, their choice is theirs to see"
    );

    fs::write(&f.lock_path, "{not json").unwrap();
    assert_eq!(members(&f), [("gh".to_owned(), InstallState::Unknown)]);
}

/// The page a Packages row opens reads the same standing the row showed,
/// so it can withhold its Install for the same reason the row withheld
/// one — rather than offering a button the engine refuses on that record.
#[test]
#[allow(clippy::unwrap_used)]
fn the_package_page_carries_the_same_unknown_the_row_showed() {
    let f = fixture();
    let preview = |f: &Fixture| {
        browse::package_preview(&f.env, &catalog(&f.scope), ItemKind::Skill, "gh", None)
            .unwrap()
            .state
    };
    assert_eq!(preview(&f), InstallState::Available);

    fs::write(&f.lock_path, "{not json").unwrap();
    assert_eq!(preview(&f), InstallState::Unknown);
}

/// A member the catalog no longer carries answers NotOffered with or
/// without a lock, so the set page cannot read the scope's record off its
/// rows: every member answering NotOffered is the shape that looks readable.
/// `records_unreadable` is the scope's own answer, carried rather than
/// derived, and Install all is what reads it.
#[test]
#[allow(clippy::unwrap_used)]
fn the_set_carries_the_scopes_answer_even_where_no_member_shows_it() {
    let f = fixture();
    drop_the_member(&f);
    assert!(
        !detail(&f).records_unreadable,
        "the control: a readable record says so"
    );

    fs::write(&f.lock_path, "{not json").unwrap();
    let detail = detail(&f);
    assert!(detail.records_unreadable);
    assert!(
        detail
            .members
            .iter()
            .all(|member| member.state == InstallState::NotOffered),
        "no member row carries the fact, which is why the set must"
    );
}

/// Browsing one place and installing into another: a personal subscription
/// to a local catalog, plus a project to redirect the install into. Each
/// place has its own lock, and either one can be the damaged one.
struct Redirect {
    _tmp: tempfile::TempDir,
    env: Env,
    browsing: Scope,
    destination: Scope,
    browsed_lock: std::path::PathBuf,
    destination_lock: std::path::PathBuf,
}

#[allow(clippy::unwrap_used)]
fn redirect() -> Redirect {
    let tmp = tempfile::tempdir().unwrap();
    let home = rooted(&tmp);
    let project = home.join("dev/app");
    let source = home.join("catalog");
    put(
        &source.join("skills/gh/SKILL.md"),
        "---\nname: gh\ndescription: work a pull request\n---\n\nBody.\n",
    );
    put(
        &source.join("kendex.toml"),
        "[bundles.starter]\ndescription = \"the starter set\"\nskills = [\"gh\"]\n",
    );
    let env = Env::fake(&home, FakeOs::Linux);
    let declaration = format!(
        "schema = {}\n\n[sources.cat]\npath = \"{}\"\n\n[install]\nharnesses = [\"claude\"]\nmethod = \"symlink\"\n",
        kendex_core::manifest::MANIFEST_SCHEMA,
        source.display()
    );
    put(
        &kendex_core::manifest::manifest_path(&env, &Scope::Global),
        &declaration,
    );
    // The destination declares the same subscription, which is what
    // installing into a project from a personal one leaves behind.
    put(&project.join("kendex.toml"), &declaration);
    let browsed_lock = kendex_core::lock::lock_path(&env, &Scope::Global);
    Redirect {
        env,
        browsing: Scope::Global,
        destination: Scope::Project {
            root: project.clone(),
        },
        browsed_lock,
        destination_lock: project.join(".kendex-lock.json"),
        _tmp: tmp,
    }
}

#[allow(clippy::unwrap_used)]
fn redirected_state(r: &Redirect) -> InstallState {
    browse::package_preview(
        &r.env,
        &catalog(&r.browsing),
        ItemKind::Skill,
        "gh",
        Some(&r.destination),
    )
    .unwrap()
    .state
}

#[allow(clippy::unwrap_used)]
fn redirected_detail(r: &Redirect) -> browse::BundleDetail {
    browse::bundle(
        &r.env,
        &catalog(&r.browsing),
        "starter",
        Some(&r.destination),
    )
    .unwrap()
}

/// The available-package page's Install gates on the state this read
/// returns, and the install lands in the destination the page picked — so a
/// damaged record there withholds the button, whatever the scope being
/// browsed says.
#[test]
#[allow(clippy::unwrap_used)]
fn the_package_page_withholds_its_install_for_an_unreadable_destination() {
    let r = redirect();
    assert_eq!(
        redirected_state(&r),
        InstallState::Available,
        "the control: two readable records offer the install"
    );

    fs::write(&r.destination_lock, "{not json").unwrap();
    assert_eq!(
        redirected_state(&r),
        InstallState::Unknown,
        "the install lands here, and the engine would refuse on this record"
    );
}

/// The inverse, and the worse of the two: a scope being browsed whose lock
/// cannot be read must not withhold an install landing somewhere that reads
/// perfectly well. Nothing about that record is in the install's way, and
/// refusing on it is a valid action denied with no reason to show.
#[test]
#[allow(clippy::unwrap_used)]
fn an_unreadable_browsed_scope_does_not_withhold_an_install_landing_elsewhere() {
    let r = redirect();
    fs::write(&r.browsed_lock, "{not json").unwrap();

    assert_eq!(redirected_state(&r), InstallState::Available);
    assert_eq!(
        browse::package_preview(&r.env, &catalog(&r.browsing), ItemKind::Skill, "gh", None)
            .unwrap()
            .state,
        InstallState::Unknown,
        "the control: with no redirect the same damaged record still answers"
    );
}

/// The set page's Install all reads `records_unreadable` and its member
/// boxes read each member's state; both are about the place the install
/// lands in, so a damaged record there withholds both.
#[test]
#[allow(clippy::unwrap_used)]
fn the_set_page_withholds_its_installs_for_an_unreadable_destination() {
    let r = redirect();
    let detail = redirected_detail(&r);
    assert!(
        !detail.records_unreadable,
        "the control: two readable records offer Install all"
    );
    assert_eq!(
        detail.members.first().map(|member| member.state),
        Some(InstallState::Available)
    );

    fs::write(&r.destination_lock, "{not json").unwrap();
    let detail = redirected_detail(&r);
    assert!(detail.records_unreadable);
    assert_eq!(
        detail.members.first().map(|member| member.state),
        Some(InstallState::Unknown),
        "no member box may be ticked for a place whose record went unread"
    );
}

/// The set page's inverse: a damaged record in the scope being browsed
/// leaves Install all and every member box alone when the install lands in
/// a project that reads.
#[test]
#[allow(clippy::unwrap_used)]
fn an_unreadable_browsed_scope_leaves_the_sets_installs_alone() {
    let r = redirect();
    fs::write(&r.browsed_lock, "{not json").unwrap();

    let detail = redirected_detail(&r);
    assert!(!detail.records_unreadable);
    assert_eq!(
        detail.members.first().map(|member| member.state),
        Some(InstallState::Available)
    );

    let browsed = browse::bundle(&r.env, &catalog(&r.browsing), "starter", None).unwrap();
    assert!(
        browsed.records_unreadable,
        "the control: with no redirect the same damaged record still answers"
    );
}
