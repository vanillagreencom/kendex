//! A fresh manifest points at the tools on this machine kendex can actually
//! write to. A tool it can only read is still found and reported — it just
//! never becomes a target whose every install would silently do nothing.
#![cfg(unix)]

use std::fs;

use kendex_core::engine::ops;
use kendex_core::env::{Env, FakeOs};
use kendex_core::harness::installable;
use kendex_core::model::{HarnessId, Scope};
use kendex_core::scan;
use kendex_core::settings::AppSettings;

#[test]
#[allow(clippy::unwrap_used)]
fn a_fresh_manifest_targets_the_tools_it_can_write_to() {
    let tmp = tempfile::tempdir().unwrap();
    let home = tmp.path();
    let env = Env::fake(home, FakeOs::Linux);
    for root in [".claude", ".gemini", ".copilot"] {
        fs::create_dir_all(home.join(root)).unwrap();
    }
    // Gemini CLI is marked by its settings file, not the directory.
    fs::write(home.join(".gemini/settings.json"), "{}\n").unwrap();

    let detected: Vec<_> = scan::scan(&env, &AppSettings::default())
        .harnesses
        .iter()
        .map(|h| h.harness)
        .collect();
    assert_eq!(
        detected,
        [HarnessId::Claude, HarnessId::Gemini, HarnessId::Copilot]
    );

    // Copilot is a full install target now that kendex writes its agents,
    // skills, hooks and servers — the seed follows the capability table
    // rather than a list of its own.
    let manifest = ops::manifest_for_mutation(&env, &Scope::Global).unwrap();
    let writable: Vec<_> = detected.into_iter().filter(|h| installable(*h)).collect();
    assert_eq!(manifest.install.harnesses, writable);
    assert!(writable.contains(&HarnessId::Copilot));
}
