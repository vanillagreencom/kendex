//! Rendering the drift report: the human and quiet text, plus the
//! credential-, control- and length-scrubbing every displayed string passes
//! through on its way there.

use super::{AvailableItem, CATALOG_KINDS, CheckReport, Item, ScopeReport, SourceProblem};
use std::collections::HashSet;

/// How much free text (a source string, a parse failure, a name) may reach an
/// agent's context on one report line.
const DISPLAY_LIMIT: usize = 120;

/// Remove credentials from a source string, keeping it FUNCTIONAL. Applied
/// at report construction, so every consumer — human report, quiet hook
/// line, `--json` on stdout, CI logs quoting either — sees credential-free
/// strings.
///
/// For `ssh://` URLs and scp-style `user@host:path` sources the username is
/// kept and only a `:password` is dropped: `git@` is how the endpoint picks
/// the key, not a secret, and stripping it turns a working remedy command
/// into one that dies on publickey. For every other scheme (https) the whole
/// userinfo goes — a bare user field is exactly where tokens like
/// `ghp_…@github.com` live.
pub(super) fn scrub_source_credentials(text: &str) -> String {
    if let Some(rest) = text.strip_prefix("ssh://") {
        let host_end = rest.find('/').unwrap_or(rest.len());
        if let Some(at) = rest[..host_end].rfind('@') {
            let user = rest[..at].split(':').next().unwrap_or_default();
            return format!("ssh://{user}@{}", &rest[at + 1..]);
        }
        return text.to_string();
    }
    if let Some(scheme_end) = text.find("://") {
        let after = &text[scheme_end + 3..];
        // Userinfo ends at the last `@` before the path starts.
        let host_end = after.find('/').unwrap_or(after.len());
        return match after[..host_end].rfind('@') {
            Some(at) => format!("{}{}", &text[..scheme_end + 3], &after[at + 1..]),
            None => text.to_string(),
        };
    }
    // scp-style `user@host:path` has no scheme; a pasted `user:pass@` form
    // must still lose the password while the user survives.
    let head_end = text.find('/').unwrap_or(text.len());
    if let Some(at) = text[..head_end].find('@') {
        let user = text[..at].split(':').next().unwrap_or_default();
        if user.len() != at {
            return format!("{user}@{}", &text[at + 1..]);
        }
    }
    text.to_string()
}

/// Characters a shell passes through untouched, so an argument built only
/// from them needs no quoting at all.
fn is_shell_safe(c: char) -> bool {
    c.is_ascii_alphanumeric() || matches!(c, '.' | '_' | '/' | '@' | ':' | '=' | '-')
}

/// A source rendered INSIDE a copy-paste command: credential- and
/// control-scrubbed like prose, but never truncated — an elided argument is
/// a command that cannot work — and single-quoted whenever it holds anything
/// a shell would interpret, so the pasted command runs on the literal string
/// rather than on whatever `$`, backtick, or quote it happened to contain.
pub(crate) fn command_arg(text: &str) -> String {
    let scrubbed: String = scrub_source_credentials(text)
        .chars()
        .map(|c| if c.is_control() { '?' } else { c })
        .collect();
    if !scrubbed.is_empty() && scrubbed.chars().all(is_shell_safe) {
        return scrubbed;
    }
    // POSIX single-quoting: nothing inside `'…'` is special, and the one
    // character that cannot appear there is spliced back in as `'\''`.
    format!("'{}'", scrubbed.replace('\'', r"'\''"))
}

/// Defensive rendering of text that did not pass through
/// `is_safe_item_name` (source strings, parse failures, agent-declared
/// skill references): credentials embedded in a URL are removed, control
/// characters become `?` so nothing can start a new line or drive a
/// terminal, and anything long is truncated — an item is never classified on
/// its length, only shortened when shown.
pub(crate) fn display_text(text: &str) -> String {
    let scrubbed: String = scrub_source_credentials(text)
        .chars()
        .map(|c| if c.is_control() { '?' } else { c })
        .collect();
    if scrubbed.chars().count() <= DISPLAY_LIMIT {
        return scrubbed;
    }
    let kept: String = scrubbed.chars().take(DISPLAY_LIMIT).collect();
    format!("{kept}…")
}

/// Human report. `quiet` drops headers and per-item listings and prints
/// nothing at all when no scope has drift; suggestions and cache warnings
/// then ride along only with real drift, so a clean session stays silent.
pub(super) fn render_report(report: &CheckReport, quiet: bool) -> String {
    let mut out = String::new();
    if quiet && !report.drift {
        return out;
    }
    for scope in &report.scopes {
        render_scope(&mut out, scope, quiet);
    }
    if let Some(error) = &report.background_refresh_error {
        out.push_str(&format!(
            "\n  source caches could not be refreshed in the background ({error}); run `vstack refresh` to update them\n"
        ));
    }
    if !report.cache_refresh_failures.is_empty() {
        out.push('\n');
        let shown = shown_count(quiet, report.cache_refresh_failures.len());
        for failure in &report.cache_refresh_failures[..shown] {
            out.push_str(&format!(
                "  source cache {} is not up to date — {}; results may be stale — run `vstack refresh` to retry it now\n",
                display_text(&failure.source),
                failure.reason
            ));
        }
        overflow_line(&mut out, "  ", shown, report.cache_refresh_failures.len());
    }
    out
}

pub(super) fn humanize_age(secs: u64) -> String {
    match secs {
        0..=119 => format!("{secs}s"),
        120..=7199 => format!("{}m", secs / 60),
        _ => format!("{}h", secs / 3600),
    }
}

/// How many lines a single section may spend in the quiet report. The quiet
/// report is relayed verbatim into an agent's context by both session
/// adapters, so its size is bounded BY CONSTRUCTION rather than by how large
/// an inventory happens to be. Headers keep the true counts; the full listing
/// is one `vstack check` away.
const QUIET_SECTION_LIMIT: usize = 10;

/// How many of `total` entries this mode renders.
fn shown_count(quiet: bool, total: usize) -> usize {
    if quiet {
        total.min(QUIET_SECTION_LIMIT)
    } else {
        total
    }
}

/// The `… and M more` line for whatever a capped section left out.
fn overflow_line(out: &mut String, indent: &str, shown: usize, total: usize) {
    if total > shown {
        out.push_str(&format!(
            "{indent}… and {} more (run `vstack check` for the full report)\n",
            total - shown
        ));
    }
}

/// One drift section: a header line and one `glyph name (kind)` line per
/// item, with the item's own detail when the header cannot carry it. Capped
/// in quiet mode; the header's count is always the true total.
fn section(out: &mut String, header: &str, glyph: char, items: &[Item], quiet: bool) {
    if items.is_empty() {
        return;
    }
    out.push_str(&format!("\n  {} {header}:\n", items.len()));
    let shown = shown_count(quiet, items.len());
    for item in &items[..shown] {
        let detail = item
            .detail
            .as_deref()
            .map(|detail| format!(" — {}", display_text(detail)))
            .unwrap_or_default();
        out.push_str(&format!(
            "    {glyph} {} ({}){detail}\n",
            display_text(&item.name),
            item.kind
        ));
    }
    overflow_line(out, "    ", shown, items.len());
}

/// The `? <name>` list a source problem attaches to its header. Every name is
/// scrubbed here rather than at the caller, so the module's guarantee — nothing
/// reaches the report unscrubbed — holds at the point of rendering. Capped in
/// quiet mode; the header above it already carries the true count.
fn render_entry_names(out: &mut String, entries: &[String], quiet: bool) {
    use std::fmt::Write as _;
    let shown = shown_count(quiet, entries.len());
    for name in &entries[..shown] {
        let _ = writeln!(out, "    ? {}", display_text(name));
    }
    overflow_line(out, "    ", shown, entries.len());
}

/// The scope flag every remediation command in a section carries. A section
/// belongs to exactly one scope while `add` and `remove` default to PROJECT
/// scope, so a global section printing a bare `vstack remove <name>` either
/// clears nothing or — when a project install shares the name — removes the
/// wrong one. `vstack refresh` deliberately never takes it: unflagged, it
/// reinstalls at every scope an item is locked at.
fn scope_flag(scope: &str) -> &'static str {
    match scope {
        "global" => " -g",
        _ => "",
    }
}

pub(super) fn render_scope(out: &mut String, report: &ScopeReport, quiet: bool) {
    use std::fmt::Write as _;

    let g = scope_flag(report.scope);

    if quiet {
        if !report.has_drift() {
            return;
        }
        let _ = writeln!(out, "vstack drift — {} scope:", report.scope);
    } else {
        let _ = writeln!(
            out,
            "\n{} scope: {} item(s)",
            report.scope, report.installed
        );
        for item in &report.current {
            let _ = writeln!(out, "  ✓ {} ({})", display_text(&item.name), item.kind);
        }
    }

    section(
        out,
        "outdated — run `vstack refresh` to update",
        '!',
        &report.outdated,
        quiet,
    );
    section(
        out,
        &format!("no longer in source — run `vstack remove{g} <name>`"),
        '✗',
        &report.removed,
        quiet,
    );
    section(
        out,
        &format!("installed on disk but missing from lock — run `vstack add{g}` to recover"),
        '?',
        &report.orphaned,
        quiet,
    );
    section(
        out,
        &format!(
            "in lock but missing from disk — run `vstack add{g}` to clean up, or `vstack remove{g} <name>`"
        ),
        '✗',
        &report.phantom,
        quiet,
    );
    // Deliberately its own section: reinstalling repairs nothing here, and
    // the detail names the file whose repair does.
    section(
        out,
        "installed, but the install could not be verified — repair the file named below",
        '?',
        &report.unverifiable,
        quiet,
    );

    if !report.missing_skill_refs.is_empty() {
        let agents: HashSet<&str> = report
            .missing_skill_refs
            .iter()
            .map(|r| r.agent.as_str())
            .collect();
        let _ = writeln!(
            out,
            "\n  {} agent(s) reference uninstalled skill(s):",
            agents.len()
        );
        let shown = shown_count(quiet, report.missing_skill_refs.len());
        for r in &report.missing_skill_refs[..shown] {
            let _ = writeln!(
                out,
                "    ✗ agent {} references skill {} but it's not installed; run `vstack add{g} --skill {} .` or `vstack add{g}` to auto-install dependent skills.",
                display_text(&r.agent),
                display_text(&r.skill),
                command_arg(&r.skill),
            );
        }
        overflow_line(out, "    ", shown, report.missing_skill_refs.len());
    }

    for issue in &report.source_issues {
        let source = display_text(&issue.source);
        match &issue.problem {
            SourceProblem::Unresolvable { entries } => {
                let _ = writeln!(
                    out,
                    "\n  source {source} is unreachable (cache not cloned or path missing) — {} item(s) cannot be verified; run `vstack add{g} {}` to restore it, or `vstack remove{g} <name>` if it is gone for good:",
                    entries.len(),
                    command_arg(&issue.source),
                );
                render_entry_names(out, entries, quiet);
            }
            SourceProblem::Unreadable { entries, reasons } => {
                let _ = writeln!(
                    out,
                    "\n  source {source} cannot be inventoried — {} item(s) cannot be verified; fix the source layout, refresh cannot:",
                    entries.len()
                );
                let shown = shown_count(quiet, reasons.len());
                for reason in &reasons[..shown] {
                    let _ = writeln!(out, "    ✗ {}", display_text(reason));
                }
                overflow_line(out, "    ", shown, reasons.len());
                render_entry_names(out, entries, quiet);
            }
            SourceProblem::Unverifiable { entries, reason } => {
                let _ = writeln!(
                    out,
                    "\n  source {source} has a cache that is not provably its own ({}) — {} item(s) cannot be verified; remove that directory under ~/.vstack/cache and run `vstack add{g} {}` to re-clone it:",
                    display_text(reason),
                    entries.len(),
                    command_arg(&issue.source),
                );
                render_entry_names(out, entries, quiet);
            }
            SourceProblem::Discovery { failures } => {
                let _ = writeln!(
                    out,
                    "\n  source {source} has {} asset(s) that could not be read — fix them upstream before trusting refresh:",
                    failures.len()
                );
                let shown = shown_count(quiet, failures.len());
                for failure in &failures[..shown] {
                    let _ = writeln!(out, "    ✗ {}", display_text(failure));
                }
                overflow_line(out, "    ", shown, failures.len());
            }
        }
    }

    if !report.invalid_names.is_empty() {
        let _ = writeln!(
            out,
            "\n  {} name(s) rejected (unsafe to render or resolve) — inspect the lock file and installed agents by hand:",
            report.invalid_names.len()
        );
        let shown = shown_count(quiet, report.invalid_names.len());
        for item in &report.invalid_names[..shown] {
            let _ = writeln!(out, "    ✗ <invalid name> ({})", item.kind);
        }
        overflow_line(out, "    ", shown, report.invalid_names.len());
    }

    if !report.available.is_empty() {
        let _ = writeln!(
            out,
            "\n  {} available in source but not installed — suggestions only, ask before adding:",
            report.available.len()
        );
        for kind in CATALOG_KINDS {
            let Some(flag) = kind.add_filter_flag() else {
                continue;
            };
            let offered: Vec<&AvailableItem> =
                report.available.iter().filter(|a| a.kind == kind).collect();
            if offered.is_empty() {
                continue;
            }
            // Group by source: which repo is offering an item is half of
            // deciding whether to add it.
            let mut sources: Vec<&str> = offered.iter().map(|a| a.source.as_str()).collect();
            sources.sort();
            sources.dedup();
            for source in sources {
                let names: Vec<&str> = offered
                    .iter()
                    .filter(|a| a.source == source)
                    .map(|a| a.name.as_str())
                    .collect();
                let shown = shown_count(quiet, names.len());
                let overflow = if names.len() > shown {
                    format!(", … and {} more", names.len() - shown)
                } else {
                    String::new()
                };
                // The source is part of the command, not a footnote: with
                // two sources offering the same name, an unqualified `vstack
                // add --skill <name>` installs whichever one resolution
                // happens to pick.
                let _ = writeln!(
                    out,
                    "    + {} (`vstack add{g} {} {flag} <name>`): {}{overflow}",
                    kind.label_plural(),
                    command_arg(source),
                    names[..shown].join(", ")
                );
            }
        }
    }
}

#[cfg(test)]
mod tests;
