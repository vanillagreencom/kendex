// expect: disallowed agent_runtime::process::identity
// holds: an effect file reads no process past the engine handle
let _read = agent_runtime::process::identity(1);
