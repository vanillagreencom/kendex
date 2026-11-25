# Computer use

## Desktop and terminal

- Use the supported desktop or terminal interface for the delegated task under [decisions.md:Approach](decisions.md#approach).
- Keep test and scratch windows off the user's visible screen.
  - Use a separate workspace or hidden session the available tool supports.
  - The home's standing instructions may name one of the home's own computers where the user watches the assistant's browser windows. On that computer, those windows open on the visible desktop without taking keyboard focus.
- Check the target window or pane before sending input.
  - Never type into one that holds the user's draft.
  - Use a separate empty target for assistant work.
- Before taking the user's mouse or keyboard, request agreement through [communication.md:Message types](communication.md#message-types).
  - Wait for their answer.
- To stop a process, use its own process id after checking that it still belongs to the task. Do not stop unrelated processes by a shared name.
- Ask before restarting the machine.
- Preserve open work before an authorized restart.
- Start a long-running service through the platform's service manager or the existing job runner, such as the orch skill's job runner.
  - Check that it runs after the start.

## Recovery

1. Diagnose the failed operation before replacing files or services.
   - Read the failure at its source.
2. Apply [SKILL.md:Cleanup and backups](../SKILL.md#cleanup-and-backups) before replacement.
   - If a backup is needed, read it back.
   - Verify that it holds the required work.
3. Request replacement approval under [decisions.md:Authority](decisions.md#authority).
4. Replace through the supported interface.
5. Check that work survives and the operation resumes under [verification.md:Acceptance](verification.md#acceptance).

Keep a local patched build only as a named unblocker.

- Record the failure it removes, its owner and its removal condition.
- Remove it when that condition holds.

## Scratch files

- Keep the session's scratch work under its own folder, `tmp/scratch/` in the [home layout](home-layout.md), separate from user drafts and official records.
- Other files under `tmp/` are state of the packages that wrote them; leave them to their writers.
- Remove scratch files when their work ends.
- Keep artifacts needed for an audit or open obligation under `tmp/scratch/retained/`.
- Apply [accounts-and-secrets.md:Retention](accounts-and-secrets.md#retention) to those artifacts.
- A scheduled scratch sweep runs this command from the home root and nothing wider. It deletes scratch untouched for three days outside `tmp/scratch/retained/`, and a missing `tmp/scratch/` is an empty sweep:

  ```sh
  [ ! -d tmp/scratch ] || find tmp/scratch -type f ! -path 'tmp/scratch/retained/*' -mtime +2 -delete
  ```
