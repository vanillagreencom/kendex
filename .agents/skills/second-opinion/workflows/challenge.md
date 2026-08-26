# Challenge

Adversarial analysis of a proposed approach before implementation.

## 1. Build Prompt

Gather the user's description. The user may be brief — expand from conversation context:

| User says | What to include in prompt |
|-----------|--------------------------|
| "challenge my refactor approach" | Summarize the approach from recent conversation, include relevant code |
| "challenge using async here" | Describe the async pattern being considered, include the code in question |
| "challenge this design" + file paths | Read the files, describe the design |

Read relevant code files for context, then write a prompt file to `tmp/second-opinion-prompt.md`:

<prompt_template>
You are an adversarial reviewer providing a cross-model second opinion. The developer wants to take the following approach — your job is to stress-test it.

**Proposed approach:**
[USER_DESCRIPTION]

**Relevant code:**
[CODE_SNIPPETS — include file paths as headers]

Analyze thoroughly:
1. **Risks** — What could go wrong? Failure modes, data loss scenarios, security implications.
2. **Edge cases** — What inputs, states, or timing conditions are unhandled?
3. **Alternatives** — What other approaches exist? Include concrete trade-offs.
4. **Assumptions** — What is the developer assuming that might not hold?

Be specific — reference actual code paths, function names, and behaviors. No vague warnings.

Structure your response exactly as:

## Risks
[numbered list with severity: CRITICAL / HIGH / MEDIUM / LOW]

## Edge Cases
[numbered list — describe the scenario AND what would happen]

## Alternatives
[numbered list — each with: approach, trade-off, when to prefer it]

## Verdict
[1-2 sentences: PROCEED (approach is sound), RECONSIDER (fixable concerns), or STOP (fundamental flaw)]
</prompt_template>

## 2. Run Script

The default timeout (`SECOND_OPINION_TIMEOUT`, 1080s) exceeds the ~600s ceiling a harness puts on a foreground shell call — on Claude Code use `run_in_background` (Pi: `bg_task`; Codex/OpenCode: scheduled re-entry), or pass `--timeout` at or below the foreground ceiling.

```bash
.agents/skills/second-opinion/scripts/second-opinion challenge \
  --prompt tmp/second-opinion-prompt.md \
  --cwd [PROJECT_PATH]
```

## 3. Present Results

Present the structured response directly. Highlight CRITICAL/HIGH risks with emphasis.
