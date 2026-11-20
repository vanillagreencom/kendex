// expect: E0451
// holds: a terminal outcome's parts are the engine's, so a caller neither builds one nor takes one apart
let agent_runtime::effects::EffectOutcome { intent_id, .. } = owned.hold(Default::default());
