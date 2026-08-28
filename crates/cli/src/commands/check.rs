use std::process::ExitCode;

use kendex_core::drift::report::{self, CheckReport};
use kendex_core::env::Env;

use super::{out, resolve_scopes, say};
use crate::scope::ScopeFilter;

/// The session-start contract: exit 0 clean / 1 drift or not yet
/// evaluated / 2 could-not-check.
/// The report reads the drift snapshot and the fetch stamps — the deep work
/// already ran wherever updates, refresh, or apply last did — and spawns
/// one detached background refresh when any mirror is stale, so the next
/// session reads fresh verdicts. `--quiet` prints the bounded report and
/// nothing when clean; `--json` prints the machine shape.
pub fn run(
    env: &Env,
    filter: ScopeFilter,
    json: bool,
    quiet: bool,
) -> Result<ExitCode, Box<dyn std::error::Error>> {
    let scopes = resolve_scopes(env, filter)?;
    let mut checked = report::check(env, &scopes);
    fold_commit_hooks(env, &mut checked, &scopes);

    // Freshness is earned in the background, never waited on. The spawn is
    // detached with no stdio; a busy or failing refresh writes stamps and
    // the next check reads them. `KENDEX_BACKGROUND_REFRESH=off` keeps the
    // check strictly read-only (tests, CI).
    if report::wants_background_refresh(env, &scopes)
        && std::env::var("KENDEX_BACKGROUND_REFRESH").as_deref() != Ok("off")
    {
        kendex_core::process::respawn_detached(&["source", "refresh", "--stale"]);
    }

    if json {
        out(&serde_json::to_string_pretty(&checked)?);
    } else {
        render_text(&checked, quiet);
    }
    Ok(ExitCode::from(checked.status.exit_code()))
}

/// Whether commits here are actually gated. The one thing this report
/// cannot read off a stat: the shims live in `.git/hooks`, which no lock
/// tracks, and a repository whose shims drifted looks identical on disk to
/// one that never armed any.
///
/// Read natively, never executed. A checkout is other people's data, and
/// this is a read: cloning a repository and asking after its status must
/// not run code its author chose. The package's own checker speaks a richer
/// vocabulary and a person can still run it — but running it is an
/// invocation, and this is not one.
///
/// Only project scopes have a work tree to ask about. A verdict that could
/// not be taken is `could not check`, never a silent pass.
fn fold_commit_hooks(env: &Env, checked: &mut CheckReport, scopes: &[kendex_core::model::Scope]) {
    use kendex_core::drift::report::Class;
    use kendex_core::model::Scope;
    for scope in scopes {
        let Scope::Project { root } = scope.canonical() else {
            continue;
        };
        // One probe per scope, shared by both reads below: each costs git
        // processes, and this runs at every session start.
        //
        // No repository here is no verdict: there is nothing to arm and no
        // drift to report. Folding it into "not armed" told a scope with no
        // work tree to run `kendex guard install`, which exits 2 there —
        // advice that cannot be taken, every session.
        let repo = match kendex_core::guard::Repo::probe(&root) {
            Ok(Some(repo)) => repo,
            Ok(None) => continue,
            Err(error) => {
                report::fold(checked, "commit hooks", Class::Unknown, error.to_string());
                continue;
            }
        };
        // A checkout that merely carries the files is not missing an
        // arming nobody asked for, so only a project whose own install
        // record declares the package hears about unarmed hooks. One whose
        // record does NOT is where a removal may have left shims behind:
        // the package is in no record, and what it left armed is the one
        // state here that stops every commit. Named by file, because the
        // remedy is by hand — the uninstaller that would strip these went
        // with the package.
        let (class, text) = match installed_here(env, scope) {
            false => match kendex_core::guard::stranded(&repo) {
                Ok(files) if files.is_empty() => continue,
                Ok(files) => {
                    let files: Vec<String> = files
                        .iter()
                        .map(|path| path.display().to_string())
                        .collect();
                    (
                        Class::Drift,
                        format!(
                            "{} armed the commit hooks and is installed in no project of this repository, so every commit fails until {} are dealt with — strip the lines marked `{}` from each hook, and delete a whole file only where it carries `{}` or is the helper kendex wrote beside the hooks",
                            kendex_core::guard::SKILL,
                            files.join(", "),
                            kendex_core::guard::MARKER,
                            kendex_core::guard::CREATED_MARKER
                        ),
                    )
                }
                Err(error) => (Class::Unknown, error.to_string()),
            },
            true => match kendex_core::guard::armed(&repo) {
                Ok(true) => continue,
                Ok(false) => (
                    Class::Drift,
                    format!(
                        "commit hooks are not armed in {} — `kendex guard install` arms them, and `kendex guard check` says more",
                        root.display()
                    ),
                ),
                Err(error) => (Class::Unknown, error.to_string()),
            },
        };
        report::fold(checked, "commit hooks", class, text);
    }
}

/// Whether this project's install record carries the guard package — the
/// difference between "your hooks are not armed" and a clone that simply
/// ships the files. Wording only: nothing here decides what may run.
fn installed_here(env: &Env, scope: &kendex_core::model::Scope) -> bool {
    kendex_core::lock::load(&kendex_core::lock::lock_path(env, scope)).is_ok_and(|lock| {
        // Enabled, not merely recorded: a declaration switched off is
        // someone saying they do not want this gate here, and reporting it
        // as unarmed drift every session start argues with them about a
        // choice they already made.
        //
        // And the SKILL of that name, not anything of that name. A name is
        // not unique across kinds — an agent called growth-guards is a
        // legal thing to install — and reading one as consent to a commit
        // gate reports hook drift, every session, at a project that never
        // asked for hooks and has no way to make the report stop.
        lock.entries.values().any(|entry| {
            entry.name == kendex_core::guard::SKILL
                && entry.kind == kendex_core::model::ItemKind::Skill
                && entry.enabled
        })
    })
}

fn render_text(checked: &CheckReport, quiet: bool) {
    let text = report::render_plain(checked);
    if text.is_empty() {
        if !quiet {
            say("all clear — every install matches its source");
        }
        return;
    }
    // The report is agent- and composition-facing content: stdout.
    for line in text.lines() {
        out(line);
    }
}
