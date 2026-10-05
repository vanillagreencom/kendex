# The pair record

What `shots compare` writes for each pair under `tmp/shots/<screen>-<size>.json`, and what `shots attach` reads.

| Field | Shape | Meaning |
|---|---|---|
| `screen` | string | The screen name from `sizes.conf`. |
| `size` | `WxH` | The capture size. |
| `before`, `after` | path | The two PNGs, relative to `tmp/shots/`. |
| `diff_pct` | number, 0 to 100 | Pixels that differ, as a share of the frame. |
| `attached` | boolean | Set by `shots attach` once the pair is on the pull request. |

A record with no `diff_pct` is one `compare` could not finish; `attach` skips it and names the screen.

---

## Not this

> `diff_pct` was added in 1.2 after the LUM-880 regression, where a one-pixel shift in the footer was attached to forty pull requests; before that the record held only the two paths, and `attach` posted every pair.

History and an issue number answer no lookup; the reader wanted the field's shape and meaning.
