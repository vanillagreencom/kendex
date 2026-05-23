use crate::config::{self, LockFile};
use crate::harness::Harness;
use crate::scope::ScopeFilter;
use anyhow::Result;

pub fn run(scope: ScopeFilter, harness_filter: Option<&str>) -> Result<()> {
    let mut printed_anything = false;
    let mut totals = (0usize, 0usize, 0usize, 0usize, 0usize); // agents, skills, hooks, pi, extras

    for &global in scope.globals() {
        let lock_path = config::lock_file_path(global);
        let lock = LockFile::load(&lock_path).unwrap_or_default();
        let scope_label = if global { "GLOBAL" } else { "PROJECT" };
        let scope_target = if global {
            config::display_path(&config::global_state_dir())
        } else {
            config::display_path(&config::project_root())
        };

        if lock.entries.is_empty() {
            // For an explicit single-scope run, surface that the lock is empty.
            if matches!(scope, ScopeFilter::Project | ScopeFilter::Global) {
                eprintln!("{scope_label} ({scope_target}): nothing installed.");
                printed_anything = true;
            }
            continue;
        }

        let mut agents = Vec::new();
        let mut skills = Vec::new();
        let mut hooks = Vec::new();
        let mut pi_extensions = Vec::new();
        let mut extras = Vec::new();

        for entry in lock.entries.values() {
            if let Some(filter) = harness_filter
                && let Some(harness) = Harness::from_id(filter)
                && !entry
                    .harnesses
                    .iter()
                    .any(|installed| installed == harness.id())
            {
                continue;
            }

            match entry.kind {
                config::ItemKind::Agent => agents.push(entry),
                config::ItemKind::Skill => skills.push(entry),
                config::ItemKind::Hook => hooks.push(entry),
                config::ItemKind::PiExtension => pi_extensions.push(entry),
                config::ItemKind::Extra => extras.push(entry),
            }
        }

        if agents.is_empty()
            && skills.is_empty()
            && hooks.is_empty()
            && pi_extensions.is_empty()
            && extras.is_empty()
        {
            continue;
        }

        if printed_anything {
            eprintln!();
        }
        eprintln!("{scope_label} ({scope_target}):");

        for (label, items) in [
            ("Agents", &agents),
            ("Skills", &skills),
            ("Hooks", &hooks),
            ("Pi packages", &pi_extensions),
            ("Extras", &extras),
        ] {
            if items.is_empty() {
                continue;
            }
            eprintln!("  {label}:");
            for entry in items {
                let harnesses = entry.harnesses.join(", ");
                eprintln!("    {} ({}) [{}]", entry.name, entry.method, harnesses);
            }
        }

        totals.0 += agents.len();
        totals.1 += skills.len();
        totals.2 += hooks.len();
        totals.3 += pi_extensions.len();
        totals.4 += extras.len();
        printed_anything = true;
    }

    if !printed_anything {
        eprintln!("No items installed.");
        return Ok(());
    }

    eprintln!(
        "\nTotal: {} agent(s), {} skill(s), {} hook(s), {} Pi package(s), {} extra(s)",
        totals.0, totals.1, totals.2, totals.3, totals.4
    );
    Ok(())
}
