// expect: E0507
// holds: no terminal is reached through a borrowed handle
let _outcome = op.settle(agent_runtime::effects::Word::Confirmed, Default::default());
