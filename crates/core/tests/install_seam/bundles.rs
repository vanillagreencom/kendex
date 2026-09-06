//! Install-all subsumption: declaring a whole bundle folds in the
//! equal-option members declared earlier — and only those — and a second
//! marketplace's same-named bundle is refused naming the first.

use std::collections::BTreeSet;
use std::fs;
use std::path::PathBuf;

use kendex_core::apply;
use kendex_core::engine::{audit, ops};
use kendex_core::error::CoreError;
use kendex_core::lock::{BundleRef, Reason, load as load_lock, lock_path};

use super::{Fixture, add_and_apply, manifest_of, manifest_with, skill, world, write};

/// A catalog whose `kendex.toml` offers `starter` = dev + docs.
fn starter_catalog(f: &Fixture, name: &str) -> PathBuf {
    let catalog = f.home.join(name);
    skill(&catalog, "dev");
    skill(&catalog, "docs");
    write(
        &catalog,
        "kendex.toml",
        "[bundles.starter]\ndescription = \"the starter set\"\nskills = [\"dev\", \"docs\"]\n",
    );
    catalog
}

#[allow(clippy::unwrap_used)]
fn apply_now(f: &Fixture) {
    let report = audit(&f.env, &f.scope).unwrap();
    apply::execute(&f.env, &report.plan).unwrap();
}

/// Every way a member is the user's own — not just its harness list — keeps its
/// declaration when the whole bundle installs. Each of these, subsumed by
/// mistake, silently deletes what the person chose, so each is pinned: a member
/// with its own install method and one toggled off both stay, while the plain
/// equal member is folded in.
#[test]
#[allow(clippy::unwrap_used)]
fn subsumption_keeps_every_member_the_user_shaped() {
    let f = world();
    let catalog = f.home.join("catalog");
    for name in ["copied", "off", "plain"] {
        skill(&catalog, name);
    }
    write(
        &catalog,
        "kendex.toml",
        "[bundles.all]\ndescription = \"everything\"\nskills = [\"copied\", \"off\", \"plain\"]\n",
    );
    manifest_with(
        &f,
        &[("cat", &catalog)],
        "[skills.copied]\nsource = \"cat\"\nmethod = \"copy\"\n\n[skills.off]\nsource = \"cat\"\nenabled = false\n\n[skills.plain]\nsource = \"cat\"\n",
    );

    let report = add_and_apply(
        &f,
        &ops::AddRequest {
            source: Some("cat".to_owned()),
            bundles: vec!["all".into()],
            no_auto_skills: true,
            ..ops::AddRequest::default()
        },
    );

    let manifest = manifest_of(&f);
    assert!(
        manifest.skills.contains_key("copied"),
        "a member with its own install method stays declared"
    );
    assert!(
        manifest.skills.contains_key("off"),
        "a member toggled off stays declared"
    );
    assert!(
        !manifest.skills.contains_key("plain"),
        "the equal-option member is subsumed"
    );
    for reason in ["install method", "toggled it"] {
        assert!(
            report.notes.iter().any(|note| note.contains(reason)),
            "each kept member names its reason ({reason}): {:?}",
            report.notes
        );
    }
}

/// Install-all subsumes the member whose effective options equal what the
/// bundle derives — its declaration goes, the installation stays on the
/// bundle's edge — and keeps the member the user shaped, saying why.
#[test]
#[allow(clippy::unwrap_used)]
fn installing_the_whole_bundle_subsumes_equal_members_and_keeps_shaped_ones() {
    let f = world();
    let catalog = starter_catalog(&f, "catalog");
    manifest_with(
        &f,
        &[("cat", &catalog)],
        "[skills.dev]\nsource = \"cat\"\n\n[skills.docs]\nsource = \"cat\"\nharnesses = [\"claude\"]\n",
    );
    apply_now(&f);

    let report = add_and_apply(
        &f,
        &ops::AddRequest {
            source: Some("cat".to_owned()),
            bundles: vec!["starter".into()],
            no_auto_skills: true,
            ..ops::AddRequest::default()
        },
    );

    assert!(
        report
            .notes
            .iter()
            .any(|note| note == "1 package now comes with the starter bundle"),
        "{:?}",
        report.notes
    );
    assert!(
        report
            .notes
            .iter()
            .any(|note| note.contains("docs") && note.contains("harness list")),
        "the kept member is named with the reason: {:?}",
        report.notes
    );

    let manifest = manifest_of(&f);
    assert!(
        !manifest.skills.contains_key("dev"),
        "the equal-option declaration is subsumed"
    );
    assert!(
        manifest.skills.contains_key("docs"),
        "a member with its own harness list stays declared"
    );
    assert!(manifest.bundles.contains_key("starter"));

    let lock = load_lock(&lock_path(&f.env, &f.scope)).unwrap();
    let member = Reason::MemberOf {
        bundle: BundleRef {
            source: "cat".to_owned(),
            name: "starter".to_owned(),
        },
    };
    assert_eq!(
        lock.entries["skill:dev:claude"].reasons,
        BTreeSet::from([member.clone()]),
        "dev is installed through the bundle edge alone"
    );
    assert_eq!(
        lock.entries["skill:docs:claude"].reasons,
        BTreeSet::from([Reason::Requested, member]),
        "docs keeps its own request"
    );
    assert!(f.project.join(".claude/skills/dev").exists());
}

/// `[bundles.<name>]` is keyed by bare name: a second marketplace's
/// same-named bundle is refused naming the first, with installing the
/// members individually offered as the way out.
#[test]
#[allow(clippy::unwrap_used)]
fn a_second_marketplaces_same_named_bundle_is_refused_naming_the_first() {
    let f = world();
    let catalog = starter_catalog(&f, "catalog");
    let rival = starter_catalog(&f, "rival");
    manifest_with(
        &f,
        &[("cat", &catalog), ("cat2", &rival)],
        "[bundles.starter]\nsource = \"cat\"\n",
    );
    apply_now(&f);
    let before = fs::read_to_string(f.project.join("kendex.toml")).unwrap();

    let error = ops::add(
        &f.env,
        &f.scope,
        &ops::AddRequest {
            source: Some("cat2".to_owned()),
            bundles: vec!["starter".into()],
            no_auto_skills: true,
            ..ops::AddRequest::default()
        },
    )
    .unwrap_err();

    let said = error.to_string();
    assert!(
        matches!(error, CoreError::BundleCollision { ref name, .. } if name == "starter"),
        "{said}"
    );
    assert!(
        said.contains(&catalog.display().to_string()),
        "the first marketplace is named canonically: {said}"
    );
    assert!(said.contains("individually"), "{said}");
    assert_eq!(
        fs::read_to_string(f.project.join("kendex.toml")).unwrap(),
        before,
        "a refusal writes nothing"
    );
    let members_installed = f.project.join(".claude/skills/dev").exists()
        && f.project.join(".claude/skills/docs").exists();
    assert!(members_installed, "the first bundle stays whole");
}

/// A set the catalog offers and can hand nothing over for is refused at the
/// declaration. What a set installs derives at plan time, so declaring it
/// would record the set, plan nothing, and report a successful install of no
/// files — the shape a `skills = ["nope"]` list leaves behind.
#[test]
#[allow(clippy::unwrap_used)]
fn a_set_whose_members_the_catalog_does_not_offer_is_refused() {
    let f = world();
    let catalog = f.home.join("catalog");
    skill(&catalog, "dev");
    write(
        &catalog,
        "kendex.toml",
        "[bundles.ghost]\nskills = [\"nope\"]\n\n[bundles.starter]\nskills = [\"dev\"]\n",
    );
    manifest_with(&f, &[("cat", &catalog)], "");
    let before = fs::read_to_string(f.project.join("kendex.toml")).unwrap();

    let error = ops::add(&f.env, &f.scope, &request("ghost")).unwrap_err();
    let said = error.to_string();
    assert!(
        matches!(error, CoreError::BundleInstallsNothing { ref name, .. } if name == "ghost"),
        "{said}"
    );
    assert!(said.contains("nope"), "the member it cannot offer: {said}");
    assert_eq!(
        fs::read_to_string(f.project.join("kendex.toml")).unwrap(),
        before,
        "a refusal writes nothing"
    );
}

/// The must-fail counterpart: the set beside it, whose member the catalog
/// does offer, installs. The refusal is about what the catalog can hand over,
/// not about sets.
#[test]
#[allow(clippy::unwrap_used)]
fn a_set_whose_member_the_catalog_offers_installs() {
    let f = world();
    let catalog = starter_catalog(&f, "catalog");
    manifest_with(&f, &[("cat", &catalog)], "");
    add_and_apply(&f, &request("starter"));
    assert!(f.project.join(".claude/skills/dev").exists());
}

/// One `add --bundle <name>` from the catalog these tests declare.
fn request(name: &str) -> ops::AddRequest {
    ops::AddRequest {
        source: Some("cat".to_owned()),
        bundles: vec![name.to_owned()],
        no_auto_skills: true,
        ..ops::AddRequest::default()
    }
}

/// A catalog whose set stops reading keeps what it already installed — the
/// member, and what that member requires. Both derive to nothing while the
/// body is unreadable, and `kendex apply` sweeps what nothing derives, so a
/// catalog-side edit would otherwise trash a consumer's files and tell them
/// they were not wanted. The same holds when the control file cannot be
/// opened at all: a symlink the sealed reader refuses to look through, whose
/// error is dropped one layer up.
#[test]
#[allow(clippy::unwrap_used)]
fn an_unreadable_set_keeps_its_member_and_what_that_member_requires() {
    let f = world();
    let catalog = f.home.join("catalog");
    write(
        &catalog,
        "skills/dev/SKILL.md",
        "---\nname: dev\ndescription: the dev skill\ndependencies:\n  required: [helper]\n---\nBody.\n",
    );
    skill(&catalog, "helper");
    write(
        &catalog,
        "kendex.toml",
        "[bundles.starter]\nskills = [\"dev\"]\n",
    );
    manifest_with(
        &f,
        &[("cat", &catalog)],
        "[bundles.starter]\nsource = \"cat\"\n",
    );
    apply_now(&f);
    let member = f.project.join(".claude/skills/dev");
    let required = f.project.join(".claude/skills/helper");
    assert!(member.exists() && required.exists(), "both install first");

    write(
        &catalog,
        "kendex.toml",
        "[bundles.starter]\nskills = [\"dev\"]\nversion = \"1.0\"\n",
    );
    sweep(&f);
    assert!(member.exists(), "an unreadable set trashed its member");
    assert!(required.exists(), "it trashed what that member requires");

    fs::remove_file(catalog.join("kendex.toml")).unwrap();
    std::os::unix::fs::symlink(f.home.join("away.toml"), catalog.join("kendex.toml")).unwrap();
    let report = sweep(&f);
    assert!(
        member.exists(),
        "a catalog that would not open lost its member"
    );
    // The open is the only thing holding this error: the set declaration
    // reaches a catalog that gives back nothing, and every caller below sees
    // a plan that derived nothing rather than one that could not read. A
    // retention nothing accounts for is what the removal pass then keeps.
    assert_eq!(
        report
            .notes
            .iter()
            .filter(
                |note| note.starts_with("the catalog 'cat' could not be read")
                    && note.contains("kendex.toml")
            )
            .count(),
        1,
        "a catalog that would not open kept files with nothing said: {:?}",
        report.notes
    );
}

/// The lines saying this plan kept a catalog's installations rather than
/// sweeping them — one per catalog it could not read.
fn kept_notes<'a>(report: &'a kendex_core::engine::EngineReport, source: &str) -> Vec<&'a String> {
    report
        .notes
        .iter()
        .filter(|note| {
            note.starts_with(&format!("the catalog '{source}' "))
                && note.contains(" it brought in ")
        })
        .collect()
}

/// The must-fail counterpart: a catalog that reads still sweeps what its set
/// stopped carrying, so the retention above is not "keep everything".
#[test]
#[allow(clippy::unwrap_used)]
fn a_readable_catalog_sweeps_what_its_set_dropped() {
    let f = world();
    let catalog = starter_catalog(&f, "catalog");
    manifest_with(
        &f,
        &[("cat", &catalog)],
        "[bundles.starter]\nsource = \"cat\"\n",
    );
    apply_now(&f);
    let member = f.project.join(".claude/skills/dev");
    assert!(member.exists(), "the member installs first");

    write(
        &catalog,
        "kendex.toml",
        "[bundles.starter]\nskills = [\"docs\"]\n",
    );
    let report = sweep(&f);
    assert!(!member.exists(), "a set that reads kept what it dropped");
    assert!(
        !report
            .notes
            .iter()
            .any(|note| note.contains("could not be read")),
        "a catalog that reads was reported as one that would not: {:?}",
        report.notes
    );
}

/// A sweep that reaches no declaration from the catalog it is about to
/// delete files for, against each shape the read can fail in: a control file
/// that will not open, and one that parses carrying a set body that will not
/// read. Nothing opens the catalog during expansion, so "can this origin
/// still be read" arrives at the removal pass with nothing behind it, and a
/// catalog nobody looked at must not answer as one that read. Two members,
/// because the retention is reported per catalog and a one-member set cannot
/// tell one note from one per file kept. The last step is the must-fail
/// counterpart: the same orphans and the same absent declaration against a
/// catalog that reads, which go.
#[test]
#[allow(clippy::unwrap_used)]
fn a_sweep_with_no_declaration_left_reads_the_catalog_itself() {
    let f = world();
    let catalog = starter_catalog(&f, "catalog");
    manifest_with(
        &f,
        &[("cat", &catalog)],
        "[bundles.starter]\nsource = \"cat\"\n",
    );
    apply_now(&f);
    let members = [
        f.project.join(".claude/skills/dev"),
        f.project.join(".claude/skills/docs"),
    ];
    assert!(members.iter().all(|path| path.exists()), "both install");

    manifest_with(&f, &[("cat", &catalog)], "");
    fs::remove_file(catalog.join("kendex.toml")).unwrap();
    std::os::unix::fs::symlink(f.home.join("away.toml"), catalog.join("kendex.toml")).unwrap();
    let report = sweep(&f);
    assert!(
        members.iter().all(|path| path.exists()),
        "a catalog no declaration opened lost its members"
    );
    let kept = kept_notes(&report, "cat");
    assert_eq!(
        kept.len(),
        1,
        "one catalog it could not read is one note: {:?}",
        report.notes
    );
    assert!(
        kept[0].contains("kendex.toml") && kept[0].contains("symlink in a catalog"),
        "the note carries the read failure: {}",
        kept[0]
    );
    assert!(
        kept[0].ends_with("; the 2 installations it brought in were kept"),
        "the note says what it held, and how much: {}",
        kept[0]
    );

    // A control file that parses, carrying a set body this reader will not
    // read — and a broken `[marketplace]` ahead of it, an advisory problem a
    // working catalog also has, so the cause has to be the one the verdict
    // turned on rather than the first one on the display list.
    fs::remove_file(catalog.join("kendex.toml")).unwrap();
    write(
        &catalog,
        "kendex.toml",
        "[marketplace]\ntags = \"analysis\"\n\n[bundles.starter]\nskills = [\"dev\"]\nversion = \"1.0\"\n",
    );
    let report = sweep(&f);
    assert!(
        members.iter().all(|path| path.exists()),
        "an unreadable set body lost the members"
    );
    let kept = kept_notes(&report, "cat");
    assert_eq!(
        kept.len(),
        1,
        "one note for the catalog: {:?}",
        report.notes
    );
    assert!(
        kept[0].contains("[bundles.starter]")
            && kept[0].contains("version")
            && !kept[0].contains("[marketplace]"),
        "the note names the set the verdict turned on: {}",
        kept[0]
    );

    write(
        &catalog,
        "kendex.toml",
        "[bundles.starter]\ndescription = \"the starter set\"\nskills = [\"dev\", \"docs\"]\n",
    );
    sweep(&f);
    assert!(
        members.iter().all(|path| !path.exists()),
        "a catalog that reads kept orphans nothing declares"
    );
}

/// A catalog that cannot be resolved at all keeps what it installed, and the
/// plan says so. Every note about a source's state is written per
/// declaration, and the first step here has none — the subscription is gone
/// — so without this the person sees `kendex apply` do nothing while a stale
/// package sits there with no line about it. The second step is the count:
/// one member is held by a declaration that could not be processed and is
/// reported against that declaration, so the retention must not add it to
/// what it says is riding on the catalog.
#[test]
#[allow(clippy::unwrap_used)]
fn a_sweep_with_no_subscription_left_says_what_it_kept() {
    let f = world();
    let catalog = starter_catalog(&f, "catalog");
    manifest_with(
        &f,
        &[("cat", &catalog)],
        "[bundles.starter]\nsource = \"cat\"\n",
    );
    apply_now(&f);
    let member = f.project.join(".claude/skills/dev");
    let other = f.project.join(".claude/skills/docs");
    assert!(member.exists() && other.exists(), "both install first");

    manifest_with(&f, &[], "");
    let report = sweep(&f);
    assert!(
        member.exists() && other.exists(),
        "an unsubscribed catalog lost its members"
    );
    assert_eq!(
        report
            .notes
            .iter()
            .filter(|note| note.starts_with("the catalog 'cat' ")
                && note.ends_with("; the 2 installations it brought in were kept"))
            .count(),
        1,
        "the plan says which catalog it kept files for, and how many: {:?}",
        report.notes
    );

    manifest_with(&f, &[("cat", &catalog)], "[skills.dev]\nsource = \"cat\"\n");
    fs::remove_dir_all(&catalog).unwrap();
    let report = sweep(&f);
    assert!(
        member.exists(),
        "a catalog that is gone lost the named member"
    );
    assert!(other.exists(), "it lost the member only the set brought in");
    assert_eq!(
        report
            .notes
            .iter()
            .filter(
                |note| note.starts_with("the catalog 'cat' is not on this machine")
                    && note.ends_with("; the installation it brought in was kept")
            )
            .count(),
        1,
        "the plan says the catalog is gone, and counts only what it held: {:?}",
        report.notes
    );
}

/// A plugin-registry catalog's sets are its plugins, and what a plugin holds
/// is a second read that can fail on its own — the registry and the control
/// file both read fine and say nothing about it. The same no-declaration
/// sweep must not take a plugin's items because the plugin would not
/// enumerate. What keeps this from reading as "keep everything" is the
/// readable step the two tests above end on.
#[test]
#[allow(clippy::unwrap_used)]
fn a_sweep_with_no_declaration_left_reads_a_plugins_own_members() {
    let f = world();
    let catalog = f.home.join("market");
    write(
        &catalog,
        ".claude-plugin/marketplace.json",
        r#"{"name": "market", "owner": {"name": "someone"},
  "plugins": [{"name": "tools", "source": "./plugins/tools"}]}"#,
    );
    write(
        &catalog,
        "plugins/tools/.claude-plugin/plugin.json",
        r#"{"name": "tools"}"#,
    );
    skill(&catalog.join("plugins/tools"), "dev");
    manifest_with(
        &f,
        &[("cat", &catalog)],
        "[bundles.tools]\nsource = \"cat\"\n",
    );
    apply_now(&f);
    let member = f.project.join(".claude/skills/tools__dev");
    assert!(member.exists(), "the plugin's skill installs first");

    manifest_with(&f, &[("cat", &catalog)], "");
    let manifest = catalog.join("plugins/tools/.claude-plugin/plugin.json");
    fs::remove_file(&manifest).unwrap();
    std::os::unix::fs::symlink(f.home.join("away.json"), &manifest).unwrap();
    let report = sweep(&f);
    assert!(
        member.exists(),
        "a plugin that would not enumerate lost its skill"
    );
    assert_eq!(
        kept_notes(&report, "cat").len(),
        1,
        "the plan names the catalog it kept files for: {:?}",
        report.notes
    );
}

/// A member the person also declared by name carries `Requested` beside the
/// set's edge. Dropping that declaration while the set stops reading leaves
/// exactly one entry: out of desired state, with a derivation this pass
/// cannot check — and the set may still require it. The last step is the
/// must-fail counterpart: a set that reads and no longer carries it goes,
/// so the retention is not "keep everything the person once declared".
#[test]
#[allow(clippy::unwrap_used)]
fn a_declared_member_keeps_its_set_edge_when_the_set_stops_reading() {
    let f = world();
    let catalog = f.home.join("catalog");
    skill(&catalog, "dev");
    skill(&catalog, "docs");
    write(
        &catalog,
        "kendex.toml",
        "[bundles.starter]\nskills = [\"dev\"]\n",
    );
    manifest_with(
        &f,
        &[("cat", &catalog)],
        "[skills.dev]\nsource = \"cat\"\n\n[bundles.starter]\nsource = \"cat\"\n",
    );
    apply_now(&f);
    let member = f.project.join(".claude/skills/dev");
    assert!(member.exists(), "the member installs first");
    let lock = load_lock(&lock_path(&f.env, &f.scope)).unwrap();
    assert_eq!(
        lock.entries["skill:dev:claude"].reasons,
        BTreeSet::from([
            Reason::Requested,
            Reason::MemberOf {
                bundle: BundleRef {
                    source: "cat".to_owned(),
                    name: "starter".to_owned(),
                },
            },
        ]),
        "the entry is both asked for and carried"
    );

    manifest_with(
        &f,
        &[("cat", &catalog)],
        "[bundles.starter]\nsource = \"cat\"\n",
    );
    write(
        &catalog,
        "kendex.toml",
        "[bundles.starter]\nskills = [\"dev\"]\nversion = \"1.0\"\n",
    );
    sweep(&f);
    assert!(
        member.exists(),
        "an unreadable set trashed the member the person had also declared"
    );

    write(
        &catalog,
        "kendex.toml",
        "[bundles.starter]\nskills = [\"docs\"]\n",
    );
    sweep(&f);
    assert!(
        !member.exists(),
        "a set that reads kept a member it no longer carries"
    );
}

/// One `kendex apply` sweep of this scope, orphans and all.
#[allow(clippy::unwrap_used)]
fn sweep(f: &Fixture) -> kendex_core::engine::EngineReport {
    let report = kendex_core::engine::plan_apply(
        &f.env,
        &f.scope,
        &kendex_core::engine::PlanOptions {
            remove_orphans: true,
            removal_filter: None,
            ..kendex_core::engine::PlanOptions::default()
        },
    )
    .unwrap();
    apply::execute(&f.env, &report.plan).unwrap();
    report
}
