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
use kendex_core::model::{HarnessId, ItemKind, Scope};
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
    source: std::path::PathBuf,
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
    let destination = Scope::Project {
        root: project.clone(),
    };
    // Both paths come off the engine's own resolver rather than composed
    // here: a composed one diverges from what a read resolves wherever the
    // home it is rooted under is a symlink.
    let browsed_lock = kendex_core::lock::lock_path(&env, &Scope::Global);
    let destination_lock = kendex_core::lock::lock_path(&env, &destination);
    Redirect {
        env,
        browsing: Scope::Global,
        destination,
        source,
        browsed_lock,
        destination_lock,
        _tmp: tmp,
    }
}

impl Redirect {
    /// The manifest of one of this fixture's two places, off the engine's
    /// own resolver rather than composed here.
    fn manifest_path(&self, scope: &Scope) -> std::path::PathBuf {
        kendex_core::manifest::manifest_path(&self.env, scope)
    }

    /// Records `gh` as installed from the `cat` subscription in one place
    /// and nowhere else.
    #[allow(clippy::unwrap_used)]
    fn install_gh_in(&self, scope: &Scope) {
        let mut lock = kendex_core::lock::Lock {
            version: kendex_core::lock::LOCK_VERSION,
            root: match scope {
                Scope::Project { root } => Some(root.clone()),
                Scope::Global => None,
            },
            ..Default::default()
        };
        lock.entries.insert(
            kendex_core::lock::entry_key(ItemKind::Skill, "gh", HarnessId::Claude),
            kendex_core::lock::LockEntry {
                name: "gh".to_owned(),
                kind: ItemKind::Skill,
                harness: HarnessId::Claude,
                source: "cat".to_owned(),
                source_repo: "cat".to_owned(),
                method: kendex_core::manifest::Method::Symlink,
                installed_at: "2026-01-01T00:00:00Z".to_owned(),
                source_hash: "hash".to_owned(),
                source_commit: None,
                rendered_hash: None,
                enabled: true,
                upstream_skills: None,
                emitted: None,
                registration: None,
                reasons: std::collections::BTreeSet::from([kendex_core::lock::Reason::Requested]),
            },
        );
        kendex_core::lock::save(&kendex_core::lock::lock_path(&self.env, scope), &lock).unwrap();
    }

    /// Declares `gh` and the `starter` set in one place from a source that
    /// is not the catalog being browsed — the name clash invariant 4
    /// refuses an install on.
    #[allow(clippy::unwrap_used)]
    fn claim_gh_in(&self, scope: &Scope) {
        let path = self.manifest_path(scope);
        let manifest = fs::read_to_string(&path).unwrap();
        put(
            &path,
            &format!(
                "{manifest}\n[sources.other]\npath = \"{}\"\n\n[skills.gh]\nsource = \"other\"\n\n[bundles.starter]\nsource = \"other\"\n",
                self.source.display()
            ),
        );
    }

    /// Adds this place's own instructions to `gh`, which the catalog's
    /// bytes do not carry and the preview therefore never scored.
    #[allow(clippy::unwrap_used)]
    fn inject_into_gh_in(&self, scope: &Scope) {
        let path = self.manifest_path(scope);
        let manifest = fs::read_to_string(&path).unwrap();
        put(
            &path,
            &format!("{manifest}\n[skill-instructions]\ngh = \"house rules\"\n"),
        );
    }

    /// Records that the person removed `gh` on purpose in one place.
    #[allow(clippy::unwrap_used)]
    fn suppress_gh_in(&self, scope: &Scope) {
        let path = self.manifest_path(scope);
        let manifest = fs::read_to_string(&path).unwrap();
        put(
            &path,
            &format!("{manifest}\n[suppressed]\nskill = [\"gh\"]\n"),
        );
    }
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

/// The package page's Install gates on the state this read returns, and the
/// install lands in the destination the page picked. Both directions: a
/// damaged record where the install lands withholds the button, and a
/// damaged one in the scope being browsed does not withhold an install
/// landing somewhere that reads — the second is the worse of the two, a
/// valid action denied with no reason to show.
#[test]
#[allow(clippy::unwrap_used)]
fn the_package_page_is_judged_at_the_destination() {
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

/// The set page reaches the same gate through the other engine entry point,
/// and reads two things there: `records_unreadable`, which Install all
/// gates on, and each member's standing, which the boxes gate on. Both are
/// the landing place's, in both directions and past readability — an
/// installation recorded there is what makes a row say Installed, and a
/// removal recorded there is what makes it say whose choice it was. Reading
/// the browsed scope instead puts a wrong count on the page and a box the
/// reader cannot tick for the place actually missing the member.
#[test]
#[allow(clippy::unwrap_used)]
fn the_set_page_is_judged_at_the_destination() {
    let member = |r: &Redirect| redirected_detail(r).members.first().map(|m| m.state);
    let count = |r: &Redirect| redirected_detail(r).installed_members;

    let r = redirect();
    assert!(
        !redirected_detail(&r).records_unreadable,
        "the control: two readable records offer Install all"
    );
    assert_eq!((member(&r), count(&r)), (Some(InstallState::Available), 0));

    fs::write(&r.destination_lock, "{not json").unwrap();
    let detail = redirected_detail(&r);
    assert!(detail.records_unreadable);
    assert_eq!(
        detail.members.first().map(|m| m.state),
        Some(InstallState::Unknown),
        "no member box may be ticked for a place whose record went unread"
    );

    // Damaged in the scope being browsed and nowhere else: the install is
    // not going there, so nothing about it is in the way.
    let r = redirect();
    fs::write(&r.browsed_lock, "{not json").unwrap();
    assert!(!redirected_detail(&r).records_unreadable);
    assert_eq!((member(&r), count(&r)), (Some(InstallState::Available), 0));
    assert!(
        browse::bundle(&r.env, &catalog(&r.browsing), "starter", None)
            .unwrap()
            .records_unreadable,
        "the control: with no redirect the same damaged record still answers"
    );

    let r = redirect();
    r.install_gh_in(&r.destination);
    assert_eq!(
        (member(&r), count(&r)),
        (Some(InstallState::Installed), 1),
        "installed where the install lands, so the row says so"
    );
    let r = redirect();
    r.install_gh_in(&r.browsing);
    assert_eq!((member(&r), count(&r)), (Some(InstallState::Available), 0));

    let r = redirect();
    r.suppress_gh_in(&r.destination);
    assert_eq!(
        member(&r),
        Some(InstallState::RemovedByYou),
        "kept removed where the install lands, so the row says whose choice it was"
    );
    let r = redirect();
    r.suppress_gh_in(&r.browsing);
    assert_eq!(
        member(&r),
        Some(InstallState::Available),
        "a removal in the scope being browsed says nothing about the project it lands in"
    );
}

fn redirected_state(r: &Redirect) -> InstallState {
    redirected_preview(r).state
}

#[allow(clippy::unwrap_used)]
fn redirected_preview(r: &Redirect) -> browse::PackagePreview {
    browse::package_preview(
        &r.env,
        &catalog(&r.browsing),
        ItemKind::Skill,
        "gh",
        Some(&r.destination),
    )
    .unwrap()
}

#[allow(clippy::unwrap_used)]
fn redirected_safety(r: &Redirect) -> browse::PackageSafety {
    browse::package_safety(
        &r.env,
        &catalog(&r.browsing),
        ItemKind::Skill,
        "gh",
        Some(&r.destination),
    )
    .unwrap()
}

/// The name clash a page shows before the click is the one the engine's
/// invariant 4 would refuse on, and the engine judges that against the
/// scope it is handed. So the warning reads the destination's records, on
/// the package page and on the set page alike: a name that place already
/// holds from another source is warned about, and one only the browsed
/// scope holds is not, because the install is not going there.
#[test]
#[allow(clippy::unwrap_used)]
fn a_name_clash_is_read_where_the_install_lands() {
    let r = redirect();
    assert_eq!(
        redirected_preview(&r).collision,
        None,
        "the control: nothing claims the name in either place"
    );

    r.claim_gh_in(&r.destination);
    assert_eq!(
        redirected_preview(&r).collision,
        Some("other".to_owned()),
        "the install would land on this claim, so the page says so first"
    );
    assert_eq!(
        redirected_detail(&r).collision,
        Some("other".to_owned()),
        "the set's own name is claimed there too"
    );

    // The inverse: claimed only in the scope being browsed, which the
    // install is not going to.
    let r = redirect();
    r.claim_gh_in(&r.browsing);
    assert_eq!(redirected_preview(&r).collision, None);
    assert_eq!(redirected_detail(&r).collision, None);
}

/// The safety note says what the preview did not read: the instructions a
/// place adds to what installs there. Which place is the one the install
/// lands in, so a destination that injects gets the note and a browsed
/// scope that injects does not — the note would otherwise describe text no
/// installed copy would carry.
#[test]
#[allow(clippy::unwrap_used)]
fn the_safety_note_is_about_the_place_the_install_lands_in() {
    let r = redirect();
    assert!(
        redirected_safety(&r).notes.is_empty(),
        "the control: neither place adds anything to gh"
    );

    r.inject_into_gh_in(&r.destination);
    assert_eq!(
        redirected_safety(&r).notes.len(),
        1,
        "installed there, gh carries that place's instructions, unscored here"
    );

    let r = redirect();
    r.inject_into_gh_in(&r.browsing);
    assert!(
        redirected_safety(&r).notes.is_empty(),
        "no installed copy would carry these, so the note would be about nothing"
    );
}
