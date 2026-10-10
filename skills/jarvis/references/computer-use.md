# Computer use

## Desktop and terminal

- Use the supported desktop or terminal interface for the delegated task under [decisions.md:Approach](decisions.md#approach).
- Keep test and scratch windows off the user's visible screen. Use a separate workspace or hidden session the available tool supports.
- Check the target window or pane before sending input. Never type into one that holds the user's draft. Use a separate empty target for assistant work.
- Before taking the user's mouse or keyboard, request agreement through [communication.md:Message types](communication.md#message-types). Wait for their answer.
- To stop a process, use its own process id after checking that it still belongs to the task. Do not stop unrelated processes by a shared name.
- Ask before restarting the machine. Preserve open work before an authorized restart.

## Recovery

- Diagnose the failed operation before replacing files or services. Read the failure at its source.
- Back up work that replacement can destroy. Read the backup back and verify that it holds the required work.
- Request replacement approval under [decisions.md:Authority](decisions.md#authority), then replace through the supported interface. Check that work survives and the operation resumes under [verification.md:Acceptance](verification.md#acceptance).
- Keep a local patched build only as a named unblocker. Record the failure it removes, its owner and its removal condition. Remove it when that condition holds.

## Scratch files

- Keep scratch work separate from user drafts and official records.
- Remove scratch files when their work ends. Apply [accounts-and-secrets.md:Retention](accounts-and-secrets.md#retention) to any artifact still needed for an open obligation.
