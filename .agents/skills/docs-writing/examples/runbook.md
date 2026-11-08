# Delivery service runbook

This example uses a fictional service with an operator console. Its controls and readings illustrate a procedure, not a deployed system's contract.

```markdown
# Delivery service operations

## Resume deliveries after maintenance

Use this procedure when maintenance is complete and production deliveries remain paused. It resumes queued deliveries before accepting new ones.

### Prerequisites

- The maintenance owner confirms that production can resume. The incident record holds approval to start the worker, reopen intake and pause the worker if verification fails.
- You have temporary operator access to the production console and can read the delivery log. Check that the console's environment label says `production`. The maintenance owner approves a delivery to the test account and its cleanup.
- No other operator is changing intake or worker state. Record your ownership of this procedure in the incident record.

### Procedure

1. Read the console's intake and worker states. Both must show `paused`. Record the queue depth and failed-delivery count in the incident record. If a reading is unavailable or a state differs, stop and contact the maintenance owner without changing the controls.
2. Start the worker while intake stays paused. The console must show the worker as `running`. If it does not, use Failure handling before continuing.
3. Check the delivery log for the queued work. The queue must drain, and the failed-delivery count must not increase from the recorded value. If the queue was empty, continue to the intake check and test delivery in the next step. A queue the console reports as stalled, a new failure or an unreadable log takes Failure handling.
4. Reopen intake. Confirm that the console shows intake as `open` and the worker as `running`. Send the approved delivery to the test account and confirm its receipt in the log. If any check fails, use Failure handling.

### Failure handling

Pause intake and pause the worker. Confirm that both controls show `paused`; if either state is unreadable or the controls fail, report that unresolved state to the maintenance owner immediately. Preserve queued deliveries. Do not clear the queue or repeat the start.

Send the maintenance owner the incident record with the environment, failed step, observed states and delivery-log evidence. The owner decides the next recovery action. This procedure grants no approval to change the release or replay failed deliveries.

### Completion and cleanup

Record the final intake and worker states, test-delivery receipt and failed-delivery count in the incident record. State whether deliveries resumed or the procedure stopped with an unresolved check.

If you sent a test delivery, remove it through the test account's cleanup control and confirm its removal. End temporary operator access and confirm that access ended. Keep any exported logs until the maintenance owner confirms the evidence is readable in the incident record, then remove only the temporary copies you created. Record any incomplete cleanup for the owner.
```

---

## Not this

> `docs/runbook.md`: an operator; step-by-step procedures for a running system.

A declared file type without a route to rules and a finished example leaves the author unable to follow the requirement to read both before writing. The [runbook route](../SKILL.md#per-file-type) leads to the rules and this procedure; the file-type label alone does not teach an author how to state prerequisites, expected readings, failure handling or cleanup.
