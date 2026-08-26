//! The tables that name items: what is declared, which plugins are on, what
//! stays removed, and which optional dependencies were taken.

use toml::Table;
use toml::Value;

use super::Finding;

/// Tables whose entries name something a source offers. Plugins are not
/// among them: they come from a plugin registry and carry only an enabled flag.
/// Bundles are — a bundle names a set the source offers, and it declares the
/// same things about installing it that any item declares.
const ITEM_TABLES: &[&str] = &[
    "agents",
    "skills",
    "hooks",
    "commands",
    "mcp-servers",
    "pi-extensions",
    "bundles",
];

/// The kinds a plugin-registry-shaped catalog offers, and so the only ones whose
/// names may carry the plugin they came from. A hook or a server has no
/// namespaced spelling anywhere — a `/` in one of those names would just be
/// a directory on disk that nothing knows to remove.
const NAMESPACED_TABLES: &[&str] = &["agents", "commands", "skills"];

/// The tools whose plugin switch kendex can write. Naming any other one
/// asks for a write that has nowhere to land.
fn plugin_harnesses() -> Vec<&'static str> {
    crate::model::HarnessId::ALL
        .into_iter()
        .filter(|h| {
            let toggle = crate::harness::capabilities(*h, crate::model::ItemKind::Plugin).toggle;
            toggle.project || toggle.global
        })
        .map(crate::model::HarnessId::name)
        .collect()
}

pub(super) fn validate_items(table: &Table, findings: &mut Vec<Finding>) {
    let source_names: Vec<String> = table
        .get("sources")
        .and_then(Value::as_table)
        .map(|s| s.keys().cloned().collect())
        .unwrap_or_default();
    let repo_sources: Vec<String> = table
        .get("sources")
        .and_then(Value::as_table)
        .map(|sources| {
            sources
                .iter()
                .filter(|(_, decl)| {
                    decl.as_table()
                        .is_some_and(|decl| decl.get("repo").is_some_and(|v| v.is_str()))
                })
                .map(|(name, _)| name.clone())
                .collect()
        })
        .unwrap_or_default();
    for &kind_table in ITEM_TABLES {
        let Some(items) = table.get(kind_table).and_then(Value::as_table) else {
            continue;
        };
        for (name, decl) in items {
            let location = format!("{kind_table}.{name}");
            // Pi extensions are npm packages, where `@scope/name` is a
            // legitimate shape. Every other name becomes a file or a
            // directory, and the only `/` one may hold is the plugin a
            // plugin-registry-shaped catalog keeps the item in.
            let scoped_ok = kind_table == "pi-extensions"
                && name.starts_with('@')
                && name.matches('/').count() == 1
                && !name.ends_with('/');
            let namespaced = NAMESPACED_TABLES.contains(&kind_table);
            let problem = match (scoped_ok, namespaced) {
                (true, _) => None,
                (false, true) => crate::names::item_problem(name),
                (false, false) => crate::names::segment_problem(name),
            };
            if let Some(problem) = problem {
                findings.push(Finding {
                    location: location.clone(),
                    problem,
                    fix: match namespaced {
                        true => "rename the item — a plain name, or `<plugin>/<item>` for an item from a catalog of Claude plugins".into(),
                        false => format!(
                            "rename it — a {} is named without a `/`",
                            kind_table.strip_suffix('s').unwrap_or(kind_table)
                        ),
                    },
                });
            }
            let Some(decl) = decl.as_table() else {
                findings.push(Finding {
                    location,
                    problem: "declaration must be a table".into(),
                    fix: format!("write [{kind_table}.{name}] with source = \"<source-name>\""),
                });
                continue;
            };
            match decl.get("source").and_then(Value::as_str) {
                None => findings.push(Finding {
                    location: location.clone(),
                    problem: "missing source".into(),
                    fix: "add source = \"<source-name>\" (or \"local\")".into(),
                }),
                Some(source) => {
                    if source != crate::manifest::LOCAL_SOURCE_NAME
                        && source != crate::manifest::INPLACE_SOURCE_NAME
                        && !source_names.iter().any(|s| s == source)
                    {
                        findings.push(Finding {
                            location: location.clone(),
                            problem: format!("references undeclared source '{source}'"),
                            fix: format!(
                                "declare [sources.{source}] or change source to one of: {}",
                                if source_names.is_empty() {
                                    "local".to_owned()
                                } else {
                                    format!("{}, local", source_names.join(", "))
                                }
                            ),
                        });
                    }
                }
            }
            validate_rev(kind_table, name, decl, &location, &repo_sources, findings);
        }
    }
}

/// An item's rev is a hold, and a hold that can move is not one: only the
/// full commit id is immutable — a tag or branch here would re-resolve on
/// refresh, the very drift holding is meant to prevent. And only a repo
/// source has revisions to hold at.
fn validate_rev(
    kind_table: &str,
    name: &str,
    decl: &Table,
    location: &str,
    repo_sources: &[String],
    findings: &mut Vec<Finding>,
) {
    let Some(rev) = decl.get("rev") else {
        return;
    };
    if !rev.as_str().is_some_and(crate::remote::store::is_pin) {
        findings.push(Finding {
            location: location.to_owned(),
            problem: "an item's rev must be a full commit id".into(),
            fix: format!(
                "run `kendex pin {} {name} <version>` to resolve a tag or branch to its commit",
                kind_table.strip_suffix('s').unwrap_or(kind_table)
            ),
        });
    }
    if !decl
        .get("source")
        .and_then(Value::as_str)
        .is_some_and(|source| repo_sources.iter().any(|s| s == source))
    {
        findings.push(Finding {
            location: location.to_owned(),
            problem: "only an item from a repo source has revisions".into(),
            fix: "remove rev, or point this item's source at a repo".into(),
        });
    }
}

/// `[forks.<kind>.<name>]` records where each fork came from. User-editable
/// TOML, so a malformed entry gets a finding, never a silent drop.
pub(super) fn validate_forks(table: &Table, findings: &mut Vec<Finding>) {
    let kinds: Vec<&str> = crate::model::ItemKind::ALL
        .into_iter()
        .map(crate::model::ItemKind::name)
        .collect();
    let Some(forks) = table.get("forks").and_then(Value::as_table) else {
        return;
    };
    for (kind, entries) in forks {
        if !kinds.contains(&kind.as_str()) {
            findings.push(Finding {
                location: format!("forks.{kind}"),
                problem: format!("unknown kind '{kind}'"),
                fix: format!("use one of: {}", kinds.join(", ")),
            });
            continue;
        }
        let Some(entries) = entries.as_table() else {
            findings.push(Finding {
                location: format!("forks.{kind}"),
                problem: "forks are grouped by kind, then name".into(),
                fix: format!("write [forks.{kind}.<name>] with source and forked-at"),
            });
            continue;
        };
        for (name, provenance) in entries {
            let location = format!("forks.{kind}.{name}");
            if let Some(problem) = crate::names::item_problem(name) {
                findings.push(Finding {
                    location: location.clone(),
                    problem,
                    fix: "name the fork the way its item is named".into(),
                });
            }
            let Some(provenance) = provenance.as_table() else {
                findings.push(Finding {
                    location,
                    problem: "a fork records where it came from".into(),
                    fix: format!("write [forks.{kind}.{name}] with source and forked-at"),
                });
                continue;
            };
            for required in ["source", "forked-at"] {
                if !provenance.get(required).is_some_and(|v| v.is_str()) {
                    findings.push(Finding {
                        location: location.clone(),
                        problem: format!("missing {required}"),
                        fix: format!("add {required} = \"…\""),
                    });
                }
            }
        }
    }
}

pub(super) fn validate_plugins(table: &Table, findings: &mut Vec<Finding>) {
    let Some(plugins) = table.get("plugins").and_then(Value::as_table) else {
        return;
    };
    for (key, decl) in plugins {
        let decl = decl.as_table();
        let well_formed = decl.is_some_and(|decl| {
            decl.keys().all(|k| k == "enabled" || k == "harness")
                && decl.get("enabled").is_none_or(Value::is_bool)
        });
        if !well_formed {
            findings.push(Finding {
                location: format!("plugins.{key}"),
                problem: "a plugin declares whether it is enabled and which tool it belongs to"
                    .into(),
                fix: format!("write [plugins.\"{key}\"] with enabled = true or false"),
            });
        }
        // A plugin belongs to one tool, and only some tools have a plugin
        // switch to write at all.
        if let Some(harness) = decl
            .and_then(|decl| decl.get("harness"))
            .and_then(Value::as_str)
            && !plugin_harnesses().contains(&harness)
        {
            findings.push(Finding {
                location: format!("plugins.{key}.harness"),
                problem: format!("{harness} has no plugin switch kendex can write"),
                fix: format!("set harness to one of: {}", plugin_harnesses().join(", ")),
            });
        }
    }
}

/// The two tables that record dependency choices: what stays removed, and
/// which optional dependencies were taken. Both are lists of item names, so
/// a value that is not one would silently hold nothing back or install
/// nothing extra.
pub(super) fn validate_dependency_choices(table: &Table, findings: &mut Vec<Finding>) {
    let kinds: Vec<&str> = crate::model::ItemKind::ALL
        .into_iter()
        .map(crate::model::ItemKind::name)
        .collect();
    if let Some(suppressed) = table.get("suppressed").and_then(Value::as_table) {
        for (kind, names) in suppressed {
            if !kinds.contains(&kind.as_str()) {
                findings.push(Finding {
                    location: format!("suppressed.{kind}"),
                    problem: format!("unknown kind '{kind}'"),
                    fix: format!("use one of: {}", kinds.join(", ")),
                });
            }
            name_list(names, &format!("suppressed.{kind}"), findings);
        }
    }
    if let Some(optional) = table.get("optional-dependencies").and_then(Value::as_table) {
        for (item, names) in optional {
            name_list(names, &format!("optional-dependencies.{item}"), findings);
        }
    }
}

pub(super) fn name_list(value: &Value, location: &str, findings: &mut Vec<Finding>) {
    let list_of_names = value
        .as_array()
        .is_some_and(|list| list.iter().all(Value::is_str));
    if !list_of_names {
        findings.push(Finding {
            location: location.to_owned(),
            problem: "expected a list of item names".into(),
            fix: format!("write {location} = [\"<name>\"]"),
        });
    }
}
