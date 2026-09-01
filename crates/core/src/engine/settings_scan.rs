//! The one thing outside the engine may ask a scope pass about settings:
//! which template each installed skill ships here.
//!
//! Deriving that is the closure's work — which skills a scope installs is
//! what the manifest, the sets it carries and the dependencies those pull
//! in decide together, and only the pass that walks them knows. Reading
//! the templates it found is [`crate::settings_view`]'s, and that lives
//! outside because parsing a template and comparing it with a consumer's
//! file has nothing to do with planning a write.
//!
//! So the boundary is this function and nothing else. A caller that
//! reached past it into the desired-state computation would be bound to
//! the shape of an engine internal, and would break every time one moved.

use std::collections::BTreeMap;

use crate::env::Env;
use crate::error::Result;
use crate::lock::lock_path;
use crate::manifest;
use crate::model::Scope;
use crate::settings_template::TemplateSource;

/// The `kendex.settings.toml.example` each skill installed at this scope
/// ships, by skill name — its text, that the skill ships none, or why
/// nothing here could read one.
///
/// One entry per skill the closure plans, so a skill this answers for is a
/// skill an apply would seed for, and the two cannot come apart. A place
/// with no manifest answers with nothing, the posture
/// [`super::plan_apply`] takes for the same file; one whose files this
/// build cannot read refuses, the way every other read of them does.
/// Global scope answers with nothing too: a global install seeds no
/// settings.
pub fn settings_templates(env: &Env, scope: &Scope) -> Result<BTreeMap<String, TemplateSource>> {
    let scope = &scope.canonical();
    let lock = crate::lock::load(&lock_path(env, scope))?;
    let Some(manifest) = manifest::load_current(&manifest::manifest_path(env, scope))? else {
        return Ok(BTreeMap::new());
    };
    let state = super::desired::desired_state(env, scope, &manifest, &lock, false, None)?;
    Ok(state.settings_templates)
}

/// What a pass records for a skill before it has reached it: every planned
/// skill starts out of reach, and the pass overwrites this the moment it
/// can say better. A skill still carrying it is one whose source never
/// resolved, whose item the source no longer has, or that a hostile
/// catalog read refused — one answer for every way of not getting there,
/// in place of an absent entry a reader would have to interpret.
pub(super) fn out_of_reach(
    scope: &Scope,
    name: &str,
    templates: &mut BTreeMap<String, TemplateSource>,
) {
    seeds_nothing(
        scope,
        name,
        "nothing here could read this skill's source, so what it declares is unknown",
        templates,
    );
}

/// Why this skill seeds nothing even though its source read fine.
pub(super) fn seeds_nothing(
    scope: &Scope,
    name: &str,
    reason: &str,
    templates: &mut BTreeMap<String, TemplateSource>,
) {
    // Project scope only: a global install seeds no settings, so a pass
    // there has nothing to say about a template either way.
    if matches!(scope, Scope::Project { .. }) {
        templates.insert(
            name.to_owned(),
            TemplateSource::Unreadable(reason.to_owned()),
        );
    }
}
