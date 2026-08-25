//! The carrier that makes hooks real on Pi. Pi has no per-hook artifact:
//! the `pi-hooks` extension package hosts native listeners, and hook
//! content rides in the registry kendex renders beside them. A hook
//! "installed" for Pi without the carrier registered anywhere Pi loads is
//! written but never runs — so every label reads carrier reality instead
//! of claiming enforcement the runtime cannot deliver.

use std::path::Path;

use serde_json::Value;

use crate::env::Env;
use crate::harness::Enforcement;
use crate::model::{HarnessId, Scope};

/// The carrier package's name, as its directory and npm name both end.
pub const CARRIER: &str = "pi-hooks";

/// Whether a settings entry's text names the carrier, in any of the
/// spellings Pi loads: a relative or absolute path ending in the package
/// directory, a bare or scoped npm name, an `npm:` spec, with or without
/// a version suffix or trailing slash.
fn names_carrier(raw: &str) -> bool {
    let text = raw.strip_prefix("npm:").unwrap_or(raw);
    let text = text.trim_end_matches('/');
    // A version suffix is an `@` inside the last path segment, past that
    // segment's first character — an `@` opening a segment is a scope
    // (`@vanillagreen/pi-hooks`, `./packages/@vanillagreen/pi-hooks`),
    // identity rather than version.
    let segment = text.rfind('/').map_or(0, |slash| slash + 1);
    let text = match text.rfind('@') {
        Some(at) if at > segment => &text[..at],
        _ => text,
    };
    text == CARRIER || text.ends_with(&format!("/{CARRIER}"))
}

fn entry_is_carrier(entry: &Value) -> bool {
    match entry {
        Value::String(text) => names_carrier(text),
        Value::Object(object) => object
            .get("source")
            .and_then(Value::as_str)
            .is_some_and(names_carrier),
        _ => false,
    }
}

/// Whether one settings file registers the carrier. Unreadable or absent
/// reads as not registered — the conservative answer, which downgrades a
/// label rather than upgrading one.
fn settings_register_carrier(scope_root: &Path) -> bool {
    let path = super::settings_path(scope_root);
    let Ok(Some(text)) = crate::fs::read_if_exists(&path) else {
        return false;
    };
    let Ok(value) = serde_json::from_str::<Value>(&text) else {
        return false;
    };
    value
        .get("packages")
        .and_then(Value::as_array)
        .is_some_and(|packages| packages.iter().any(entry_is_carrier))
}

/// Where the carrier is registered, of the settings layers Pi loads for
/// this scope. Pi loads project and global settings both, so a
/// project-installed hook with only a global carrier still runs — the
/// v1 #1407 lesson, carried here as behavior.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct CarrierPresence {
    pub project: bool,
    pub global: bool,
}

impl CarrierPresence {
    pub fn anywhere(&self) -> bool {
        self.project || self.global
    }
}

pub fn presence(env: &Env, scope: &Scope) -> CarrierPresence {
    let global_root = crate::harness::adapter(HarnessId::Pi).default_global_root(env);
    CarrierPresence {
        global: settings_register_carrier(&global_root),
        project: match scope {
            Scope::Global => false,
            Scope::Project { root } => settings_register_carrier(&root.join(".pi")),
        },
    }
}

/// What a Pi hook label may honestly claim at this scope: enforced only
/// while the carrier is really registered somewhere Pi loads, advisory
/// otherwise — a rendered registry nothing executes is prose.
pub fn enforcement(env: &Env, scope: &Scope) -> Enforcement {
    match presence(env, scope).anywhere() {
        true => Enforcement::Enforced,
        false => Enforcement::Advisory,
    }
}

#[cfg(test)]
mod tests {
    use super::names_carrier;

    #[test]
    fn every_spelling_pi_loads_counts_and_lookalikes_do_not() {
        for entry in [
            "pi-hooks",
            "./packages/pi-hooks",
            "/abs/path/packages/pi-hooks",
            "@vanillagreen/pi-hooks",
            "./packages/@vanillagreen/pi-hooks",
            "/abs/path/packages/@vanillagreen/pi-hooks",
            "npm:@vanillagreen/pi-hooks@0.4.0",
            "npm:pi-hooks@1.2.3",
            "./packages/pi-hooks/",
        ] {
            assert!(names_carrier(entry), "{entry}");
        }
        for entry in [
            "pi-hooks-extra",
            "other-hooks",
            "./packages/my-pi-hooks-fork",
        ] {
            assert!(!names_carrier(entry), "{entry}");
        }
    }
}
