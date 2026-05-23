use crate::skill::Skill;
use std::collections::HashMap;

use super::multiselect::{ItemGroup, Scope, SelectItem, Tab, TabKind};

pub(super) struct InstalledInfo {
    pub scope: Scope,
    pub harnesses: Vec<String>,
    pub kind: Option<crate::config::ItemKind>,
    pub installed_at: String,
    /// Lock entry from whichever scope was loaded first (for legacy callers).
    pub lock_entry: crate::config::LockEntry,
    /// Lock entry from the project scope (if installed there).
    pub project_entry: Option<crate::config::LockEntry>,
    /// Lock entry from the global scope (if installed there).
    pub global_entry: Option<crate::config::LockEntry>,
    /// True if any installed copy is stale relative to its source.
    pub outdated: bool,
}

pub(super) type InstalledState = HashMap<String, InstalledInfo>;

pub(super) fn load_installed_state() -> InstalledState {
    let mut state = InstalledState::new();

    let project_lock = crate::config::lock_file_path(false);
    if let Ok(lock) = crate::config::LockFile::load(&project_lock) {
        for (name, entry) in &lock.entries {
            let outdated = crate::config::is_source_changed(entry);
            state.insert(
                name.clone(),
                InstalledInfo {
                    scope: Scope::Project,
                    harnesses: entry.harnesses.clone(),
                    kind: Some(entry.kind),
                    installed_at: entry.installed_at.clone(),
                    lock_entry: entry.clone(),
                    project_entry: Some(entry.clone()),
                    global_entry: None,
                    outdated,
                },
            );
        }
    }

    let global_lock = crate::config::lock_file_path(true);
    if let Ok(lock) = crate::config::LockFile::load(&global_lock) {
        for (name, entry) in &lock.entries {
            let outdated = crate::config::is_source_changed(entry);
            state
                .entry(name.clone())
                .and_modify(|info| {
                    info.scope = info.scope.merge_with_global();
                    if entry.installed_at < info.installed_at {
                        info.installed_at = entry.installed_at.clone();
                    }
                    for h in &entry.harnesses {
                        if !info.harnesses.contains(h) {
                            info.harnesses.push(h.clone());
                        }
                    }
                    info.global_entry = Some(entry.clone());
                    info.outdated = info.outdated || outdated;
                })
                .or_insert(InstalledInfo {
                    scope: Scope::Global,
                    harnesses: entry.harnesses.clone(),
                    kind: Some(entry.kind),
                    installed_at: entry.installed_at.clone(),
                    lock_entry: entry.clone(),
                    project_entry: None,
                    global_entry: Some(entry.clone()),
                    outdated,
                });
        }
    }

    state
}

pub(super) fn build_item_tabs(
    items: &super::DiscoveredItems,
    dep_display: &HashMap<String, String>,
    installed: &InstalledState,
    cli_update: Option<&str>,
) -> Vec<Tab> {
    let mut tabs = Vec::new();

    if !items.agents.is_empty() {
        let mut engineers = Vec::new();
        let mut analysts = Vec::new();
        let mut reviewers = Vec::new();
        let mut managers = Vec::new();

        for a in &items.agents {
            let info = installed.get(&a.name);
            let item = SelectItem {
                label: a.name.clone(),
                description: a.description.clone(),
                selected: false,
                suffix: None,
                locked: false,
                installed: info.is_some(),
                installed_scope: info.map(|i| i.scope),
                outdated: info.is_some_and(|i| i.outdated),
                kind: Some(crate::config::ItemKind::Agent),
                search_haystack: String::new(),
            };
            match a.role {
                crate::agent::AgentRole::Engineer => engineers.push(item),
                crate::agent::AgentRole::Analyst => analysts.push(item),
                crate::agent::AgentRole::Reviewer => reviewers.push(item),
                crate::agent::AgentRole::Manager => managers.push(item),
            }
        }

        let mut groups = Vec::new();
        if !engineers.is_empty() {
            groups.push(ItemGroup {
                label: "Engineers".into(),
                items: engineers,
            });
        }
        if !analysts.is_empty() {
            groups.push(ItemGroup {
                label: "Analysts".into(),
                items: analysts,
            });
        }
        if !reviewers.is_empty() {
            groups.push(ItemGroup {
                label: "Reviewers".into(),
                items: reviewers,
            });
        }
        if !managers.is_empty() {
            groups.push(ItemGroup {
                label: "Managers".into(),
                items: managers,
            });
        }

        tabs.push(Tab {
            name: "Agents".into(),
            kind: TabKind::Source,
            groups,
        });
    }

    if !items.skills.is_empty() {
        let mut rust = Vec::new();
        let mut perf = Vec::new();
        let mut ui = Vec::new();
        let mut workflow = Vec::new();

        for s in &items.skills {
            let info = installed.get(&s.name);
            let item = SelectItem {
                label: s.name.clone(),
                description: s.description.clone(),
                selected: false,
                suffix: dep_display.get(&s.name).cloned(),
                locked: false,
                installed: info.is_some(),
                installed_scope: info.map(|i| i.scope),
                outdated: info.is_some_and(|i| i.outdated),
                kind: Some(crate::config::ItemKind::Skill),
                search_haystack: String::new(),
            };

            if s.name.starts_with("rust-") {
                rust.push(item);
            } else if s.name.starts_with("perf-") {
                perf.push(item);
            } else if matches!(
                s.name.as_str(),
                "iced-rs" | "price-handling" | "trading-design"
            ) {
                ui.push(item);
            } else {
                workflow.push(item);
            }
        }

        let mut groups = Vec::new();
        if !rust.is_empty() {
            groups.push(ItemGroup {
                label: "Rust".into(),
                items: rust,
            });
        }
        if !perf.is_empty() {
            groups.push(ItemGroup {
                label: "Performance".into(),
                items: perf,
            });
        }
        if !ui.is_empty() {
            groups.push(ItemGroup {
                label: "UI / Domain".into(),
                items: ui,
            });
        }
        if !workflow.is_empty() {
            groups.push(ItemGroup {
                label: "Workflow".into(),
                items: workflow,
            });
        }

        tabs.push(Tab {
            name: "Skills".into(),
            kind: TabKind::Source,
            groups,
        });
    }

    if !items.hooks.is_empty() {
        let items_list: Vec<SelectItem> = items
            .hooks
            .iter()
            .map(|h| {
                let info = installed.get(&h.name);
                SelectItem {
                    label: h.name.clone(),
                    description: h.description.clone(),
                    selected: false,
                    suffix: Some(h.event.clone()),
                    locked: false,
                    installed: info.is_some(),
                    installed_scope: info.map(|i| i.scope),
                    outdated: info.is_some_and(|i| i.outdated),
                    kind: Some(crate::config::ItemKind::Hook),
                    search_haystack: String::new(),
                }
            })
            .collect();

        tabs.push(Tab {
            name: "Hooks".into(),
            kind: TabKind::Source,
            groups: vec![ItemGroup {
                label: String::new(),
                items: items_list,
            }],
        });
    }

    if !items.pi_extensions.is_empty() {
        let items_list: Vec<SelectItem> = items
            .pi_extensions
            .iter()
            .map(|ext| {
                let info = installed.get(&ext.name);
                // Pi packages don't bump package.json#version on every change
                // (it's an npm convention we don't actively use), so showing
                // it here is misleading next to the hash-based outdated dot.
                let suffix = None;
                SelectItem {
                    label: ext.name.clone(),
                    description: if ext.description.is_empty() {
                        "Pi package".into()
                    } else {
                        ext.description.clone()
                    },
                    selected: false,
                    suffix,
                    locked: false,
                    installed: info.is_some(),
                    installed_scope: info.map(|i| i.scope),
                    outdated: info.is_some_and(|i| i.outdated),
                    kind: Some(crate::config::ItemKind::PiExtension),
                    search_haystack: String::new(),
                }
            })
            .collect();

        tabs.push(Tab {
            name: "Pi Packages".into(),
            kind: TabKind::Source,
            groups: vec![ItemGroup {
                label: String::new(),
                items: items_list,
            }],
        });
    }

    if let Some(installed_tab) = build_installed_tab(installed) {
        tabs.push(installed_tab);
    }

    let mut update_items: Vec<SelectItem> = Vec::new();
    for tab in &tabs {
        if tab.kind != TabKind::Source {
            continue;
        }
        for group in &tab.groups {
            for item in &group.items {
                if item.outdated {
                    let mut clone = item.clone();
                    clone.selected = false;
                    update_items.push(clone);
                }
            }
        }
    }

    if let Some(info) = cli_update {
        update_items.push(SelectItem {
            label: "vstack (cli)".into(),
            description: format!("Binary update: {info}"),
            selected: false,
            suffix: Some("binary".into()),
            locked: false,
            installed: true,
            installed_scope: Some(Scope::Global),
            outdated: true,
            kind: None,
            search_haystack: String::new(),
        });
    }

    if !update_items.is_empty() {
        let content_items: Vec<SelectItem> = update_items
            .iter()
            .filter(|i| i.label != "vstack (cli)")
            .cloned()
            .collect();
        let cli_items: Vec<SelectItem> = update_items
            .into_iter()
            .filter(|i| i.label == "vstack (cli)")
            .collect();

        let mut groups = Vec::new();
        if !content_items.is_empty() {
            groups.push(ItemGroup {
                label: "Content".into(),
                items: content_items,
            });
        }
        if !cli_items.is_empty() {
            groups.push(ItemGroup {
                label: "CLI".into(),
                items: cli_items,
            });
        }

        let count: usize = groups.iter().map(|g| g.items.len()).sum();
        tabs.insert(
            0,
            Tab {
                name: format!("Updates ({count})"),
                kind: TabKind::Updates,
                groups,
            },
        );
    }

    if let Some(dup_tab) = build_duplicates_tab(installed) {
        tabs.insert(0, dup_tab);
    }

    tabs
}

fn kind_bucket(kind: Option<crate::config::ItemKind>) -> &'static str {
    match kind {
        Some(crate::config::ItemKind::Agent) => "Agents",
        Some(crate::config::ItemKind::Hook) => "Hooks",
        Some(crate::config::ItemKind::PiExtension) => "Pi Packages",
        Some(crate::config::ItemKind::Extra) => "Extras",
        _ => "Skills",
    }
}

const KIND_ORDER: &[&str] = &["Agents", "Skills", "Hooks", "Pi Packages", "Extras"];

fn build_installed_tab(installed: &InstalledState) -> Option<Tab> {
    if installed.is_empty() {
        return None;
    }

    let mut buckets: HashMap<(&'static str, &'static str), Vec<SelectItem>> = HashMap::new();

    let mut sorted: Vec<_> = installed.iter().collect();
    sorted.sort_by_key(|(name, _)| name.as_str());

    for (name, info) in sorted {
        let h = info.harnesses.join(", ");
        let scope_str = info.scope.title_label();
        let item = SelectItem {
            label: name.clone(),
            description: format!("[{h}]"),
            selected: false,
            suffix: None,
            locked: false,
            installed: true,
            installed_scope: Some(info.scope),
            outdated: info.outdated,
            kind: info.kind,
            search_haystack: String::new(),
        };
        buckets
            .entry((scope_str, kind_bucket(info.kind)))
            .or_default()
            .push(item);
    }

    let mut groups = Vec::new();
    for scope in ["Project", "Global", "Both"] {
        for kind in KIND_ORDER {
            if let Some(items) = buckets.remove(&(scope, *kind))
                && !items.is_empty()
            {
                groups.push(ItemGroup {
                    label: format!("{scope} / {kind}"),
                    items,
                });
            }
        }
    }

    if groups.is_empty() {
        None
    } else {
        Some(Tab {
            name: "Installed".into(),
            kind: TabKind::Installed,
            groups,
        })
    }
}

fn build_duplicates_tab(installed: &InstalledState) -> Option<Tab> {
    let mut sorted: Vec<_> = installed
        .iter()
        .filter(|(_, info)| info.scope == Scope::Both)
        .collect();
    if sorted.is_empty() {
        return None;
    }
    sorted.sort_by_key(|(name, _)| name.as_str());

    let mut buckets: HashMap<&'static str, Vec<SelectItem>> = HashMap::new();
    for (name, info) in sorted {
        let proj_hash = info
            .project_entry
            .as_ref()
            .map(|e| e.source_hash.as_str())
            .unwrap_or("");
        let global_hash = info
            .global_entry
            .as_ref()
            .map(|e| e.source_hash.as_str())
            .unwrap_or("");
        let proj_when = info
            .project_entry
            .as_ref()
            .map(|e| e.installed_at.as_str())
            .unwrap_or("");
        let global_when = info
            .global_entry
            .as_ref()
            .map(|e| e.installed_at.as_str())
            .unwrap_or("");
        let identical = proj_hash == global_hash && !proj_hash.is_empty();
        let mut suffix_parts: Vec<String> = Vec::new();
        if identical {
            suffix_parts.push("identical".to_string());
        } else {
            let newer = if proj_when > global_when {
                "project newer"
            } else if global_when > proj_when {
                "global newer"
            } else {
                "differs"
            };
            suffix_parts.push(newer.to_string());
        }
        suffix_parts.push(crate::config::ItemKind::label_short_or_item(info.kind).to_string());
        let item = SelectItem {
            label: name.clone(),
            description: format!("project + global · {}", info.harnesses.join(", ")),
            selected: false,
            suffix: Some(suffix_parts.join(" · ")),
            locked: false,
            installed: true,
            installed_scope: Some(Scope::Both),
            outdated: info.outdated,
            kind: info.kind,
            search_haystack: String::new(),
        };
        buckets
            .entry(kind_bucket(info.kind))
            .or_default()
            .push(item);
    }

    let mut groups = Vec::new();
    for kind in KIND_ORDER {
        if let Some(items) = buckets.remove(*kind) {
            groups.push(ItemGroup {
                label: (*kind).into(),
                items,
            });
        }
    }

    let count: usize = groups.iter().map(|g| g.items.len()).sum();
    Some(Tab {
        name: format!("Duplicates ({count})"),
        kind: TabKind::Duplicates,
        groups,
    })
}

/// Check for CLI binary update (~1.5s timeout).
pub(super) fn check_for_update() -> Option<String> {
    let local = env!("CARGO_PKG_VERSION");
    let remote = crate::commands::update::get_remote_version_with_timeout(
        std::time::Duration::from_millis(1500),
    )?;
    if remote != local {
        Some(format!("{} → {}", local, remote))
    } else {
        None
    }
}

pub(super) fn build_dep_display(
    skills: &[Skill],
    graph: &HashMap<String, Vec<String>>,
) -> HashMap<String, String> {
    let mut display = HashMap::new();

    for skill in skills {
        let mut parts = Vec::new();

        if let Some(deps) = graph.get(&skill.name) {
            parts.push(format!("requires: {}", deps.join(", ")));
        }

        let optional: Vec<_> = skill
            .resolved_deps
            .iter()
            .filter(|d| d.optional)
            .map(|d| d.name.as_str())
            .collect();
        if !optional.is_empty() {
            parts.push(format!("optional: {}", optional.join(", ")));
        }

        if !parts.is_empty() {
            display.insert(skill.name.clone(), parts.join(" | "));
        }
    }

    display
}
