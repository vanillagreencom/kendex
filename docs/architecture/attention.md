# A person is asked only for what kendex cannot finish alone

Read before adding an event, a notice, a badge, a toast or a dialog to the desktop app.

## The approach

Every event the app shows a person is one of five classes, and the class fixes its name, where it appears, its tone, whether the person may dismiss it, and whether it carries read state. A persistent item the person cannot dismiss is one the person must act on before kendex can finish its job: a Problem, or a Decision only they can make. Every other item is a Notice that clears once seen or dismissed, an Update, or the Result of an action they just took. Healthy is the state with no Problem and no Decision.

## Why

A footer that counts every event in red teaches a person to ignore it. Separating what blocks kendex from what merely informs is what makes the Problems page worth opening. One derivation of every row keeps Home, the footer and the Problems page from each counting the stores differently.

## Rules

- Do classify every item in one place, `attentionRows` in `ui/src/components/home/attention-rows.ts`, and gather its reads in `useAttentionRows`; Home, the status footer and the Problems page call it, and none filters or counts a store on its own.
- Do take every tone from `CLASS_TONES` there, never a tone literal; the token values live in `ui/src/index.css`.
- Do give a Problem and a Decision no dismiss control and no read state; they stand until the next read no longer finds them or the person decides.
- Do give a Notice and an Update a dismiss control, with read state keyed by slot and identity in `ui/src/stores/read-notices.ts`, so a changed set is unread again.
- Do draw Home's rows in class order: Problems, Decisions, Updates, Notices.
- Never make a Result a row: a toast or the error dialog carries it and nothing keeps it.
- Never count a blocked place more than once in the footer, however many declarations it holds.

## The canonical example

`ui/src/components/home/attention-rows.ts`: one row per item with its class, `CLASS_TONES` as the only tone source, and `attention-rows.test.ts` beside it holding each producer to its class. A new event adds a producer there and nowhere else.

## Revisit when

An event appears that blocks kendex and that the person can still reasonably dismiss, so the two persistent classes no longer cover it, or a surface outside Home needs its own count of one class.

## Not governed

The wording of an item and the control that lifts it: the producer that adds the row. The tokens behind each tone: `ui/AGENTS.md`.
