// expect: E0451
// holds: a caller cannot supply evidence the engine's own readers produce
let _evidence = agent_runtime::effects::Recorded { value: 1 };
