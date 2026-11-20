// expect: disallowed agent_runtime::process::stop_group
// holds: agent-runtime's own modules signal no recorded group past the engine's handle or the session command's exact stop
let _stop = crate::process::stop_group(&crate::process::Identity { pid: 0, start: String::new() }, std::time::Duration::ZERO);
