// expect: disallowed agent_runtime::effects::Operation::open
// holds: no engine handle is opened outside the lane operation
let _raw = agent_runtime::effects::Operation::open(&run.engine, intent, agent_runtime::effects::Bootstrap::Predecessor);
