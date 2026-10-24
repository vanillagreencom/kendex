# Questions

Read when requesting a decision or action. The caller decides whether to ask and which options it can offer.

## Decision requests

Ask one question per message. When a chat or relay may show only the ask's first sentence, name the person's decision and its subject in that sentence, for example 'Decision for you on ITEM, SUBJECT: ...'. Give the options and a recommendation when the caller’s ask form permits one. Use the [visible comparison](#today-and-after). Each option states its gain, its cost and the likelihood of that cost. Use the reader mode from [messages](messages.md#reader-modes).

## Today and After

For a decision, show Today and After side by side in the words of the screen or app the person uses. A goal statement alone never replaces that comparison. A work-item description carries today and after in its template-owned Story opening. A comment or completion summary opens with the changed result and consequence; do not repeat the description’s Story. Keep an explicit comparison when the decision needs it.

For a folder change, show the folders today and where each moves.

## CEO questions

```text
Decision for you on [ITEM], [SUBJECT]: [WHAT THIS CHANGES FOR THE USER, ONE SENTENCE]

**A. [OUTCOME OF THE FIRST PATH]**

[ONE OR TWO PLAIN SENTENCES SAYING WHAT THE USER GETS, WHAT IT COSTS THEM AND HOW LIKELY THAT COST IS]

**B. [OUTCOME OF THE SECOND PATH]**

[ONE OR TWO PLAIN SENTENCES SAYING WHAT THE USER GETS, WHAT IT COSTS THEM AND HOW LIKELY THAT COST IS]

**Recommended:** [A OR B], because [ONE SENTENCE IN OUTCOME TERMS].
```

When the caller’s envelope renders options, recommendation or deadline labels, keep those authoritative fields there and omit duplicate labels from authored prose. Explain the options and reason in the question text. An owner-reserved ask waits for approval and invents no default.

Use outcomes only. Name no mechanism the person does not act on and no option by its internal name.

## Engineer questions

```text
[QUESTION]: [OPTION_A] | [OPTION_B], with [RECOMMENDED_OPTION] recommended.
```

## Action requests

Give numbered steps in plain words, with one action per step. Say what evidence closes the request. State what the deadline does. Omit the recommendation when the caller's ask form records none.

## Opening question

When the caller offers `idle` and `tracker` for an empty work queue, use:

```text
What do you want to work on? Reply with issue ids or describe it, or answer tracker to take work from the tracker. With no answer by the deadline I wait for your reply.
```
