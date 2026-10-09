# Wait for current-head Copilot work

Read before the thread count in `thread-read.md`, before review-pr-comments § 1 and § 6.3 read `pr-data`, and before § 7.2 requests a review or sends a head notice.

Run through [Waiter launch](waiter-launch.md):

```bash
env -u GH_REPO -u GITHUB_REPOSITORY .agents/skills/orch/scripts/copilot-wait [PR_NUMBER] --item [ISSUE_ID]
```

Outside a managed lane, omit `--item`. Keep the result line for the current head as `[COPILOT_WAIT]`. The bound is `ORCH_COPILOT_HOLD_SECS`; `copilot-wait --help` owns its default, output fields and exits. The shared `scripts/lib/copilot-check-runs.sh` reader checks the head's runs and pending Copilot timeline requests.

- `state=none` or `state=settled`, exit `0`: continue the calling read. A settled result names the review, or `review=none` when the check completed without one. Read threads and review bodies after the wait.
- `state=expired`, exit `1`: report its run id, start time and waited seconds. Continue the calling read under the existing gate. The expiry grants no approval.
- A keyed refusal, any other nonzero exit: report it and stop the calling read. A failed read is never `state=none`.
- Exit `5`: read `lane-mail inbox --item [ISSUE_ID]`, act on its mail, then launch a fresh wait through Waiter launch. This exit has no result.

Use the result's `head` for this read. A different head observed later requires this wait again. In review-pr-comments § 7.2, a `run` other than `none` on `[HEAD_SHA]` means a Copilot request already exists on that head. Record it as `pr_approval.copilot_rerequest_head`, send no second request, and use that step's approval wait.
