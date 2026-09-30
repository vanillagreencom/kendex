use clap::{Args, Subcommand};

use kendex_core::env::Env;
use kendex_core::model::Scope;
use kendex_core::package::updates::UpdatesReport;

use super::pin::parse_kind;
use super::{CliResult, resolve_scopes_at, scope_label};
use crate::scope::ScopeFilter;
use crate::ui::{self, Status, Style};

#[derive(Subcommand)]
pub enum UpdatesCommand {
    /// Stop notifying about one package's updates
    Ignore {
        /// agent | skill | hook | command | mcp-server | pi-extension
        kind: String,
        name: String,
    },
    /// Resume notifications for an ignored package
    Unignore {
        /// agent | skill | hook | command | mcp-server | pi-extension
        kind: String,
        name: String,
    },
}

#[derive(Args)]
pub struct UpdatesArgs {
    #[command(subcommand)]
    command: Option<UpdatesCommand>,
    /// Check every marketplace for updates first, held packages' ones included
    #[arg(long)]
    refresh: bool,
    /// Install pending updates (the same run as refresh)
    #[arg(long)]
    pub(super) apply: bool,
    #[arg(short = 'g', long)]
    global: bool,
    /// project | global (default project)
    #[arg(long)]
    scope: Option<String>,
    /// Skip confirmation prompts
    #[arg(short = 'y', long, global = true)]
    yes: bool,
    // Read by the listing, written by --apply. The help clap prints is the
    // flag's own, on `flags::ProjectTargetFlag`; a doc comment here would
    // reach no output.
    #[command(flatten)]
    pub(super) target: crate::flags::ProjectTargetFlag,
    // The commit offer's answer, without asking. Its help is
    // `commit_offer::CommitFlags`' own, for the same reason.
    #[command(flatten)]
    _commit: crate::commands::commit_offer::CommitFlags,
}

impl UpdatesArgs {
    /// The scope selection shared by dispatch and the pre-bootstrap lane check.
    pub(super) fn effective_scope(&self) -> Result<ScopeFilter, String> {
        ScopeFilter::resolve(self.scope.as_deref(), self.global, ScopeFilter::Project)
    }
}

pub fn run(env: &Env, args: UpdatesArgs) -> CliResult {
    run_with(env, args, kendex_core::package::updates::updates)
}

fn run_with(
    env: &Env,
    args: UpdatesArgs,
    evaluate: impl FnOnce(&Env, &Scope) -> kendex_core::error::Result<UpdatesReport>,
) -> CliResult {
    let filter = args.effective_scope()?;
    let UpdatesArgs {
        command,
        refresh,
        apply,

        yes,
        target,
        ..
    } = args;

    // Resolution only resolves: a listing writes nothing, so a bare
    // `updates --project-path` leaves the projects list as it found it.
    // `--apply` registers through the refresh it hands off to.
    let scope = resolve_scopes_at(env, filter, target.path())?.remove(0);
    // Whatever this run turns out to be, it starts the way the parent
    // command starts: a `--refresh` the person typed is a fetch they asked
    // for before anything reads a catalog. The listing reads one; muting
    // and unmuting write a settings entry and read no source, so fetching
    // every one of them would spend the network on nothing.
    if refresh && command.is_none() {
        fetch_sources(env, &scope);
    }
    // `--apply` is the whole scope and a subcommand is one package's
    // notification setting: doing either silently over the other answers a
    // question nobody asked.
    if apply && command.is_some() {
        return Err(
            "--apply brings the whole place current; drop it to mute or unmute one package".into(),
        );
    }
    match command {
        Some(UpdatesCommand::Ignore { kind, name }) => {
            return set_ignored(env, &scope, kind, name, true);
        }
        Some(UpdatesCommand::Unignore { kind, name }) => {
            return set_ignored(env, &scope, kind, name, false);
        }
        None => {}
    }
    if apply {
        return super::refresh::run(env, filter, &target, false, yes, false);
    }
    let report = evaluate(env, &scope)?;
    let style = ui::style();
    ui::stderr(&style.header("updates", &scope.label()));
    ui::stderr(&screen(&style, &report));
    // The deep work just ran; write it down so the next session-start check
    // reads verdicts instead of guesses.
    if let Err(error) = kendex_core::drift::snapshot::record_with(env, &scope, &report) {
        ui::report::warning(&format!("snapshot not derived ({})", error));
    }
    Ok(())
}

fn screen(style: &Style, report: &kendex_core::package::updates::UpdatesReport) -> Vec<String> {
    let mut lines = Vec::new();
    let mut shown = 0;
    for row in &report.rows {
        // Mixed installs, packages gone upstream and installs edited on
        // disk are standing facts worth a line even when no newer version
        // exists to move to: the edit is what stands between the package
        // and its next update, and Home counts it, so the listing must
        // say it too.
        if !row.update_available
            && !row.mixed
            && !row.removed_upstream
            && !row.blocked_by_local_edit
        {
            continue;
        }
        shown += 1;
        let mut notes = Vec::new();
        if row.pinned {
            notes.push((Status::Decision, "held"));
        }
        if row.ignored {
            notes.push((Status::Decision, "ignored"));
        }
        if row.mixed {
            notes.push((Status::Decision, "mixed installs"));
        }
        if row.removed_upstream {
            notes.push((Status::Failed, "no longer in its marketplace"));
        }
        if row.blocked_by_local_edit {
            notes.push((
                Status::Failed,
                "edited on disk — keep it as your own copy, or discard the edits",
            ));
        }
        let current = row
            .current
            .as_ref()
            .map(show_version)
            .unwrap_or_else(|| "?".into());
        let latest = row
            .latest
            .as_ref()
            .map(show_version)
            .unwrap_or_else(|| "?".into());
        // The place leads the plain line: the same package can be out of
        // date in several projects, and a line that does not say which one
        // reads as a duplicate.
        lines.extend(style.report_change(
            &scope_label(&row.scope),
            &format!("{} {}", row.kind.name(), row.name),
            &current,
            &latest,
            &notes,
        ));
    }
    for warning in &report.warnings {
        lines.extend(style.report_warning(&format!(
            "{} {}: {}",
            warning.kind.name(),
            warning.name,
            warning.message
        )));
    }
    if shown == 0 && report.warnings.is_empty() {
        lines.extend(style.summary(Status::Done, "everything is on its latest version"));
    }
    lines
}

/// Bring every source's mirror up to date, pinned ones included. A source
/// that cannot be fetched is said and skipped: the run continues against
/// what is cached, which is what it would have had anyway.
fn fetch_sources(env: &Env, scope: &kendex_core::model::Scope) {
    let path = kendex_core::manifest::manifest_path(env, scope);
    if let Ok(kendex_core::manifest::ManifestFile::Current(manifest)) =
        kendex_core::manifest::load(&path)
    {
        for warning in kendex_core::remote::fetch_all(env, &manifest) {
            ui::report::warning(&warning.to_string());
        }
    }
}

fn show_version(version: &kendex_core::package::updates::VersionRef) -> String {
    match &version.label {
        Some(label) => label.clone(),
        None => version.commit[..7.min(version.commit.len())].to_owned(),
    }
}

fn set_ignored(
    env: &Env,
    scope: &kendex_core::model::Scope,
    kind: String,
    name: String,
    ignored: bool,
) -> CliResult {
    let kind = parse_kind(&kind)?;
    // The ignore is keyed by repository too, so it needs the row's identity.
    let rows = kendex_core::package::updates::updates(env, scope)?.rows;
    let Some(row) = rows.iter().find(|row| row.kind == kind && row.name == name) else {
        return Err(format!(
            "no {} named '{name}' from a marketplace repository in this place",
            kind.name()
        )
        .into());
    };
    kendex_core::package::updates::set_ignored(env, scope, kind, &name, &row.repo, ignored)?;
    ui::report::notice(&match ignored {
        true => {
            format!("updates for {name} are muted — `kendex updates unignore` brings them back")
        }
        false => format!("updates for {name} notify again"),
    });
    Ok(())
}

#[cfg(test)]
mod tests;
