// expect: disallowed orch_runtime::effects::operation::Operation::open
// holds: no engine handle is opened outside the lane operation
let _raw = super::operation::Operation::open(run, intent, super::operation::Bootstrap::Predecessor);
