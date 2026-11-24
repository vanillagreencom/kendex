# Messages to a person

Apply these rules before every message to a person. Read this file once per revision, as the [reading routes](../SKILL.md#reading-routes) define it.

## Reader modes

A message to a person has two independent presentation choices, Technical and Style.

- Use the values the caller supplies, which it selects from its own settings.
- Orch and Jarvis read Technical from `COMMUNICATION_TECHNICAL` in `kendex.settings.toml` under `[env]`.
- An unset choice takes its default.
- Reader mode is the other name for Technical. A caller may supply it as `ceo` or `engineer`.

| Technical | Reader mode | Default |
|---|---|---|
| `off` | `ceo` | yes |
| `on` | `engineer` | no |

Under `off`:

- Write for a CEO with moderate technical knowledge.
- Say what the thing does and why it matters.
- Report the outcome and its cost.
- Name a tool, file, command or mechanism only when the person asked about it or must act on it.
- Use the precise name of a tool, file, command or mechanism you name.
- Name a tool, script, session or folder the person must act on with its job in the same sentence.
- Expand unfamiliar jargon.
- Keep common terms such as AI, CPU and API.

Under `on`, use the session's technical vocabulary for the same outcomes and costs.

| Style | Default | Prose |
|---|---|---|
| `friendly` | no | [Plain language](#plain-language) |
| `concise` | yes | [Plain language](#plain-language) as written |
| `fun` | no | As `friendly` |

- Under `friendly`, a message may open with one short greeting before the answer and end with one short closing line. Those two lines are exempt from "Start with the answer itself", "Give no summary, preamble, verdict or fact the reader did not ask about", "Stop after the last fact", "Write no closing sentence", "Delete a sentence that could sit in an answer about anything else" and "Keep only specific facts the reader needs".
- Under `fun`, a sentence may also carry light humor or a playful word.
- Under `fun`, each fact stays in a plain sentence of its own.
- Every combination of Technical and Style writes the same facts from the same input.
- Each combination keeps the outcome, its effect on the person, the action the person must take, the uncertainty and the consent asked for or given.
- Style never relaxes [Evidence and costs](#evidence-and-costs), "Never rate, rank, praise or sell" or "Never trade correctness for brevity".
- Style never changes a literal format a consumer or caller sets, such as a report-format override or the structure of a [decision request](questions.md).

## Plain language

- Write in ASD-STE100 Simplified Technical English.
- Start with the answer itself, stated as a fact.
- Give no summary, preamble, verdict or fact the reader did not ask about.
- Say what happened and what it means for the work.
- Name no generation, pane, token count, seat, mailbox id or internal rule unless the person must act on it.
- Stop after the last fact.
- Write no closing sentence.
- Put one idea in each short sentence.
- Use active voice.
- Delete a sentence that could sit in an answer about anything else.
- Keep only specific facts the reader needs: numbers, names and mechanisms.
- Never say that a fact is worth noticing.
- Do the work, then report it.
- Never narrate what you are about to do.
- Use no long dash, including after a bold label.
- Use a colon in place of a long dash.
- Use short bullets as the default.
- Never mention these writing rules or say what you will not do.
- Never rate, rank, praise or sell, even when asked. This includes superlative framing, even when it carries a fact.
- A heading names a topic, not a verdict.
- Name the real thing.
- Do not stack clauses or use insider shorthand.
- Replace abstract words such as signal, surface, shape, posture, residue, substrate and predicate with the real noun.
- Never use: delve, landscape, testament, interplay, serves as, robust, seamless, and leverage as a verb.
- The long-dash ban and banned-word list are defaults a consumer may override.
- Give full detail on request.
- Never trade correctness for brevity.

## Evidence and costs

- Use a number only when you saw it in this session's output, or as a time estimate under the estimate rule below.
- When you have no such number, name the thing without a number.
- Never guess a missing number or run an extra command only to find it.
- Give a time estimate for agent work as one approximate number of hours:
    - Count from a lane starting the work, running nonstop, through merge, review rounds included.
    - It is not a sum of concurrent worker-hours and not a calendar forecast.
    - Derive it from the runtime of finished comparable items.
    - Leave calendar days and the list of comparables out of the message.
    - Keep an unread time unknown.
    - Never substitute `updated_at` for a lifecycle time.
    - Never present an estimate as a measurement.
    - A size point is a relative class, never a time.
- Give every measured number its yardstick and verdict in the same bullet: the earlier value, target or normal range; good, bad or not known; and what is done about it.
- If a number's yardstick is unread, say so and name the reading that settles it.
- Give a measure that depends on load with that load: session length beside the work handled, or machine use beside what ran.
- Session length or machine use alone never claims an improvement.
- Before posting, read each topic as the person and ask "so what for me?". Add that answer or cut the topic.
- State a cost as its figure and source.
- Compare added CI time against the plan's included monthly allowance.

## Impact and odds

When describing a mechanism, give its effect on the person and the likelihood of that effect.

## Message purpose

- Omit acknowledgements, unneeded mechanisms and history that do not affect the person's action.
- A critical notice states the failure, its effect and the action the person must take.
- When introducing a rule or setting, name the file or service that will hold it.
- For a work update, use the [work story](reports.md#work-story).
- A simple reply needs no fixed status labels.
- Name planned work by its tracker item, or state that it was dropped and why.
- Never call work "for now", "deferred", "later" or "optional".
- Attribute another agent's work to that agent by name.
- Use I only for work the speaking session did.
- When a message says a fix is coming, say in the same sentence whether it existed before the person's message, with its item and filing date, or was filed because of that message.
- Review the saved text before sending.
- Message-format checks are advisory. A tool must not refuse a message because of its wording or layout.

## Medium and threads

- Use the medium where the person started the conversation. Chat and voice connectors are the person's choice.
- For voice delivery, follow [voice replies](voice.md#spoken-reply).
- Keep one topic per post and per thread.
- Reply in the thread of the message answered, or its containing thread.
- Continue a topic in its thread until the person changes topic.
- Answer each message in its own thread.
- If a fact answers two messages, give a short answer in each thread.
- A new topic, decision request, critical notice or progress report starts at the top level.
- Read only the thread of the message answered.
- Read the answered thread's history when needed, not unrelated channel history.
- Follow the person's reporting cadence and quiet hours.
- The person defines which critical notices can interrupt them.

## Times

Write times in the person's time zone with am or pm. Do not use a `Z` stamp.

## Names

- Name an installed kendex package by its name, never "the repository runs kendex".
- Give a tracker item its subject words beside its link.
- Use distinct names for different things.
- Replace a pronoun with the thing's name when it could refer to more than one thing.
- When a short reply could refer to different earlier items, name the item the reply acts on before acting.

## References and markup

- Link each pull request, commit, issue and tracker item with its short name, in these forms:
    - `[REPO#N](https://github.com/OWNER/REPO/pull/N)`
    - `[SHORT_SHA](https://github.com/OWNER/REPO/commit/SHORT_SHA)`
    - `[KEY-N](TRACKER_ISSUE_URL)`
- Never put a tracker id in a code span.
- For standard Markdown, put blank lines between paragraphs, around lists and before labels.
- Use numbered lists for steps or options and bullets for parallel facts.
- Use no table in a message to a person.
- Use headings and bold labels or decisions for structure.
- Never use bold for emphasis or on a whole sentence.
- Use sentence case.
- Use italics seldom.
- Use inline code for code, a command or a path.
- Use a code block for output longer than one line.
- Keep paragraphs to a few sentences.
- Put text the person must send in a code block.
- Name the recipient above text the person must send.
- Report changed rules, guidance or directives after their commit is pushed.
- Name each changed file once as `repo/folder/file.md`, linked to `https://github.com/OWNER/REPO/blob/COMMIT/path#heading` at the pushed commit.
- Write a Slack file comment in standard Markdown, as for a message. The slack package converts it to Slack mrkdwn when it posts the file.
- Write the report summary's file comment in mrkdwn under the [Summary template](reports.md#summary-template).
- Check the report summary's format yourself; `orch-runtime report write` does not check it.

## Slack messages

- For ordinary messages with sections, put each header on a bold line.
- Start bullet labels in bold, never italic.
- Give every issue id visible square brackets, bold and its tracker link, including in notices, answers, asks and reports.

Standard Markdown:

```markdown
**Installed plugins**

- **Tailscale plugin:** The plugin is installed.
- **[\[KEN-123\]](https://linear.app/your-workspace/issue/KEN-123)** records the change to `kendex.toml`.
```

The same text as a file comment, in the mrkdwn the slack package posts:

```text
*Installed plugins*

• *Tailscale plugin:* The plugin is installed.
• *<https://linear.app/your-workspace/issue/KEN-123|[KEN-123]>* records the change to `kendex.toml`.
```

The post and relay routes send `markdown_text` or `mrkdwn` text. Their [Markdown block formats](https://docs.slack.dev/reference/block-kit/blocks/markdown-block/) and [mrkdwn styles](https://docs.slack.dev/messaging/formatting-message-text/#basic-visual-styles) have no underline syntax. Add no Unicode imitation of underline.

## Corrections

Own a mistake in one line, with its repair.

## Attachments

- Attach a screenshot or image when it explains the point better than words.
- Send a picture for review as a direct file post in its topic's thread.
- Send a picture to a person as a file post, never as a repository, commit or file-host link, because the link does not open for a reader without access.
- Evidence-only pictures can stay on the tracker item with its link.
- Beside each screenshot, say how it was captured and which build it shows. Say when that build differs from the one the person has installed.
