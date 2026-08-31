- **Breaking:** a hook selector spelling `planner` gates every `role: planner`
  agent and no rename rewrites it, so an agent named `planner` with no role
  falls out of the gate. Declare the role.
