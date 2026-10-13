//! External commands declared by skill publishers. Installation and check
//! share this reader and judge; neither installs system packages.

use std::collections::BTreeMap;
use std::path::PathBuf;
use std::time::Instant;

use crate::frontmatter::{Map, Value};

const MISSING_KEY: &str = "kendex-command-missing:";
const BELOW_FLOOR_KEY: &str = "kendex-command-below-floor:";
const VERSION_UNREADABLE_KEY: &str = "kendex-command-version-unreadable:";

#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct CommandDependency {
    pub(crate) command: String,
    pub(crate) purpose: String,
    pub(crate) optional: bool,
    pub(crate) floor: Option<String>,
    pub(crate) packages: BTreeMap<String, String>,
}

#[derive(Debug, PartialEq, Eq)]
pub(crate) struct DeclarationProblem {
    pub(crate) row: usize,
    pub(crate) field: &'static str,
}

/// SKILL.md authors produce these rows. Refuse malformed values rather than
/// treating a misspelled required command or optional flag as no requirement.
pub(crate) fn declared(map: &Map) -> Result<Vec<CommandDependency>, DeclarationProblem> {
    let Some(Value::Map(dependencies)) = map.get("dependencies") else {
        return Ok(Vec::new());
    };
    let Some(commands) = dependencies.get("commands") else {
        return Ok(Vec::new());
    };
    let Value::List(rows) = commands else {
        return Err(DeclarationProblem {
            row: 0,
            field: "commands",
        });
    };
    rows.iter()
        .enumerate()
        .map(|(index, value)| {
            let problem = |field| DeclarationProblem {
                row: index + 1,
                field,
            };
            let Value::Map(row) = value else {
                return Err(problem("row"));
            };
            let text = |field| {
                row.get(field)
                    .and_then(Value::as_str)
                    .map(str::trim)
                    .filter(|text| !text.is_empty())
                    .ok_or_else(|| problem(field))
            };
            let command = text("command")?;
            // A command is a PATH name, never a catalog-selected executable path
            // or a shell expression. Only the resolved host command may be probed.
            if command.contains(['/', '\\', ':'])
                || command.chars().any(|c| c.is_whitespace() || c.is_control())
            {
                return Err(problem("command"));
            }
            let purpose = text("purpose")?.to_owned();
            let optional = match row.get("optional") {
                None => false,
                Some(Value::Scalar(value)) if value == "true" => true,
                Some(Value::Scalar(value)) if value == "false" => false,
                Some(Value::Scalar(_) | Value::Null | Value::List(_) | Value::Map(_)) => {
                    return Err(problem("optional"));
                }
            };
            let floor = row
                .get("floor")
                .map(|_| text("floor").map(str::to_owned))
                .transpose()?;
            if floor.as_ref().is_some_and(|floor| version(floor).is_none()) {
                return Err(problem("floor"));
            }
            let packages = match row.get("packages") {
                None => BTreeMap::new(),
                Some(Value::Map(packages)) => packages
                    .entries()
                    .map(|(manager, value)| {
                        let package = value
                            .as_str()
                            .filter(|text| !text.trim().is_empty())
                            .ok_or_else(|| problem("packages"))?;
                        Ok((manager.to_owned(), package.to_owned()))
                    })
                    .collect::<Result<_, DeclarationProblem>>()?,
                Some(Value::Scalar(_) | Value::Null | Value::List(_)) => {
                    return Err(problem("packages"));
                }
            };
            Ok(CommandDependency {
                command: command.to_owned(),
                purpose,
                optional,
                floor,
                packages,
            })
        })
        .collect()
}

#[derive(Debug, PartialEq, Eq)]
pub(crate) enum CommandProblem {
    Missing,
    BelowFloor { found: String },
    VersionUnreadable,
}

#[derive(Debug, PartialEq, Eq)]
pub(crate) struct CommandIssue {
    pub(crate) dependency: CommandDependency,
    pub(crate) problem: CommandProblem,
}

impl CommandIssue {
    pub(crate) fn is_notice(&self) -> bool {
        self.dependency.optional || self.problem == CommandProblem::VersionUnreadable
    }

    /// One diagnostic for both installation and check. These keyed fields are
    /// identify requirements in the check report and carry the publisher's purpose.
    pub(crate) fn message(&self, skill: &str) -> String {
        let key = match self.problem {
            CommandProblem::Missing => MISSING_KEY,
            CommandProblem::BelowFloor { .. } => BELOW_FLOOR_KEY,
            CommandProblem::VersionUnreadable => VERSION_UNREADABLE_KEY,
        };
        let packages = self
            .dependency
            .packages
            .iter()
            .map(|(manager, name)| format!("{manager}={name}"))
            .collect::<Vec<_>>()
            .join(", ");
        let mut message = format!(
            "{key} command={} skill={} purpose={} optional={} packages={}",
            crate::names::shown(&self.dependency.command),
            crate::names::shown(skill),
            crate::names::shown(&self.dependency.purpose),
            self.dependency.optional,
            crate::names::shown(&packages)
        );
        if let Some(floor) = &self.dependency.floor {
            message.push_str(&format!(" floor={}", crate::names::shown(floor)));
        }
        if let CommandProblem::BelowFloor { found } = &self.problem {
            message.push_str(&format!(" found={}", crate::names::shown(found)));
        }
        message
    }
}

pub(crate) fn check(
    dependencies: &[CommandDependency],
    deadline: Option<Instant>,
) -> Vec<CommandIssue> {
    let path = std::env::var_os("PATH").unwrap_or_default();
    let suffixes = std::env::var("PATHEXT").unwrap_or_else(|_| ".COM;.EXE;.BAT;.CMD".to_owned());
    dependencies
        .iter()
        .filter_map(|dependency| {
            let command = command_path(&dependency.command, &path, cfg!(windows), &suffixes);
            let problem = match command {
                None => Some(CommandProblem::Missing),
                Some(command) => dependency.floor.as_ref().and_then(|floor| {
                    let timeout = deadline
                        .map(|deadline| deadline.saturating_duration_since(Instant::now()))
                        .unwrap_or(crate::process::INTERACTIVE_TIMEOUT);
                    let read = (!timeout.is_zero())
                        .then(|| {
                            crate::process::Hardened::command_version(&command)
                                .timeout(timeout)
                                .run()
                        })
                        .and_then(Result::ok)
                        .filter(|output| output.status.success());
                    let found = read.and_then(|output| {
                        let stdout = String::from_utf8_lossy(&output.stdout);
                        let stderr = String::from_utf8_lossy(&output.stderr);
                        reported_version(&stdout).or_else(|| reported_version(&stderr))
                    });
                    judge_version(floor, found)
                }),
            }?;
            Some(CommandIssue {
                dependency: dependency.clone(),
                problem,
            })
        })
        .collect()
}

pub(crate) fn report(
    declarations: &BTreeMap<String, Vec<CommandDependency>>,
    notes: &mut Vec<String>,
    warnings: &mut Vec<crate::engine::ItemWarning>,
) {
    for (skill, dependencies) in declarations {
        for issue in check(dependencies, None) {
            let message = issue.message(skill);
            if issue.is_notice() {
                notes.push(message);
            } else {
                warnings.push(crate::engine::ItemWarning {
                    kind: crate::model::ItemKind::Skill,
                    name: skill.clone(),
                    harness: None,
                    message,
                    remediation: Some(format!(
                        "make {} available on PATH",
                        issue.dependency.command
                    )),
                    detail: None,
                });
            }
        }
    }
}

/// Other PATH probes only detect a fixed package manager or kendex itself.
/// Publisher-declared names need the executable bit and Windows suffixes too.
fn command_path(
    command: &str,
    path: &std::ffi::OsStr,
    windows: bool,
    suffixes: &str,
) -> Option<PathBuf> {
    std::env::split_paths(path)
        .flat_map(|dir| {
            let mut candidates = vec![dir.join(command)];
            if windows && std::path::Path::new(command).extension().is_none() {
                candidates.extend(
                    suffixes
                        .split(';')
                        .filter(|suffix| !suffix.is_empty())
                        .map(|suffix| dir.join(format!("{command}{suffix}"))),
                );
            }
            candidates
        })
        .find(|path| crate::fs::is_executable(path))
        .map(|path| crate::paths::absolute(&path))
}

/// Browser commands publish more numeric components than semantic versions.
/// Keep those components; semver owns suffix validity and pre-release ordering.
struct CommandVersion {
    semantic: semver::Version,
    extra: Vec<u64>,
    text: String,
}

impl CommandVersion {
    fn cmp_precedence(&self, other: &Self) -> std::cmp::Ordering {
        (
            self.semantic.major,
            self.semantic.minor,
            self.semantic.patch,
        )
            .cmp(&(
                other.semantic.major,
                other.semantic.minor,
                other.semantic.patch,
            ))
            .then_with(|| {
                let length = self.extra.len().max(other.extra.len());
                self.extra
                    .iter()
                    .copied()
                    .chain(std::iter::repeat(0))
                    .take(length)
                    .cmp(
                        other
                            .extra
                            .iter()
                            .copied()
                            .chain(std::iter::repeat(0))
                            .take(length),
                    )
            })
            .then_with(|| self.semantic.cmp_precedence(&other.semantic))
    }
}

fn version(text: &str) -> Option<CommandVersion> {
    let text = text.strip_prefix('v').unwrap_or(text);
    let core = text.split(['-', '+']).next()?;
    let numbers = core
        .split('.')
        .map(|part| {
            if part.is_empty() || !part.chars().all(|c| c.is_ascii_digit()) {
                return None;
            }
            part.parse::<u64>().ok()
        })
        .collect::<Option<Vec<_>>>()?;
    let normalized = format!(
        "{}.{}.{}{}",
        numbers[0],
        numbers.get(1).unwrap_or(&0),
        numbers.get(2).unwrap_or(&0),
        &text[core.len()..]
    );
    let semantic = semver::Version::parse(&normalized).ok()?;
    let extra = numbers.into_iter().skip(3).collect::<Vec<_>>();
    let text = if extra.is_empty() {
        semantic.to_string()
    } else {
        text.to_owned()
    };
    Some(CommandVersion {
        semantic,
        extra,
        text,
    })
}

fn reported_version(output: &str) -> Option<CommandVersion> {
    // Major-only floors are valid, but banner integers can be copyright
    // years or subversion counters. Only dotted output tokens identify a
    // command version. Later lines are commentary, not the version header.
    output
        .lines()
        .next()?
        .split_whitespace()
        .filter(|token| token.contains('.'))
        .find_map(|token| {
            let token = token.trim_matches(|c| matches!(c, '(' | ')' | ',' | ';'));
            version(token)
        })
}

fn judge_version(floor: &str, found: Option<CommandVersion>) -> Option<CommandProblem> {
    match (version(floor), found) {
        (Some(floor), Some(found)) if found.cmp_precedence(&floor).is_lt() => {
            Some(CommandProblem::BelowFloor { found: found.text })
        }
        (Some(_), Some(_)) => None,
        (None, _) | (Some(_), None) => Some(CommandProblem::VersionUnreadable),
    }
}

#[cfg(test)]
mod tests;
