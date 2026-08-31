- **Breaking:** a hook selector spelling `planner` now gates every
  `role: planner` agent, and no rename rewrites it. Renaming a roleless
  `planner` agent drops its gate, so declare the role first.
