// expect: E0603
// holds: lane evidence is built only by the lane operation's own reads and acts
let _evidence = super::lane_operation::lane_obligations::LaneDischarge::Validation(
    super::lane_operation::lane_obligations::ValidationEnd::Stopped,
);
