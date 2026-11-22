# Error Handling

- On a script failure, report the reason it states. Error forms, exit codes and preserved-response paths: `second-opinion --help`.
- A CLI-failure record, `<output>.failed.json` at exit 5 or 6, holds the reason, the cause with its source, the partial output and each attempt.

Fix each reason a refused candidate names as follows:

- An ineligible target: install its CLI, or adjust `SECOND_OPINION_<NAME>_CMD`, `SECOND_OPINION_MODELS` or `SECOND_OPINION_CURRENT_MODEL`. Never force the same model.
- `model undeclared`: set that target's `SECOND_OPINION_<NAME>_MODEL` to the model id it runs.
- `room check refused`: the candidate names the check's setting and its exit. For a stock Copilot entry it quotes the default command. The check's own stderr, passed through above it, holds the cause.
  1. Run that command.
  2. Read its keyed line: a wall to wait out, or a setting or read to fix. For the stock check, see `agent-runtime accounts pick --help`.
- `room check printed a line that is no NAME=value assignment`: the candidate quotes that line. The check must print only the `NAME=value` env prefix of the account it judged. Fix that `SECOND_OPINION_<NAME>_ROOM_CMD` command, for example by dropping a `--json` flag.
- `room check unavailable`: the candidate quotes the check's command.
  - Install its program. For a stock Copilot entry, that is agent-runtime in the project this skill is installed in. A global install has no project, so there its check is always unavailable.
  - Or set that entry's `SECOND_OPINION_<NAME>_ROOM_CMD` or `_CMD`.
  - Or leave the entry out of `SECOND_OPINION_MODELS`.

For any room-check reason, the next roster entry reviews meanwhile. Never remove a room check to get past it.

For a timeout, suggest a larger `--timeout` or a narrower `--range`.
