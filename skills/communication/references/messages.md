# Messages to a person

Read before writing any message to a person.

## Reader modes

Use the reader mode the caller supplies. The default prose is for a CEO with moderate technical knowledge.

| Mode | Prose |
|---|---|
| `ceo` | Say what the thing does and why it matters. Report the outcome and its cost. Name a tool, file, command or mechanism only when the person must act on it. Expand unfamiliar jargon. Keep common terms such as AI, CPU and API. |
| `engineer` | Use the session's technical vocabulary for the same outcomes and costs. |

## Plain language

- Write in ASD-STE100 Simplified Technical English.
- Start with the answer itself, stated as a fact. Give no summary, preamble, verdict or unrelated opening fact.
- Say what happened and what it means for the work. Name no generation, pane, token count, seat, mailbox id or internal rule unless the person must act on it.
- Stop after the last fact. Write no closing sentence.
- Put one idea in each short sentence. Use active voice.
- Cut generic sentences. Keep specific facts the reader needs: numbers, names and mechanisms.
- Never say that a fact is worth noticing.
- Do the work, then report it. Never narrate what you are about to do.
- Use no long dash, including after a bold label. Use a colon.
- Use short bullets as the default.
- Never mention these writing rules or say what you will not do.
- Never rate, rank, praise or sell, even when asked. This includes superlative framing. A heading names a topic, not a verdict.
- Name the real thing. Do not stack clauses or use insider shorthand. Replace abstract words such as signal, surface, shape, posture, residue, substrate and predicate with the real noun.
- Avoid: delve, landscape, testament, interplay, serves as, robust, seamless, and leverage as a verb.
- Give full detail on request. Never trade correctness for brevity.

## Evidence and costs

- Use a number only when you saw it in this session's output. Otherwise name the thing without the number. Never estimate or run an extra command only to fill that gap.
- Give every number its yardstick and verdict in the same bullet: the earlier value, target or normal range; good, bad or not known; and what is done about it. If the yardstick is unread, say so and name the reading that settles it.
- Give a measure that depends on load with that load: session length beside the work handled, or machine use beside what ran. Length or use alone never claims an improvement.
- Before posting, read each topic as the person and ask "so what for me?". Add that answer or cut the topic.
- State a cost as its figure and source. Compare added CI time against the plan's 50,000 private-repository minutes each month.

The yardstick, load and so-what rules come from the owner's Slack messages 1792172820, 1792172887 and 1792172957, relayed in Jarvis note 1792173119.

## Impact and odds

When describing a mechanism, give its effect on the person and the likelihood of that effect.

## Message purpose

- Omit acknowledgements, unneeded mechanisms and history that do not affect the person's action.
- A critical notice states the failure, its effect and the action the person must take.
- When introducing a rule or setting, name the file or service that will hold it.

## Medium and threads

- Use the medium where the person started the conversation. Chat and voice connectors are the person's choice. Voice replies go to the call only.
- Keep one topic per post and per thread. Reply in the thread of the message answered, or its containing thread. Continue that topic there until the person changes topic. Keep thread replies in their threads.
- Answer each message in its own thread. If a fact answers two messages, give a short answer in each thread.
- A new topic, decision request, critical notice or progress report starts at the top level.
- Read only the thread of the message answered. Read its history when needed, not unrelated channel history.
- Follow the person's reporting cadence and quiet hours. The person defines which critical notices can interrupt them.

## Times

Write times in the person's time zone with am or pm. Do not use a `Z` stamp.

## References and markup

- Link each pull request, commit, issue and tracker item with its short name. Use `[REPO#N](https://github.com/OWNER/REPO/pull/N)`, `[SHORT_SHA](https://github.com/OWNER/REPO/commit/SHORT_SHA)` or `[KEY-N](TRACKER_ISSUE_URL)` as the form. Never put a tracker id in a code span.
- For standard Markdown, put blank lines between paragraphs, around lists and before labels. Use numbered lists for steps or options and bullets for parallel facts.
- Use headings and bold labels or decisions for structure. Never use bold for emphasis or on a whole sentence. Use sentence case. Use italics seldom.
- Use inline code for a command or path. Use a code block for output longer than one line. Keep paragraphs to a few sentences.
- Put text the person must send in a code block. Name the recipient above it.
- Beside a file, including a Slack file comment, use Slack mrkdwn: `*Label*` for bold, `<URL|LABEL>` for a link and plain lines for a list. The other markup rules still hold.

## Corrections

Own a mistake in one line, with its repair.

## Attachments

Attach a screenshot or image when it explains the point better than words.
