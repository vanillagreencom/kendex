//! The About report: what a marketplace was found to offer, where, and
//! everything wrong with it — one typed summary the About tab and
//! `kendex index` consume.

use std::collections::BTreeMap;

use crate::model::ItemKind;
use crate::names;
use crate::source_read::SealedSource;

use super::SourceConfig;
use super::discover::CatalogMode;
use super::plugin_registry::CatalogFinding;

/// What was found under one root: "12 skills under `skills/`".
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct RootCount {
    pub root: String,
    pub kind: ItemKind,
    pub count: usize,
}

/// The typed summary the About tab and `kendex index` consume.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct AboutReport {
    pub mode: CatalogMode,
    pub found: Vec<RootCount>,
    pub findings: Vec<CatalogFinding>,
}

/// The About report: what was found where, plus every finding, whatever the
/// mode. Kinds beyond skills are counted only where they are really offered
/// for browsing — a `hooks/` folder in a repo that never declared kendex's
/// layout is repository tooling, not installable content.
pub fn about(sealed: &SealedSource, config: &SourceConfig) -> AboutReport {
    let mut found = Vec::new();
    match config.mode {
        CatalogMode::Unusable => {}
        CatalogMode::PluginRegistry => {
            if let Some(registry) = &config.plugin_registry {
                for kind in [ItemKind::Agent, ItemKind::Command, ItemKind::Skill] {
                    let mut per_plugin: BTreeMap<&str, usize> = BTreeMap::new();
                    for item in super::catalog::items(sealed, registry, kind) {
                        if let Some((plugin, _)) = names::split(&item)
                            && let Some(entry) = registry.entry(plugin)
                        {
                            *per_plugin.entry(&entry.name).or_default() += 1;
                        }
                    }
                    for (plugin, count) in per_plugin {
                        found.push(RootCount {
                            root: format!("plugin {plugin}"),
                            kind,
                            count,
                        });
                    }
                }
            }
        }
        CatalogMode::Explicit | CatalogMode::Discovered => {
            match config.mode {
                CatalogMode::Explicit => {
                    for dir in &config.skill_dirs {
                        push_count(
                            &mut found,
                            dir,
                            ItemKind::Skill,
                            super::layout::flat_skills(sealed, dir).len(),
                        );
                    }
                }
                _ => {
                    let mut per_root: BTreeMap<&str, usize> = BTreeMap::new();
                    for skill in &config.discovery.skills {
                        *per_root.entry(&skill.root).or_default() += 1;
                    }
                    for (root, count) in per_root {
                        push_count(&mut found, root, ItemKind::Skill, count);
                    }
                }
            }
            for dir in &config.agent_dirs {
                push_count(
                    &mut found,
                    dir,
                    ItemKind::Agent,
                    super::layout::agent_stems(sealed, dir).len(),
                );
            }
            if config.mode == CatalogMode::Explicit {
                for kind in [ItemKind::Hook, ItemKind::Command, ItemKind::McpServer] {
                    let (dir, ext) = super::layout::fixed_kind_dir(kind);
                    push_count(
                        &mut found,
                        dir,
                        kind,
                        super::layout::file_stems(sealed, dir, ext).len(),
                    );
                }
            }
        }
    }
    AboutReport {
        mode: config.mode,
        found,
        findings: config.findings().cloned().collect(),
    }
}

fn push_count(found: &mut Vec<RootCount>, root: &str, kind: ItemKind, count: usize) {
    if count > 0 {
        found.push(RootCount {
            root: root.to_owned(),
            kind,
            count,
        });
    }
}
