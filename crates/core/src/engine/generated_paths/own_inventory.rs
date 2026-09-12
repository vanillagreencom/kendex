//! This repository's committed inventory, held to the set it renders.
//!
//! `kendex refresh` at a checkout is the only writer of
//! `.kendex-generated.json`, and a worktree may not run it, so nothing moved
//! the committed copy when a pull request landed a new render. Its readers —
//! `hooks/doc-drift-check.sh`, commit-guards' `suppression-ban` and
//! harness-ci's `harness-only` — judge a path the inventory does not list as
//! hand-written, so a render it lost is named as uncovered code at every
//! stop.
//!
//! This is the check that refuses that state before the commit that would
//! cause it. It plans this checkout the way `refresh` does and writes
//! nothing, so the judge of what a render is stays [`super::collect`] — the
//! renderer's own — and no list of harness directories is spelled a second
//! time here. It holds the bytes as well as the set: the writer lays the
//! set down one entry per line so a merge conflict is bounded to the lines
//! holding the entries involved, and every reader parses the JSON back into
//! a set, so only a byte comparison against the writer's own document
//! notices a copy some other writer laid out on one line.
//!
//! Not on Windows. The renders this repository commits include symlinks,
//! and a Windows checkout materialises each as a regular file holding its
//! target's path, so the tree a planner reads there is not the tree that was
//! committed and the set it derives is not this one. The Linux and macOS
//! legs judge every pull request, and `tools/guard --full` judges the commit.

use std::collections::BTreeSet;
use std::path::Path;

use crate::engine::{PlanOptions, plan_apply};
use crate::env::Env;
use crate::model::Scope;

use super::{GeneratedPaths, INVENTORY};

/// The first word of every line this check writes.
const NAME: &str = "render-inventory";

/// What the check found, one variant per keyed line it can open with.
#[derive(Debug, PartialEq, Eq)]
enum Finding {
    /// The checkout could not be planned, so what it renders is unknown.
    Unplanned { root: String, cause: String },
    /// The committed inventory is present and could not be read.
    Unreadable { cause: String },
    /// It is not one JSON array of path strings.
    Invalid { cause: String },
    /// It reads, and it is not the set this checkout renders.
    Drifted {
        /// Rendered here and not listed.
        missing: Vec<String>,
        /// Listed and rendered nowhere here.
        stale: Vec<String>,
    },
    /// It lists that set, and its bytes are not the document the writer
    /// lays down for it.
    Reflowed,
}

/// Whether the committed inventory is the set a pass renders.
#[derive(Debug, PartialEq, Eq)]
enum Standing {
    /// It lists every rendered path and nothing besides, laid out as the
    /// writer writes it.
    Current,
    /// It does not, and this is what the reader is handed.
    Refused(Finding),
}

/// The stable first line every message opens with: a key naming the
/// condition and the value acted on, `<name>: <key>=<value>`.
fn line(key: &str, value: &str) -> String {
    format!("{NAME}: {key}={value}\n")
}

/// Every line this check writes, and the only place its text lives.
///
/// The keyed line stands first, at position 1, and the English follows it. A
/// drifted inventory writes one keyed line per direction that holds, in the
/// order `missing`, `stale`, then names the paths under each and the command
/// that rewrites the file. What a call this check made wrote of its own is
/// carried in as the cause and replayed under the key, never ahead of it.
fn refusal(finding: &Finding) -> String {
    let mut text = String::new();
    match finding {
        Finding::Unplanned { root, cause } => {
            text.push_str(&line("unplanned", root));
            text.push_str(
                "this checkout could not be planned, so the set it renders is unknown; \
                 refusing rather than reading the committed inventory as current\n",
            );
            text.push_str(cause);
            text.push('\n');
        }
        Finding::Unreadable { cause } => {
            text.push_str(&line("unreadable", INVENTORY));
            text.push_str("the committed inventory is present and could not be read\n");
            text.push_str(cause);
            text.push('\n');
        }
        Finding::Invalid { cause } => {
            text.push_str(&line("invalid", INVENTORY));
            text.push_str(
                "the committed inventory is not one JSON array of path strings; refusing \
                 rather than reading it as a checkout that renders nothing\n",
            );
            text.push_str(cause);
            text.push('\n');
        }
        Finding::Drifted { missing, stale } => {
            if !missing.is_empty() {
                text.push_str(&line("missing", &missing.len().to_string()));
            }
            if !stale.is_empty() {
                text.push_str(&line("stale", &stale.len().to_string()));
            }
            if !missing.is_empty() {
                text.push_str(
                    "this checkout renders these paths and the committed inventory lists \
                     none of them, so every reader of it judges each as hand-written code:\n",
                );
                for path in missing {
                    text.push_str(&format!("  {path}\n"));
                }
            }
            if !stale.is_empty() {
                text.push_str(
                    "the committed inventory lists these paths and this checkout renders \
                     none of them, so each excludes a hand-written file from the scans \
                     that read it:\n",
                );
                for path in stale {
                    text.push_str(&format!("  {path}\n"));
                }
            }
            text.push_str(&rewrite());
        }
        Finding::Reflowed => {
            text.push_str(&line("reflowed", INVENTORY));
            text.push_str(
                "the committed inventory lists the set this checkout renders and is not \
                 laid out as the writer writes it, one entry per line in the set's order, \
                 so the next refresh rewrites it whole and any two branches adding \
                 renders conflict on its one line\n",
            );
            // A drift is repaired by any kendex that renders the same set;
            // this layout is written only by a kendex built from this
            // checkout, and the installed one that laid the file out this
            // way writes it that way again, so the refresh alone leaves the
            // finding standing.
            text.push_str(
                "the installed kendex that wrote it lays the set out this way, so install \
                 this checkout's own CLI first (AGENTS.md § Commands: `cargo build --release \
                 -p kendex-cli`, then copy the binary to `~/.cargo/bin/kendex`), then\n",
            );
            text.push_str(&rewrite());
        }
    }
    text
}

/// The remedy every finding a refresh repairs closes with.
fn rewrite() -> String {
    format!(
        "run `kendex refresh` at the checkout root, the one writer of {INVENTORY}, and \
         commit that file with this change\n"
    )
}

/// The committed inventory against the set the declaration renders at, and
/// then against the document the writer lays down for that set.
///
/// Both directions of the set are findings. A declared path the inventory
/// does not list reads as hand-written to every reader of it, and a path it
/// lists that nothing renders excludes a hand-written file from their scans.
/// The set standing is judged first so a drift is named by its entries, not
/// as bytes that differ; a copy holding the right set in another layout is
/// the third finding, since every reader parses the JSON and no set
/// comparison can see it. The bytes are held to the declared set's document
/// rather than the written set's, because in a lockless checkout the file
/// rightly lists the held positions the write leaves out, and holding it
/// to the written set's document would refuse exactly that checkout under
/// this finding.
///
/// `declared` is every position this pass writes and every one it held —
/// a position the declaration renders at whose bytes the pass would not
/// claim — in one set, so a held position is judged exactly as a written
/// one. A checkout without its lock holds every render whose bytes differ
/// from its source, and it holds the tree whole: a skill whose source
/// gained a file with no render lands every position of that tree here,
/// the unrendered one among them. Judged off the written set alone, the
/// held ones would each be named stale beside the one path the inventory
/// lacks; judged as neither, the unrendered one would pass unnamed, which
/// is the direction a gate may not fail in. The one reading this costs is
/// a checkout with its lock and a genuine conflict at a position a newly
/// declared item renders at: `refresh` never lists that position, so this
/// names it missing until the conflict is settled, which `refresh` itself
/// refuses on the same run. Red on a tree whose renders cannot be trusted
/// is the right answer there; green on an unrendered file is not.
fn judge(
    listed: &BTreeSet<String>,
    text: &str,
    declared: &BTreeSet<String>,
    document: &str,
) -> Standing {
    let missing: Vec<String> = declared.difference(listed).cloned().collect();
    let stale: Vec<String> = listed.difference(declared).cloned().collect();
    if !missing.is_empty() || !stale.is_empty() {
        return Standing::Refused(Finding::Drifted { missing, stale });
    }
    if text != document {
        return Standing::Refused(Finding::Reflowed);
    }
    Standing::Current
}

/// The committed inventory: its bytes, and the paths they list.
///
/// An absent file is no read failure: a checkout that renders anything is
/// owed one, so every rendered path comes back missing and the same refusal
/// names them. Present and unreadable, or present and not one JSON array of
/// path strings, refuses instead of reading as a checkout that renders
/// nothing — which would pass every drift silently.
fn committed(inventory: &Path) -> Result<(String, BTreeSet<String>), Finding> {
    let text = match crate::fs::read_if_exists(inventory) {
        Ok(Some(text)) => text,
        Ok(None) => return Ok((String::new(), BTreeSet::new())),
        Err(error) => {
            return Err(Finding::Unreadable {
                cause: error.to_string(),
            });
        }
    };
    let listed =
        serde_json::from_str::<BTreeSet<String>>(&text).map_err(|error| Finding::Invalid {
            cause: error.to_string(),
        })?;
    Ok((text, listed))
}

/// Plan `root` as `refresh` does, and hold the inventory at `inventory` to
/// what that pass renders and the document it would write for it. The plan
/// is taken and never executed, so the run writes nothing into the scope it
/// judges.
///
/// The inventory is a parameter rather than a path derived inside, so the
/// controls below drive this whole path — the read, the planned set, the
/// planned document and the comparison — against a planted inventory
/// instead of exercising `judge` alone, which would stay green if this
/// stopped reading either side. The
/// environment is one for the same reason: the lockless control plans a
/// fixture of its own through this path.
fn check_against(env: &Env, root: &Path, inventory: &Path) -> Standing {
    let unplanned = |cause: String| {
        Standing::Refused(Finding::Unplanned {
            root: crate::paths::slashed(root),
            cause,
        })
    };
    let scope = Scope::Project {
        root: root.to_path_buf(),
    };
    let report = match plan_apply(env, &scope, &PlanOptions::default()) {
        Ok(report) => report,
        Err(error) => return unplanned(error.to_string()),
    };
    let declared = GeneratedPaths::spelled(
        report
            .generated
            .inventory(root)
            .iter()
            .chain(&report.generated.held),
        root,
    );
    let document = match GeneratedPaths::laid_out(&declared, root) {
        Ok(document) => document,
        Err(error) => return unplanned(error.to_string()),
    };
    match committed(inventory) {
        Ok((text, listed)) => judge(&listed, &text, &declared, &document),
        Err(finding) => Standing::Refused(finding),
    }
}

/// A checkout held to the inventory committed in it.
fn check(root: &Path) -> Standing {
    let env = match Env::detect() {
        Ok(env) => env,
        Err(error) => {
            return Standing::Refused(Finding::Unplanned {
                root: crate::paths::slashed(root),
                cause: error.to_string(),
            });
        }
    };
    check_against(&env, root, &root.join(INVENTORY))
}

/// The check itself: this repository's `.kendex-generated.json` is the set
/// this repository renders, laid out as the writer writes it. The passing
/// direction, through the whole path.
#[test]
fn the_committed_inventory_is_the_set_this_checkout_renders() {
    let root = crate::test_util::checkout_root();
    match check(&root) {
        Standing::Current => {}
        Standing::Refused(finding) => panic!("{}", refusal(&finding)),
    }
}

/// A path no checkout renders, planted to prove the `stale` direction. The
/// leading dot makes it a name `kendex.toml` could not declare an item under.
const RENDERED_NOWHERE: &str = ".agents/skills/.nothing-renders-this/SKILL.md";

/// The refusing direction, through the same path the check above runs: this
/// checkout's own committed inventory with one real render taken out and one
/// entry nothing renders put in, read from a planted copy while the checkout
/// itself is planned untouched.
///
/// Both planted defects are asserted, in the finding and as the keyed line
/// each writes. The entry taken out is read off the committed inventory
/// rather than named here, so the control cannot drift from what this
/// repository actually renders.
#[test]
fn an_inventory_that_is_not_the_render_set_is_refused() {
    let root = crate::test_util::checkout_root();
    let (_, listed) = committed(&root.join(INVENTORY)).expect("the committed inventory reads");
    let removed = listed
        .iter()
        .find(|path| path.as_str() != INVENTORY)
        .expect("the committed inventory lists a render")
        .clone();

    let mut planted: BTreeSet<String> = listed.clone();
    assert!(planted.remove(&removed), "the entry chosen was listed");
    assert!(
        planted.insert(RENDERED_NOWHERE.to_owned()),
        "the planted entry was not already listed"
    );
    let tmp = tempfile::tempdir().expect("a scratch directory");
    let path = crate::test_util::rooted(&tmp).join(INVENTORY);
    std::fs::write(
        &path,
        serde_json::to_string(&planted).expect("the planted inventory serializes"),
    )
    .expect("the planted inventory is writable");

    let env = Env::detect().expect("the host environment is readable");
    let standing = check_against(&env, &root, &path);
    assert_eq!(
        standing,
        Standing::Refused(Finding::Drifted {
            missing: vec![removed],
            stale: vec![RENDERED_NOWHERE.to_owned()],
        })
    );
    let Standing::Refused(finding) = standing else {
        unreachable!("the assertion above pinned the variant")
    };
    let text = refusal(&finding);
    let mut lines = text.lines();
    assert_eq!(lines.next(), Some("render-inventory: missing=1"));
    assert_eq!(lines.next(), Some("render-inventory: stale=1"));
}

/// The layout direction, through the same path: this checkout's own
/// committed inventory, the right set to the entry, laid out on one line as
/// a writer that predates the one-entry-per-line document writes it, read
/// from a planted copy while the checkout itself is planned untouched.
///
/// A copy the set check passes and the layout check refuses is what a
/// contributor's older `kendex refresh` leaves behind, and what every reader
/// of the file, parsing it to a set, would wave through.
#[test]
fn an_inventory_laid_out_on_one_line_is_refused() {
    let root = crate::test_util::checkout_root();
    let (_, listed) = committed(&root.join(INVENTORY)).expect("the committed inventory reads");
    let tmp = tempfile::tempdir().expect("a scratch directory");
    let path = crate::test_util::rooted(&tmp).join(INVENTORY);
    let mut one_line = serde_json::to_string(&listed).expect("the planted inventory serializes");
    one_line.push('\n');
    std::fs::write(&path, one_line).expect("the planted inventory is writable");

    let env = Env::detect().expect("the host environment is readable");
    let standing = check_against(&env, &root, &path);
    assert_eq!(standing, Standing::Refused(Finding::Reflowed));
    let Standing::Refused(finding) = standing else {
        unreachable!("the assertion above pinned the variant")
    };
    let text = refusal(&finding);
    assert_eq!(
        text.lines().next(),
        Some("render-inventory: reflowed=.kendex-generated.json")
    );
    // The remedy must name the install step: the installed kendex that laid
    // the file out this way writes it that way again, so the refresh alone
    // cannot clear this finding.
    let install = text
        .find("cargo build --release -p kendex-cli")
        .expect("the reflowed remedy names the CLI install");
    let refresh = text
        .find("run `kendex refresh`")
        .expect("the reflowed remedy names the refresh");
    assert!(
        install < refresh,
        "the install step comes before the refresh"
    );
}

/// A project with one skill rendered from its local source and its
/// inventory written, on which each control makes the changes the
/// inventory has not seen.
struct Unrendered {
    _tmp: tempfile::TempDir,
    env: Env,
    root: std::path::PathBuf,
}

/// Where the lockless control's one missing render goes.
const UNRENDERED: &str = ".claude/skills/two/SKILL.md";

#[allow(
    clippy::expect_used,
    reason = "every expect here is a fixture precondition, not the behaviour under test"
)]
impl Unrendered {
    fn new() -> Unrendered {
        let tmp = tempfile::tempdir().expect("a scratch directory");
        let home = crate::test_util::rooted(&tmp);
        let env = Env::fake(&home, crate::env::FakeOs::Linux);
        std::fs::create_dir_all(home.join(".claude")).expect("the tool's home directory");
        let root = home.join("app");
        // A project the inventory write covers: `plan` writes it for a
        // repository root only.
        std::fs::create_dir_all(root.join(".git")).expect("the fixture repository");
        std::fs::create_dir_all(root.join(".claude")).expect("the tool's project directory");
        std::fs::write(
            root.join("kendex.toml"),
            "schema = 6\n\n[install]\nharnesses = [\"claude\"]\nmethod = \"copy\"\n",
        )
        .expect("the manifest is writable");
        let fixture = Unrendered {
            _tmp: tmp,
            env,
            root,
        };
        fixture.write_skill("one", "Body.\n");
        crate::apply::execute(&fixture.env, &fixture.add("one").plan)
            .expect("the first skill renders");
        fixture
    }

    /// The rendered skill's source edited, so its render differs from its
    /// source: what a lockless checkout holds and a locked one lists. Then
    /// a second skill declared and rendered nowhere, missing either way.
    /// The one-file skill keeps the missing set to the path the
    /// declaration adds.
    fn with_a_second_skill_unrendered(self) -> Unrendered {
        let fixture = self.with_the_skill_edited();
        fixture.write_skill("two", "Body.\n");
        fixture.declare("two");
        fixture
    }

    /// The rendered skill's source edited and nothing else changed: with the
    /// lock the render is stale and listed, without it the render is held,
    /// and the inventory the apply wrote lists it either way.
    fn with_the_skill_edited(self) -> Unrendered {
        self.write_skill("one", "Edited body.\n");
        self
    }

    /// The rendered skill's source gains a file with no render. The tree
    /// as a whole now differs from its source, so a lockless checkout
    /// holds every position in it, the unrendered one included.
    fn with_a_file_added_to_the_skill(self) -> Unrendered {
        let dir = crate::source::local_source_root(&self.env, &self.scope()).join("skills/one");
        std::fs::write(dir.join("notes.md"), "Notes.\n").expect("the added file is writable");
        self
    }

    fn scope(&self) -> Scope {
        Scope::Project {
            root: self.root.clone(),
        }
    }

    fn write_skill(&self, name: &str, body: &str) {
        let dir = crate::source::local_source_root(&self.env, &self.scope())
            .join("skills")
            .join(name);
        std::fs::create_dir_all(&dir).expect("the skill's source directory");
        std::fs::write(
            dir.join("SKILL.md"),
            format!("---\nname: {name}\n---\n{body}"),
        )
        .expect("the skill's source is writable");
    }

    /// Declare `name` from the local source in the manifest alone, the
    /// way a commit that forgot its render leaves the tree.
    fn declare(&self, name: &str) {
        let path = crate::manifest::manifest_path(&self.env, &self.scope());
        let mut manifest = crate::manifest::load_for_mutation(&path)
            .expect("the manifest reads")
            .expect("the first add wrote the manifest");
        manifest.declared_mut(crate::model::ItemKind::Skill).insert(
            name.to_owned(),
            crate::manifest::ItemDecl::from_source(crate::manifest::LOCAL_SOURCE_NAME),
        );
        crate::manifest::save(&path, &manifest).expect("the manifest is writable");
    }

    /// The plan that declares and renders `name` from the local source.
    fn add(&self, name: &str) -> crate::engine::EngineReport {
        crate::engine::ops::add(
            &self.env,
            &self.scope(),
            &crate::engine::ops::AddRequest {
                source: Some(crate::manifest::LOCAL_SOURCE_NAME.to_owned()),
                skills: vec![name.to_owned()],
                ..crate::engine::ops::AddRequest::default()
            },
        )
        .unwrap_or_else(|error| panic!("declaring {name}: {error}"))
    }

    fn lock(&self) -> std::path::PathBuf {
        crate::lock::lock_path(&self.env, &self.scope())
    }

    /// The finding, and the keyed lines it opens with.
    fn checked(&self) -> (Standing, Vec<String>) {
        let standing = check_against(&self.env, &self.root, &self.root.join(INVENTORY));
        let lines = match &standing {
            Standing::Current => Vec::new(),
            Standing::Refused(finding) => refusal(finding)
                .lines()
                .take_while(|line| line.starts_with(NAME))
                .map(str::to_owned)
                .collect(),
        };
        (standing, lines)
    }
}

/// The finding a fixture is owed, with its lock or without: the one path
/// nothing renders, and no render named stale because its bytes moved.
fn one_missing(path: &str) -> (Standing, Vec<String>) {
    (
        Standing::Refused(Finding::Drifted {
            missing: vec![path.to_owned()],
            stale: Vec::new(),
        }),
        vec!["render-inventory: missing=1".to_owned()],
    )
}

/// The finding with the lock, then the same finding with it taken away.
#[allow(
    clippy::expect_used,
    reason = "taking the lock away is a fixture step, not the behaviour under test"
)]
fn with_and_without_the_lock(fixture: &Unrendered, expected: (Standing, Vec<String>)) {
    assert_eq!(fixture.checked(), expected, "with the lock");
    std::fs::remove_file(fixture.lock()).expect("the lock is there to take away");
    assert_eq!(fixture.checked(), expected, "without the lock");
}

/// The lockless control: with nothing saying the bytes on disk are kendex's
/// own, the edited skill's render is held rather than listed as rendered,
/// and the check still names the one path the inventory lacks and nothing
/// else. The inverse plans the same tree with its lock, where the edited
/// render is stale rather than held, and pins the same line.
#[test]
fn a_lockless_checkout_names_the_missing_render_alone() {
    let fixture = Unrendered::new().with_a_second_skill_unrendered();
    with_and_without_the_lock(&fixture, one_missing(UNRENDERED));
}

/// The held tree's own unrendered position: a lockless checkout holds the
/// whole skill once one file in it is unrendered, and the check names that
/// file missing rather than passing a tree it could not judge. The inverse
/// plans the same tree with its lock, where the skill is stale and the
/// file is missing by the written set alone, and pins the same line.
#[test]
fn a_lockless_checkout_names_an_unrendered_file_of_a_held_skill() {
    let fixture = Unrendered::new().with_a_file_added_to_the_skill();
    with_and_without_the_lock(&fixture, one_missing(".claude/skills/one/notes.md"));
}

/// The layout hold on a lockless checkout that is current: the inventory the
/// apply wrote lists the held render, so its bytes are the declared set's
/// document and not the written set's, which leaves the held position out.
/// Held to the written set's document, this checkout would be refused as
/// reflowed on a file the writer itself laid down. The inverse plans the
/// same tree with its lock, where the render is listed as written.
#[test]
fn a_lockless_checkout_holding_the_declared_set_is_current() {
    let fixture = Unrendered::new().with_the_skill_edited();
    with_and_without_the_lock(&fixture, (Standing::Current, Vec::new()));
}
