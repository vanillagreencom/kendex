---
applyTo: "hooks/**"
---

Security containment here is deliberately fail-closed allowlisting (e.g. the
connectors-mode PreToolUse hook). The allowlist design is intended — do not
recommend switching to denylists or loosening the fail-closed posture.
