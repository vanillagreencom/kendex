//! A hook, read as the rules should see it: the file when the hook is
//! its own file, and its own registration — command plus the values it
//! stores — when it lives inside a shared config file.

use crate::model::{FileState, HarnessId, ObservedItem};

use super::{Content, UNREADABLE_FILE, read_document};

/// A hook found inside a shared config file whose registration is not in
/// the file any more.
const UNREAD_HOOK_ENTRY: &str =
    "this hook's registration was not found in the config file that was scanned for it";
/// A registry file that would not parse holds no entry to dig out.
const HOOK_REGISTRY_UNPARSED: &str = "the config file holding this hook's registration could not be parsed, so none of it was scored";

/// A hook, read as the rules should see it.
///
/// A hook that is its own file — opencode's instruction carrier — is the
/// file, and all of it is scored. A hook observed inside a shared config
/// file is scored on its own registration: the command text of every entry
/// the file holds under this observation's name, plus the env and header
/// values those entries store (see [`stored_values`]), and nothing beside
/// them. Sibling entries and the `permissions.ask`/`permissions.deny` lists are
/// not this hook's content — an ask-list entry is a guard *against* a
/// dangerous command, and reading the whole file as every hook's script
/// would turn one `mkfs` guard into a high-severity finding on every
/// hook registered in the same settings.json. The file is
/// parsed by the reader the scan chose for its harness and matched by the
/// same name construction the scan listed it under, so the entry the scan
/// found is the entry scored here.
pub(super) fn read_hook(item: &ObservedItem) -> Content {
    let Content::Document { text } = read_document(&item.path) else {
        return Content::Unread {
            why: UNREADABLE_FILE,
        };
    };
    if item.file_state != FileState::ConfigEntry {
        return Content::Hook {
            event: String::new(),
            matcher: None,
            command: crate::paths::slashed(&item.path),
            values: None,
            script: Some(text),
        };
    }
    let parsed = match item.harness {
        HarnessId::Copilot => crate::scan::copilot::registrations_text(&text),
        _ => crate::scan::hooks::registrations_text(&text),
    };
    let Ok(mut registrations) = parsed else {
        return Content::Unread {
            why: HOOK_REGISTRY_UNPARSED,
        };
    };
    registrations.retain(|reg| reg.name() == item.name);
    let Some(first) = registrations.first() else {
        return Content::Unread {
            why: UNREAD_HOOK_ENTRY,
        };
    };
    // Names collide only when event, matcher and command stem all agree,
    // so the one observation the scan lists stands for every registration
    // under that name, and every one of them is scored — every executable
    // each one carries, one per line, since the harness runs whichever
    // fits the platform.
    Content::Hook {
        event: first.event.clone(),
        matcher: Some(first.matcher.clone()).filter(|m| m != crate::scan::hooks::ANY_MATCHER),
        command: registrations
            .iter()
            .flat_map(crate::scan::hooks::Registration::executables)
            .collect::<Vec<_>>()
            .join("\n"),
        values: Some(
            registrations
                .iter()
                .flat_map(|reg| stored_values(&reg.entry))
                .collect::<Vec<_>>()
                .join("\n"),
        )
        .filter(|values| !values.is_empty()),
        script: None,
    }
}

/// The values a registration stores beside its command and hands to the
/// harness as they are: every string under its `env` and `headers` maps,
/// in the order the parsed entry keeps them. Nothing else of the entry is
/// text a rule reads — the keys, the matcher, a cwd, a url and the event
/// are its shape, and scoring them as commands is the false attribution
/// the narrowed reading exists to remove.
fn stored_values(entry: &serde_json::Value) -> impl Iterator<Item = String> + '_ {
    ["env", "headers"]
        .into_iter()
        .filter_map(move |key| entry.get(key).and_then(serde_json::Value::as_object))
        .flat_map(|map| map.values().filter_map(serde_json::Value::as_str))
        .map(str::to_owned)
}
