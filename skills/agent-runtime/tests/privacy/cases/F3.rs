// expect: disallowed agent_runtime::process::stop_identities
// holds: agent-runtime's own modules signal no process past the engine's handle
let _stop = crate::process::stop_identities(&[], std::time::Duration::ZERO);
