# Messages to a person

Read before writing any message to a person.

## Reader modes

Use the reader mode the caller supplies. The default prose is for a CEO with moderate technical knowledge.

| Mode | Prose |
|---|---|
| `ceo` | Say what the thing does and why it matters. Report the outcome and its cost. Name a tool, file, command or mechanism only when the person must act on it. Name a tool, script, session or folder the person must act on with its job in the same sentence. Expand unfamiliar jargon. Keep common terms such as AI, CPU and API. |
| `engineer` | Use the session's technical vocabulary for the same outcomes and costs. |

For CEO prose, retain technical source notes as evidence. Before drafting, extract what work is running or stopped, its effect on the person's goal, and the action taken or still needed.

When explaining a problem and its solution, derive these facts from the evidence before composing:

1. The problem and its effect on the person. Distinguish an observed failure from an unknown cause.
2. The proposed solution as a whole: who owns the job and how the parts together remove the problem.
3. The work actually completed and the work still needed, with its owner. Distinguish a proposal or implementation from verified use.
4. The final story for the person and the agent: what starts the job, what each does during work, why work may wait, who resolves the wait and what resumes work, what makes the result finished, and who closes the job. Explain each transition's cause and its effect on the person's goal, including what happens to unfinished work and needed results.

Mark an unread fact as unknown. Keep intended behavior distinct from observed behavior throughout the draft. Compose from the derived facts, not by shortening the source notes. Keep a necessary owner decision explicit.

Fictitious drafting example:

- Evidence: The only test job stopped after a disk-write failure; acceptance is unfinished; the build team owns storage repair; no retry has started; the failure's cause is unread. The proposed test service would own each requested test through closure, show storage waits, save progress, retry after the build team confirms repair, publish the result for acceptance, then release temporary storage while retaining the result. The build team has saved the failed result; storage repair and the proposed service changes remain unfinished.
- CEO draft: No tests are running, so you cannot yet accept the change. The disk-write failure's cause is unknown. The build team saved the failed result, but storage repair and the proposed test service changes are unfinished. No retry has started. The proposed service would carry each test from your request through acceptance and cleanup. You would request a test, and the service would start and run it. If storage failed, the service would save progress and show that work is waiting for the build team. The build team's repair confirmation would let the service resume testing without losing that progress. The service would publish the result so you could decide acceptance. Once acceptance finished, the service would close the job and release temporary storage, keeping the result for you.

## Plain language

- Write in ASD-STE100 Simplified Technical English.
- Start with the answer itself, stated as a fact. Give no summary, preamble, verdict or fact the reader did not ask about.
- Say what happened and what it means for the work. Name no generation, pane, token count, seat, mailbox id or internal rule unless the person must act on it.
- Stop after the last fact. Write no closing sentence.
- Put one idea in each short sentence. Use active voice.
- Delete a sentence that could sit in an answer about anything else. Keep the observed work, effect, cost and action the reader needs. Apply the reader mode before retaining a mechanism.
- Never say that a fact is worth noticing.
- Do the work, then report it. Never narrate what you are about to do.
- Use no long dash, including after a bold label. Use a colon.
- Use short bullets as the default.
- Never mention these writing rules or say what you will not do.
- Never rate, rank, praise or sell, even when asked. This includes superlative framing, even when it carries a fact. A heading names a topic, not a verdict.
- Name the real thing. Do not stack clauses or use insider shorthand. Replace abstract words such as signal, surface, shape, posture, residue, substrate and predicate with the real noun.
- Never use: delve, landscape, testament, interplay, serves as, robust, seamless, and leverage as a verb.
- The long-dash ban and banned-word list are defaults a consumer may override.
- Give full detail on request. Never trade correctness for brevity.

## Evidence and costs

- Use a number only when you saw it in this session's output. Otherwise name the thing without the number. Never estimate or run an extra command only to fill that gap.
- Give every number its yardstick and verdict in the same bullet: the earlier value, target or normal range; good, bad or not known; and what is done about it. If the yardstick is unread, say so and name the reading that settles it.
- Give a measure that depends on load with that load: session length beside the work handled, or machine use beside what ran. Length or use alone never claims an improvement.
- Before posting, read each topic as the person and ask "so what for me?". Add that answer or cut the topic.
- State a cost as its figure and source. Compare added CI time against the plan's included monthly allowance.

## Impact and odds

When describing a mechanism, give its effect on the person and the likelihood of that effect.

## Message purpose

- Omit acknowledgements, unneeded mechanisms and history that do not affect the person's action.
- A critical notice states the failure, its effect and the action the person must take.
- When introducing a rule or setting, name the file or service that will hold it.
- For a work update, use the [work story](reports.md#work-story). A simple reply needs no fixed status labels.
- Name planned work by its tracker item, or state that it was dropped and why. Never call work "for now", "deferred", "later" or "optional".
- Attribute another agent's work to that agent by name. Use I only for work the speaking session did.
- When a message says a fix is coming, say in the same sentence whether it existed before the person's message, with its item and filing date, or was filed because of that message.
- Review the saved text before sending. Message-format checks are advisory. A tool must not refuse a message because of its wording or layout.

## Medium and threads

- Use the medium where the person started the conversation. Chat and voice connectors are the person's choice. For voice delivery, follow [voice replies](voice.md#spoken-reply).
- Keep one topic per post and per thread. Reply in the thread of the message answered, or its containing thread. Continue that topic there until the person changes topic. Keep thread replies in their threads.
- Answer each message in its own thread. If a fact answers two messages, give a short answer in each thread.
- A new topic, decision request, critical notice or progress report starts at the top level.
- Read only the thread of the message answered. Read its history when needed, not unrelated channel history.
- Follow the person's reporting cadence and quiet hours. The person defines which critical notices can interrupt them.

## Times

Write times in the person's time zone with am or pm. Do not use a `Z` stamp.

## Names

- Name an installed kendex package by its name, never "the repository runs kendex".
- Give a tracker item its subject words beside its link.
- Use distinct names for different things. Replace a pronoun with the thing's name when it could refer to more than one thing.
- When a short reply could refer to different earlier items, name the item the reply acts on before acting.

## References and markup

- Link each pull request, commit, issue and tracker item with its short name. Use `[REPO#N](https://github.com/OWNER/REPO/pull/N)`, `[SHORT_SHA](https://github.com/OWNER/REPO/commit/SHORT_SHA)` or `[KEY-N](TRACKER_ISSUE_URL)` as the form. Never put a tracker id in a code span.
- For standard Markdown, put blank lines between paragraphs, around lists and before labels. Use numbered lists for steps or options and bullets for parallel facts.
- Use headings and bold labels or decisions for structure. Never use bold for emphasis or on a whole sentence. Use sentence case. Use italics seldom.
- Use inline code for a command or path. Use a code block for output longer than one line. Keep paragraphs to a few sentences.
- Put text the person must send in a code block. Name the recipient above it.
- Report changed rules, guidance or directives after their commit is pushed. Name each changed file once as `repo/folder/file.md`, linked to `https://github.com/OWNER/REPO/blob/COMMIT/path#heading` at that commit.
- Beside a file, including a Slack file comment, use Slack mrkdwn: `*Label*` for bold, `<URL|LABEL>` for a link and plain lines for a list. The other markup rules still hold.

## Slack messages

For ordinary messages with sections, put each header on a bold line. Start bullet labels in bold, never italic. Give every issue id visible square brackets, bold and its tracker link, including in notices, answers, asks and reports. Use inline code for code, commands and filenames. Progress reports keep the full code-block headers in the [summary template](reports.md#summary-template).

Standard Markdown:

```markdown
**Installed plugins**

- **Tailscale plugin:** The plugin is installed.
- **[\[KEN-123\]](https://linear.app/vanillagreen/issue/KEN-123)** records the change to `kendex.toml`.
```

File-comment mrkdwn:

```text
*Installed plugins*
- *Tailscale plugin:* The plugin is installed.
- *<https://linear.app/vanillagreen/issue/KEN-123|[KEN-123]>* records the change to `kendex.toml`.
```

Slack supports underline in structured `rich_text` text styles. The current post and relay routes send `markdown_text` or `mrkdwn` text, whose supported formats have no underline syntax. Use bold headers on this route; add no Unicode imitation. See Slack's [text element styles](https://docs.slack.dev/reference/block-kit/block-elements/text-element/), [Markdown block formats](https://docs.slack.dev/reference/block-kit/blocks/markdown-block/) and [mrkdwn styles](https://docs.slack.dev/messaging/formatting-message-text/#basic-visual-styles).

## Corrections

Own a mistake in one line, with its repair.

## Attachments

Attach a screenshot or image when it explains the point better than words. Send a picture for review as a direct file post in its topic's thread. Send a picture to a person as a file post, never as a repository, commit or file-host link, because the link does not open for a reader without access. Evidence-only pictures can stay on the tracker item with its link.
