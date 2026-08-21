# Audit

Deep examination of existing code — not changes, but the code as it is. Returns review-finding JSON.

## 1. Build Prompt

Identify target files/directories from user request. Read the code to understand scope, then write a prompt file to `tmp/second-opinion-prompt.md`:

<prompt_template>
You are a code auditor providing a cross-model second opinion. Examine the specified code for quality issues.

**Files to audit:**
[FILE_LIST — one per line]

Read each file. Focus on:
- Bugs and logic errors
- Security vulnerabilities (injection, auth bypass, data exposure)
- Race conditions and concurrency issues
- Resource leaks (file handles, connections, memory)
- Error handling gaps (silent failures, swallowed errors)
- Design problems (tight coupling, broken abstractions)

Skip: style preferences, naming opinions, documentation gaps.

[Insert contents of `.agents/skills/second-opinion/schemas/review-finding-prompt.md` here, replacing `external-TARGET` with `external-[TARGET]`]
</prompt_template>

## 2. Run Script

Run it **in the background**, never as a foreground shell call: the default timeout (`SECOND_OPINION_TIMEOUT`, 1080s) exceeds the ~600s ceiling a harness puts on a foreground call, which would kill the shell before the script's own timeout fires — no artifact, and the external CLI left running. On Claude Code use `run_in_background`; on Pi run it under `bg_task`; on Codex and OpenCode use scheduled re-entry, or pass `--timeout` at or below the foreground ceiling.

```bash
.agents/skills/second-opinion/scripts/second-opinion audit \
  --prompt tmp/second-opinion-prompt.md \
  --cwd [PROJECT_PATH] \
  --output tmp/audit-external-YYYYMMDD-HHMMSS.json
```

## 3. Present Results

<output_format>

### External Audit — [TARGET]

| Verdict | Agent | Summary |
|---------|-------|---------|
| ✅ pass / ⚠️ action_required | external-[TARGET] | [SUMMARY] |

**Blockers**

| # | Location | Description | Pri |
|---|----------|-------------|-----|
| [id] | [location] | [description] | 🔴 |

**Suggestions**

| # | Location | Description | Cat | Pri |
|---|----------|-------------|-----|-----|
| [id] | [location] | [description] | fix/issue | 🟡 |

</output_format>

Omit empty sections.
