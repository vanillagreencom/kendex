# Reframe a completed blocker as stale metadata. The rule this suite guards is
# that an audit must never reach that conclusion.
control_expect "completed blockers framed as satisfied history, not stale metadata"
control_replace SKILL.md 1 \
    'A blocking relation pointing at a Done or Canceled issue is **satisfied history, not stale metadata**. The relation stays for provenance; never remove or "fix" it, and audits must never classify it as stale. The only legitimate audit output for a completed-blocker relation is a scheduling signal ("gates cleared, ready to schedule").' \
    'A blocking relation pointing at a Done or Canceled issue is stale metadata.'
