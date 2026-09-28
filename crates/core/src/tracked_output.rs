//! The paths an agent definition declares as tracked output, held against
//! the ignore rules of the repository the agent writes into.
//!
//! An agent that writes a plan or a report to a path the repository
//! ignores loses it to every other checkout and to review, and nothing
//! says so. The agent names those paths in its own `tracked-outputs:`
//! frontmatter (`render::agent::SourceAgent::tracked_outputs`), and git is
//! the one judge of whether a path is ignored: it reads every `.gitignore`
//! on the way down, the repository's exclude file and `core.excludesFile`,
//! and applies the precedence between them. `kendex verify` asks here of a
//! project's installed agents, and the authoring check of a catalog's own.

use std::path::Path;

use crate::error::{CoreError, Result};
use crate::guard::Repo;
use crate::process::Hardened;

/// One declared path and where the repository leaves it.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Standing {
    pub agent: String,
    /// As the agent declared it, relative to the root asked about: a
    /// project's root for `verify`, a catalog's for the authoring check.
    pub path: String,
    pub held: Held,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Held {
    /// No ignore rule keeps a file written there out of a commit.
    Tracked,
    /// `rule` is git's own account of the match, `SOURCE:LINE:PATTERN`.
    Ignored { rule: String },
}

/// Every path `declared` names, each held against the repository at
/// `root`, in the order declared. Empty where `root` sits in no work tree:
/// without a repository there are no ignore rules to contradict an agent.
/// A git that cannot answer is an error, never a path read as tracked.
pub fn standings<'a>(
    root: &Path,
    declared: impl IntoIterator<Item = (&'a str, &'a [String])>,
) -> Result<Vec<Standing>> {
    let declared: Vec<(&str, &[String])> = declared
        .into_iter()
        .filter(|(_, paths)| !paths.is_empty())
        .collect();
    // Probed only where something was declared, so a scope whose agents
    // declare nothing spawns no git child.
    if declared.is_empty() || Repo::probe(root)?.is_none() {
        return Ok(Vec::new());
    }
    let mut out = Vec::new();
    for (agent, paths) in declared {
        for path in paths {
            out.push(Standing {
                agent: agent.to_owned(),
                path: path.clone(),
                held: held(root, path)?,
            });
        }
    }
    Ok(out)
}

/// `--no-index` because the question is about a file the agent has yet to
/// write: a path the index already holds is carried whatever the rules
/// say, and the next file written beside it is not.
///
/// The verdict is the plain call's exit status: 0 ignored, 1 not, anything
/// else no answer. `--verbose` cannot give it, because it also prints, and
/// exits 0 for, a negated pattern that re-includes the path; it is asked
/// only for the rule behind an ignore already established.
fn held(root: &Path, path: &str) -> Result<Held> {
    let ask = |verbose: bool| -> Result<(String, std::process::Output)> {
        let mut args = vec!["check-ignore", "--no-index"];
        if verbose {
            args.push("--verbose");
        }
        args.extend(["--", path]);
        let command = format!("git {}", args.join(" "));
        Ok((command, Hardened::git(&args, Some(root)).run()?))
    };
    let failed = |command: String, output: &std::process::Output| CoreError::GitFailed {
        command,
        stderr: format!(
            "git could not say whether it ignores {path} (exited {:?}): {}",
            output.status.code(),
            String::from_utf8_lossy(&output.stderr).trim()
        ),
    };
    let (command, verdict) = ask(false)?;
    match verdict.status.code() {
        Some(0) => {}
        Some(1) => return Ok(Held::Tracked),
        _ => return Err(failed(command, &verdict)),
    }
    let (command, said) = ask(true)?;
    if said.status.code() != Some(0) {
        return Err(failed(command, &said));
    }
    // `SOURCE:LINE:PATTERN<TAB>PATH`. A quoted path escapes any tab it
    // holds, so the last tab is the separator.
    let text = String::from_utf8_lossy(&said.stdout);
    let line = text.trim_end_matches(['\n', '\r']);
    let rule = line.rsplit_once('\t').map_or(line, |(rule, _)| rule);
    Ok(Held::Ignored {
        rule: rule.to_owned(),
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::test_util::rooted;

    fn git(root: &Path, args: &[&str]) {
        let output = Hardened::git(args, Some(root))
            .env("HOME", root.to_str().unwrap())
            .run()
            .unwrap();
        assert!(output.status.success(), "git {args:?}");
    }

    const PLAN: &str = "docs/plans/<slug>.md";
    const RESEARCH: &str = "docs/plans/<slug>-research.md";

    /// Each ignore file against the planner's two declared paths. A rule
    /// that names only one of them leaves the other tracked, and a negated
    /// rule that re-includes both is no ignore at all. The
    /// must-fail control is `held` answering `Tracked` on exit 0: every
    /// row with a rule then fails.
    #[test]
    fn each_declared_path_is_held_against_the_rules_in_force() {
        let tmp = tempfile::tempdir().unwrap();
        let root = rooted(&tmp);
        git(&root, &["init", "-q"]);
        let declared = vec![PLAN.to_owned(), RESEARCH.to_owned()];
        for (ignore, plan, research) in [
            ("", None, None),
            ("docs/plans/\n", Some("docs/plans/"), Some("docs/plans/")),
            ("/docs/\n", Some("/docs/"), Some("/docs/")),
            ("*.md\n", Some("*.md"), Some("*.md")),
            (
                "docs/plans/*-research.md\n",
                None,
                Some("docs/plans/*-research.md"),
            ),
            ("docs/plans/*\n!docs/plans/*.md\n", None, None),
        ] {
            std::fs::write(root.join(".gitignore"), ignore).unwrap();
            let standings = standings(&root, [("planner", declared.as_slice())]).unwrap();
            let expected: Vec<Standing> = [(PLAN, plan), (RESEARCH, research)]
                .into_iter()
                .map(|(path, pattern)| Standing {
                    agent: "planner".to_owned(),
                    path: path.to_owned(),
                    held: match pattern {
                        Some(pattern) => Held::Ignored {
                            rule: format!(".gitignore:1:{pattern}"),
                        },
                        None => Held::Tracked,
                    },
                })
                .collect();
            assert_eq!(standings, expected, "{ignore:?}");
        }
    }

    /// Outside a repository no rule applies, and a scope that declares
    /// nothing asks git nothing: a root that is no directory at all would
    /// fail the probe, and passes.
    #[test]
    fn no_repository_and_no_declaration_hold_nothing() {
        let tmp = tempfile::tempdir().unwrap();
        let root = rooted(&tmp);
        std::fs::write(root.join(".gitignore"), "docs/\n").unwrap();
        let declared = vec![PLAN.to_owned()];
        assert_eq!(
            standings(&root, [("planner", declared.as_slice())]).unwrap(),
            Vec::new()
        );
        let nowhere = root.join("missing");
        assert_eq!(
            standings(&nowhere, [("planner", &[][..])]).unwrap(),
            Vec::new()
        );
    }

    /// A path git refuses to judge is an error naming it, never a path
    /// read as tracked.
    #[test]
    fn a_path_git_cannot_judge_is_an_error() {
        let tmp = tempfile::tempdir().unwrap();
        let root = rooted(&tmp);
        git(&root, &["init", "-q"]);
        let declared = vec!["../outside.md".to_owned()];
        let error = standings(&root, [("planner", declared.as_slice())]).unwrap_err();
        assert!(error.to_string().contains("../outside.md"), "{error}");
    }
}
