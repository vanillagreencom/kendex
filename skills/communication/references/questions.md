# Questions

Read when requesting a decision or action. The caller decides whether to ask and which options it can offer.

## Decision requests

Ask one question per message. Give the options and a recommendation. Use the [visible comparison](#today-and-after). Each option states its gain, its cost and the likelihood of that cost. Use the reader mode from [messages](messages.md#reader-modes).

## Today and After

Show Today and After side by side in the words of the screen or app the person uses. Put this comparison first in work-item descriptions, comments and completion summaries.

## CEO questions

```text
[WHAT THIS CHANGES FOR THE USER, ONE SENTENCE]

**A. [OUTCOME OF THE FIRST PATH]**

[ONE OR TWO PLAIN SENTENCES SAYING WHAT THE USER GETS, WHAT IT COSTS THEM AND HOW LIKELY THAT COST IS]

**B. [OUTCOME OF THE SECOND PATH]**

[ONE OR TWO PLAIN SENTENCES SAYING WHAT THE USER GETS, WHAT IT COSTS THEM AND HOW LIKELY THAT COST IS]

**Recommended:** [A OR B], because [ONE SENTENCE IN OUTCOME TERMS].
```

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
