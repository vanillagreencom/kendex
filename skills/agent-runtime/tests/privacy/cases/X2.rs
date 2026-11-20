// expect: E0451
// holds: a caller cannot forge the receipt of the handle's `signalled` write
let _receipt = agent_runtime::effects::Signalled { _written: () };
