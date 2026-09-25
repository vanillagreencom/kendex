use std::time::Duration;

use clap::Subcommand;
use kendex_core::env::Env;
use kendex_core::trash::{self, Stopped};

use super::engine_common::ask_before_writing;
use super::{CliResult, out, say};
use crate::ui;

/// The trash every removal's bytes go to: what it holds, and the one way
/// to empty it by hand. The automatic bound runs at the end of the verbs
/// `docs/architecture/trash.md` names; this verb is for the person who
/// wants to see it or take more out.
#[derive(Subcommand)]
pub enum TrashCommand {
    /// What the trash holds: each entry's name, age and size, newest first
    List,
    /// Remove entries from the trash: every one, or every one past an age
    Empty {
        /// Remove only the entries at least this many days old
        #[arg(long, value_name = "DAYS")]
        older_than: Option<u64>,
        /// Remove without asking
        #[arg(short = 'y', long)]
        yes: bool,
    },
}

pub fn run(env: &Env, command: TrashCommand) -> CliResult {
    match command {
        TrashCommand::List => list(env),
        TrashCommand::Empty { older_than, yes } => empty(env, older_than, yes),
    }
}

/// One line per entry on stdout, name first, so a script can read the
/// names back; the count and total close on stderr with the rest of the
/// human output.
fn list(env: &Env) -> CliResult {
    let listed = trash::list(env)?;
    if listed.is_empty() {
        say("the trash is empty");
        return Ok(());
    }
    for entry in &listed {
        out(&format!(
            "{}  {}  {}",
            entry.name,
            age(entry.age_secs),
            size(entry.bytes)
        ));
    }
    let total: u64 = listed.iter().map(|entry| entry.bytes).sum();
    say(&format!(
        "{} entr{}, {}",
        listed.len(),
        plural(listed.len()),
        size(total)
    ));
    Ok(())
}

/// Every entry, or every entry past the age given. The trash is the one
/// way back from a removal nobody wanted, so with no age to narrow it,
/// and an age of zero narrows nothing, the verb asks first, and with
/// nobody to ask it refuses and names `--yes`.
fn empty(env: &Env, older_than: Option<u64>, yes: bool) -> CliResult {
    ui::intro("kendex trash empty");
    let bound = older_than.map(|days| Duration::from_secs(days.saturating_mul(86_400)));
    if bound.is_none_or(|bound| bound.is_zero()) {
        let held = trash::entries(env)?.len();
        if held == 0 {
            ui::ledger("Trash: nothing to remove", &[]);
            return Ok(());
        }
        ask_before_writing(
            &format!(
                "remove every entry in the trash ({held} entr{})?",
                plural(held)
            ),
            yes,
        )?;
    }
    match trash::empty(env, bound) {
        Ok(removed) => {
            ui::ledger(
                &format!("Trash: removed {removed} entr{}", plural(removed)),
                &[],
            );
            Ok(())
        }
        Err(Stopped { removed, reason }) => Err(format!(
            "trash: removed {removed} entr{}, then stopped: {reason}",
            plural(removed)
        )
        .into()),
    }
}

fn plural(count: usize) -> &'static str {
    if count == 1 { "y" } else { "ies" }
}

/// An age in whole days and hours, or in hours and minutes under a day.
fn age(secs: u64) -> String {
    let days = secs / 86_400;
    let hours = (secs % 86_400) / 3600;
    let minutes = (secs % 3600) / 60;
    match days {
        0 => format!("{hours}h {minutes}m"),
        _ => format!("{days}d {hours}h"),
    }
}

/// A byte count in the unit that keeps it under four digits.
fn size(bytes: u64) -> String {
    const KB: f64 = 1024.0;
    const MB: f64 = KB * 1024.0;
    const GB: f64 = MB * 1024.0;
    let bytes_f = bytes as f64;
    if bytes_f >= GB {
        format!("{:.2} GB", bytes_f / GB)
    } else if bytes_f >= MB {
        format!("{:.1} MB", bytes_f / MB)
    } else if bytes_f >= KB {
        format!("{:.0} KB", bytes_f / KB)
    } else {
        format!("{bytes} B")
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn an_age_reads_in_days_and_hours_or_hours_and_minutes() {
        let rows: [(u64, &str); 4] = [
            (0, "0h 0m"),
            (5 * 60 + 30, "0h 5m"),
            (3 * 3600 + 7 * 60, "3h 7m"),
            (2 * 86_400 + 4 * 3600 + 59 * 60, "2d 4h"),
        ];
        for (secs, shown) in rows {
            assert_eq!(age(secs), shown, "{secs}");
        }
    }

    #[test]
    fn a_size_reads_in_the_unit_that_fits_it() {
        let rows: [(u64, &str); 5] = [
            (0, "0 B"),
            (1023, "1023 B"),
            (12 * 1024, "12 KB"),
            (240 * 1024 * 1024 + 512 * 1024, "240.5 MB"),
            (3 * 1024 * 1024 * 1024, "3.00 GB"),
        ];
        for (bytes, shown) in rows {
            assert_eq!(size(bytes), shown, "{bytes}");
        }
    }
}
