// expect: E0603
// holds: a caller names no standing token, so it cannot build one
let _token = agent_runtime::effects::obligations::Standing { key: () };
