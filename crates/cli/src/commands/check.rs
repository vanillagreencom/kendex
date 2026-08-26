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

/// Whether commits are actually gated, from the growth-guards installer's
/// own `--check`. It is the one thing this report cannot read off a stat:
/// the shims live in `.git/hooks`, which no lock tracks, and a repository
/// whose shims drifted looks identical on disk to one that never armed any.
///
/// Asking the installer means running a script out of the checkout, so it is
/// asked only where this project's own manifest declares the package —
/// where someone installed it on purpose. In any other repository the shims
/// are inspected as files and reported as unmanaged: cloning a repository
/// and reading its status must not run code the clone happens to carry.
///
/// Only project scopes have a work tree to ask about, and a scope with
/// nothing of the package's in it gets no line at all — no shim can fire
/// there and none is expected. A verdict that could not be taken is `could
/// not check`, never a silent pass.
fn fold_commit_hooks(env: &Env, checked: &mut CheckReport, scopes: &[kendex_core::model::Scope]) {
    use kendex_core::drift::report::Class;
    use kendex_core::model::Scope;
    for scope in scopes {
        let Scope::Project { root } = scope.canonical() else {
            continue;
        };
        let consent = match declares_guards(env, scope) {
            true => kendex_core::guard::Consent::Recorded,
            false => kendex_core::guard::Consent::Unrecorded,
        };
        let (class, text) = match kendex_core::guard::armed(&root, consent) {
            Ok(None) => continue,
            Ok(Some(verdict)) if verdict.code == 0 => continue,
            Ok(Some(verdict)) => (
                match verdict.code {
                    1 => Class::Drift,
                    _ => Class::Unknown,
                },
                verdict.lines.join(" "),
            ),
            Err(error) => (Class::Unknown, error.to_string()),
        };
        report::fold(checked, "commit hooks", class, text);
    }
}

/// Whether this scope's manifest declares the guard package, enabled.
///
/// The manifest, not the lock: what the person wrote down is the consent,
/// and a declaration whose install has not landed yet is still a
/// declaration. A manifest that cannot be read is not consent.
fn declares_guards(env: &Env, scope: &kendex_core::model::Scope) -> bool {
    let path = kendex_core::manifest::manifest_path(env, scope);
    matches!(
        kendex_core::manifest::load(&path),
        Ok(kendex_core::manifest::ManifestFile::Current(manifest))
            if manifest
                .skills
                .get(kendex_core::guard::SKILL)
                .is_some_and(|decl| decl.enabled)
    )
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
