//! What the shared declaration paths have to ask Antigravity before they
//! write a hook: whether it fires the event at all, and whether the matcher
//! can be said in its tool names.

use super::ItemWarning;
use super::desired::DesiredState;
use crate::hook::HookSpec;
use crate::model::{HarnessId, ItemKind};

/// The hook as Antigravity would register it, or `None` with the note
/// saying why nothing is registered: an event it has no counterpart for.
pub(super) fn hook(name: &str, hook: &HookSpec, state: &mut DesiredState) -> Option<HookSpec> {
    let Some(registered) = crate::harness::antigravity::hook_for(hook) else {
        state.notes.push(format!(
            "hook {name}: event {} has no Antigravity counterpart, and hanging it on a near-miss would run it at the wrong moment",
            hook.event
        ));
        return None;
    };
    if registered.matcher_as_authored {
        state.warnings.push(ItemWarning {
            kind: ItemKind::Hook,
            name: name.to_owned(),
            harness: Some(HarnessId::Antigravity),
            message: format!(
                "Antigravity matches `{}` against its own tool names, and this matcher carries syntax kendex cannot restate in them — it installs as written and may never match",
                hook.matcher.as_deref().unwrap_or_default()
            ),
            remediation: Some(
                "write the matcher as plain tool names separated by `|`, or check it against Antigravity's names (`run_command`, `view_file`, `write_to_file`)"
                    .to_owned(),
            ),
        });
    }
    Some(registered.hook)
}
