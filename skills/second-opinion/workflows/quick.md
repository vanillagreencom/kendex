# Quick

Lightweight question to the other model. No structured output format.

## 1. Build Prompt

Gather the user's question. Optionally read relevant files for context, then write a prompt file to `tmp/second-opinion-prompt.md`:

<prompt_template>
[QUESTION]

[If relevant files were identified:]
For context, read these files:
[FILE_LIST — one per line]

Answer concisely and directly. If you need to examine code in this project to answer, do so. Focus on what's practically useful — no hedging or disclaimers.
</prompt_template>

## 2. Run Script

Run `second-opinion …`; it backgrounds itself and prints when to check.

Either pass the prompt file or the question inline:

```bash
# With prompt file:
.agents/skills/second-opinion/scripts/second-opinion quick \
  --prompt tmp/second-opinion-prompt.md \
  --cwd [PROJECT_PATH] \
  --foreground

# Or inline (when no file context is needed):
.agents/skills/second-opinion/scripts/second-opinion quick \
  "[QUESTION]" \
  --cwd [PROJECT_PATH] \
  --foreground
```

Execute the exact command printed after `wait:` and follow its exit handling in `second-opinion --help` until terminal. On success, read the file printed after `artifact:` with `cat < [ARTIFACT_PATH]`.

## 3. Present Results

Present the artifact contents directly — no additional framing.
