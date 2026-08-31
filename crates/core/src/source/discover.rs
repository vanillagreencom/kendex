//! Flexible discovery: any repository holding skills is a marketplace.
//!
//! The search table below is a closed, versioned list — recognized, never
//! guessed. It yields skills only: hooks, MCP servers, commands and agents
//! install from kendex's own layout dirs, `kendex.toml`, or a plugin
//! registry, because executable content must not be discovered into
//! existence. Every probe goes through [`SealedSource`], so symlinks are
//! never followed and every read is budgeted.

use std::collections::{BTreeMap, BTreeSet};
use std::path::{Path, PathBuf};

use crate::error::Result;
use crate::names;
use crate::source_read::SealedSource;

use super::plugin_registry::CatalogFinding;

/// Part of the safety-cache key: a new table can change what a repository
/// offers, so cached verdicts must not outlive the table that produced them.
pub const DISCOVERY_VERSION: u32 = 1;

/// The closed table of directories searched for skills. `skills/` and its
/// `.curated` shelf are skills.sh conventions; the dot-dirs are each
/// harness's project skills directory, pinned to the adapters by test
/// (`.codex/skills` is kept although codex itself reads `.agents/skills`,
/// because repositories in the wild ship it).
const SKILL_ROOTS: [&str; 9] = [
    "skills",
    "skills/.curated",
    ".claude/skills",
    ".agents/skills",
    ".codex/skills",
    ".cursor/skills",
    ".opencode/skills",
    ".gemini/skills",
    ".github/skills",
];

/// A skill directory may sit this many levels below its root — one category
/// folder or two, never a whole-repo crawl.
const MAX_NEST: usize = 3;

/// Directory names that are never catalog content.
const SKIP_DIRS: [&str; 6] = [".git", "node_modules", "target", "dist", "build", ".venv"];

/// More skills than any real catalog ships; past it the walk stops with a
/// finding rather than letting a hostile tree soak the scan.
const MAX_SKILLS: usize = 512;

/// The first bytes of a git-lfs pointer file — the content is elsewhere.
const LFS_POINTER: &str = "version https://git-lfs.github.com/spec/";

/// One skill the search table found.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct DiscoveredSkill {
    /// The name it installs under — its directory name, or for a repo-root
    /// skill its validated frontmatter name (else the caller's display name,
    /// since a store directory is a commit id).
    pub name: String,
    /// Repository-relative, normalized — the dedup identity. Empty for a
    /// repo-root skill.
    pub rel: PathBuf,
    /// The table entry that found it, as the About report prints it.
    pub root: String,
}

/// Everything the search table found, and everything wrong with it.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct Discovery {
    pub skills: Vec<DiscoveredSkill>,
    pub findings: Vec<CatalogFinding>,
}

/// How a source's items were decided — the fixed precedence: a plugin
/// registry wins outright, else a parsed control file's declared layout
/// (`[catalog]` overriding which dirs), else the search table; a broken
/// control file makes the source unusable, never a different mode.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq, serde::Serialize, specta::Type)]
#[serde(rename_all = "kebab-case")]
pub enum CatalogMode {
    PluginRegistry,
    Explicit,
    #[default]
    Discovered,
    Unusable,
}

/// Run the search table over a source. `display` names a repo-root skill
/// that does not name itself: the repository leaf, passed in because the
/// store directory the source resolves to is a commit id.
mod realities;
use realities::{frontmatter_name, submodule_findings};

pub fn discover(sealed: &SealedSource, display: &str) -> Result<Discovery> {
    let mut walk = Walk {
        sealed,
        discovery: Discovery::default(),
        taken_rels: BTreeSet::new(),
        taken_names: BTreeMap::new(),
        poisoned_names: BTreeSet::new(),
        full: false,
    };
    for root in SKILL_ROOTS {
        let abs = sealed.root().join(root);
        if sealed.is_dir(&abs) {
            walk.dir(root, &abs, &PathBuf::from(root), 1)?;
        }
    }
    walk.root_skill(display)?;
    submodule_findings(sealed, &mut walk.discovery.findings)?;
    Ok(walk.discovery)
}

struct Walk<'a> {
    sealed: &'a SealedSource,
    discovery: Discovery,
    taken_rels: BTreeSet<PathBuf>,
    /// Folded name → (name, location, rel path) — what a second spelling
    /// collides with, and where its bytes are so an identical copy under a
    /// second recognized root can be recognized as one item, not a collision.
    /// The bytes are hashed only when a clash actually happens, never for every
    /// skill: a clean repository never pays for the comparison.
    taken_names: BTreeMap<String, (String, String, PathBuf)>,
    /// Folded names a real collision disqualified: both spellings are skipped,
    /// so traversal order can never decide which of two clashing skills wins.
    poisoned_names: BTreeSet<String>,
    full: bool,
}

impl Walk<'_> {
    fn dir(&mut self, root: &str, dir: &Path, rel: &Path, depth: usize) -> Result<()> {
        // Once the cap is hit the walk stops rather than reading the rest of a
        // hostile tree: the bound is on the work, not just the output, so a
        // repository of a million directories costs the cap, not the tree.
        if self.full {
            return Ok(());
        }
        for path in self.sealed.entries(dir)? {
            if self.full {
                break;
            }
            let Some(name) = path.file_name() else {
                continue;
            };
            let Some(name) = name.to_str() else {
                self.discovery.findings.push(CatalogFinding::new(
                    crate::paths::slashed(rel),
                    format!(
                        "`{}` is not a UTF-8 name, which no harness can load",
                        names::shown(&name.to_string_lossy())
                    ),
                    "rename the entry to plain UTF-8",
                ));
                continue;
            };
            if name.starts_with('.') || SKIP_DIRS.contains(&name) || !self.sealed.is_dir(&path) {
                continue;
            }
            let rel = rel.join(name);
            if self.sealed.is_file(&path.join("SKILL.md")) {
                // Stop below a found skill: its subtree is content, not more
                // skills.
                self.take(root, name, &rel)?;
            } else if depth < MAX_NEST {
                self.dir(root, &path, &rel, depth + 1)?;
            }
        }
        Ok(())
    }

    fn take(&mut self, root: &str, name: &str, rel: &Path) -> Result<()> {
        // Built from directory entries, so anything but plain components is
        // an escape attempt — refused, named, never resolved.
        if rel.is_absolute()
            || !rel
                .components()
                .all(|c| matches!(c, std::path::Component::Normal(_)))
        {
            self.discovery.findings.push(CatalogFinding::new(
                names::shown(&crate::paths::slashed(rel)),
                "this path leads out of the repository".to_owned(),
                "keep every skill in a plain directory under a recognized root",
            ));
            return Ok(());
        }
        // Bound the retained paths as well as the output: the cap is checked
        // before this skill's path is remembered, so a hostile tree cannot
        // grow the dedup set past the cap.
        if self.discovery.skills.len() >= MAX_SKILLS {
            self.full = true;
            self.discovery.findings.push(CatalogFinding::new(
                root.to_owned(),
                format!("more than {MAX_SKILLS} skills — the rest are not read"),
                "split the repository; no real catalog ships this many",
            ));
            return Ok(());
        }
        // One directory reachable under two recognized roots is one item.
        if !self.taken_rels.insert(rel.to_path_buf()) {
            return Ok(());
        }
        let location = crate::paths::slashed(rel);
        if let Some(problem) = names::segment_problem(name) {
            self.discovery.findings.push(CatalogFinding::new(
                location,
                format!("this skill cannot be installed: {problem}"),
                "rename the directory",
            ));
            return Ok(());
        }
        let fold = names::fold(name);
        if self.poisoned_names.contains(&fold) {
            // A prior collision already disqualified this name; every further
            // spelling of it is skipped too, never quietly installed.
            self.discovery.findings.push(CatalogFinding::new(
                location.clone(),
                format!(
                    "`{}` folds to a name that clashes elsewhere — skipped",
                    names::shown(name)
                ),
                "rename it so it differs by more than case",
            ));
            return Ok(());
        }
        if let Some((taken, at, taken_rel)) = self.taken_names.get(&fold).cloned() {
            // The same directory served under two recognized roots — a repo
            // that offers one skill to two harness layouts — hashes the same
            // and is one item, deduplicated in silence. Different bytes under a
            // clashing name is a real collision: neither installs, so the order
            // the tree happened to be walked in cannot pick the winner. A tree
            // that will not hash (a symlink inside it) cannot be proven equal,
            // so it counts as a clash.
            let same = match (
                self.sealed.hash_tree(&self.sealed.root().join(rel)),
                self.sealed.hash_tree(&self.sealed.root().join(&taken_rel)),
            ) {
                (Ok(a), Ok(b)) => a == b,
                _ => false,
            };
            if same {
                return Ok(());
            }
            self.poisoned_names.insert(fold.clone());
            self.discovery
                .skills
                .retain(|s| names::fold(&s.name) != fold);
            self.discovery.findings.push(CatalogFinding::new(
                location.clone(),
                format!(
                    "`{}` (here) and `{taken}` (at `{at}`) fold to one name on a case-folding filesystem — both are skipped",
                    names::shown(name)
                ),
                "rename one so they differ by more than case",
            ));
            return Ok(());
        }
        let Some(text) = self.skill_md_text(&location, rel.join("SKILL.md"))? else {
            return Ok(());
        };
        if let Some(stated) = frontmatter_name(&text)
            && stated != name
        {
            self.discovery.findings.push(CatalogFinding::new(
                location.clone(),
                format!(
                    "the frontmatter names this skill `{}` and its directory is `{}` — the directory name is the identity",
                    names::shown(&stated),
                    names::shown(name)
                ),
                "rename the directory or the frontmatter so they agree",
            ));
        }
        self.taken_names
            .insert(fold, (name.to_owned(), location, rel.to_path_buf()));
        self.discovery.skills.push(DiscoveredSkill {
            name: name.to_owned(),
            rel: rel.to_path_buf(),
            root: root.to_owned(),
        });
        Ok(())
    }

    /// A `SKILL.md` at the repository root is a one-skill repo, named by its
    /// own frontmatter when that name is installable, else by `display`.
    fn root_skill(&mut self, display: &str) -> Result<()> {
        let location = "SKILL.md";
        if !self.sealed.is_file(&self.sealed.root().join(location)) {
            return Ok(());
        }
        let Some(text) = self.skill_md_text(location, PathBuf::from(location))? else {
            return Ok(());
        };
        let name = match frontmatter_name(&text) {
            Some(name) if names::segment_problem(&name).is_none() => name,
            Some(name) => {
                self.discovery.findings.push(CatalogFinding::new(
                    location,
                    format!(
                        "`{}` cannot be an installed name: {}",
                        names::shown(&name),
                        names::segment_problem(&name).unwrap_or_default()
                    ),
                    "give the frontmatter `name` a plain spelling",
                ));
                display.to_owned()
            }
            None => display.to_owned(),
        };
        if names::segment_problem(&name).is_some() {
            // Neither the file nor the repository offers an installable
            // name; there is nothing to call this skill.
            self.discovery.findings.push(CatalogFinding::new(
                location,
                "this repository's one skill has no installable name".to_owned(),
                "add `name:` to the SKILL.md frontmatter",
            ));
            return Ok(());
        }
        let fold = names::fold(&name);
        if let Some((taken, at, _)) = self.taken_names.get(&fold).cloned() {
            // Both spellings are skipped, so which the walk reached first can
            // never decide the winner.
            self.poisoned_names.insert(fold.clone());
            self.discovery
                .skills
                .retain(|s| names::fold(&s.name) != fold);
            self.discovery.findings.push(CatalogFinding::new(
                location,
                format!(
                    "the repository root skill folds to `{taken}` (at `{at}`) — both are skipped"
                ),
                "rename one of the two",
            ));
            return Ok(());
        }
        self.discovery.skills.push(DiscoveredSkill {
            name,
            rel: PathBuf::new(),
            root: "repository root".to_owned(),
        });
        Ok(())
    }

    /// The SKILL.md's text, or `None` with a finding for the git realities
    /// that mean the content is not really here.
    fn skill_md_text(&mut self, location: &str, skill_md: PathBuf) -> Result<Option<String>> {
        let text = match self.sealed.read(&self.sealed.root().join(&skill_md)) {
            Ok(bytes) => String::from_utf8_lossy(&bytes).into_owned(),
            Err(problem) => {
                self.discovery.findings.push(CatalogFinding::new(
                    location.to_owned(),
                    format!("SKILL.md could not be read: {problem}"),
                    "keep SKILL.md a plain text file within the catalog budgets",
                ));
                return Ok(None);
            }
        };
        if text.starts_with(LFS_POINTER) {
            self.discovery.findings.push(CatalogFinding::new(
                location.to_owned(),
                "SKILL.md is a git-lfs pointer — the content is not here".to_owned(),
                "commit the file itself; LFS content is not hydrated",
            ));
            return Ok(None);
        }
        Ok(Some(text))
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::env::{Env, FakeOs};
    use crate::harness::{Surface, all_adapters};
    use crate::model::ItemKind;

    /// The table is closed but not blind: every project skills directory a
    /// harness adapter really reads is in it.
    #[test]
    fn the_search_table_covers_every_adapters_project_skills_dir() {
        let env = Env::fake("/nowhere", FakeOs::Linux);
        for adapter in all_adapters() {
            for surface in adapter.project_surfaces(ItemKind::Skill, Path::new(""), &env) {
                let Surface::SubdirPerItem { dir, .. } = surface else {
                    continue;
                };
                let dir = crate::paths::slashed(&dir);
                assert!(
                    SKILL_ROOTS.contains(&dir.as_str()),
                    "{} reads project skills from {dir}, which the search table misses",
                    adapter.id().name()
                );
            }
        }
    }
}
