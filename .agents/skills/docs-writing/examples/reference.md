# The pair record

Read when the screenshot review workflow checks a comparison record before attachment. `shots compare` writes each pair under `tmp/shots/<screen>-<size>.json`; `shots attach` reads it.

| Field | Shape | Meaning |
|---|---|---|
| `screen` | string | The screen name from `sizes.conf`. |
| `size` | `WxH` | The capture size. |
| `before`, `after` | path | The two PNGs, relative to `tmp/shots/`. |
| `diff_pct` | number, 0 to 100 | Pixels that differ, as a share of the frame. |
| `attached` | boolean | Set by `shots attach` once the pair is on the pull request. |

A record with no `diff_pct` is one `compare` could not finish; `attach` skips it and names the screen.

If `before` is missing and the screen exists on the base branch, capture that base screen and compare again. If the screen is new, mark the pair as a new screen and request approval for the after image alone. Never substitute an empty image for a failed capture.

## Event and approval packet

Read when `workflows/review-pass.md` handles `pair-ready` or prepares the attachment approval. `pair-ready` means comparison finished; it does not grant permission to attach. The workflow owns capture, comparison, approval and attachment in that order.

| Approval field | Meaning |
|---|---|
| `pair` | The comparison record path. |
| `head` | The pull request revision the images show. |
| `action` | Attach both images, or the after image alone for a new screen. |
| `approval` | The owner's answer for that revision and action. |

The packet is the approval contract, not a sequence of steps. If its revision differs from the current pull request, return to the workflow's comparison step before requesting approval again.

---

## Not this

> `diff_pct` was added in 1.2 after the LUM-880 regression, where a one-pixel shift in the footer was attached to forty pull requests; before that the record held only the two paths, and `attach` posted every pair.

History and an issue number answer no lookup; the reader wanted the field's shape and meaning.

> On Tuesday the base capture failed, so we copied an empty PNG, retried and attached it. After review, we agreed that an existing screen needs another base capture and a new screen needs approval for its after image alone.

Delete the incident account. Keep its current conditions and remedies in the reference above. The missing base, existing-screen branch, new-screen branch and approval action remain explicit. A retry that happened once is not a general instruction.

> On `pair-ready`, capture the base, compare, ask the owner and then attach. The approval packet is whatever the attachment script used last time.

Move the ordered job to `workflows/review-pass.md` after inspecting it. Keep the event meaning and packet fields here. The skill entry gives the workflow's reading trigger; the workflow gives this reference's lookup trigger.
