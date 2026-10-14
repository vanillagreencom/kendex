# Historical mailbox source

This fixture keeps the unchanged mailbox writer and helpers from [Kendex revision 13a1c5443186c9af8fed1f9712ea033b4d948962](https://github.com/vanillagreencom/kendex/tree/13a1c5443186c9af8fed1f9712ea033b4d948962/skills/mailbox/scripts).

The store matches the actual bound [Hyprtrade revision 88522b333a42d4837b9be1f73bbc27cdf7066f21](https://github.com/vanillagreencom/hyprtrade/blob/88522b333a42d4837b9be1f73bbc27cdf7066f21/.agents/skills/mailbox/scripts/lib/lane-mail-store.py) and [Hyprtrade-io revision 68d351e94def14276c3347d2e2e39b12d8e85df9](https://github.com/vanillagreencom/hyprtrade-io/blob/68d351e94def14276c3347d2e2e39b12d8e85df9/.agents/skills/mailbox/scripts/lib/lane-mail-store.py). The supplied Hyprtrade append and common-root helpers also match these fixture bytes. [KEN-4088's raw source attachment](https://uploads.linear.app/09589536-0763-447e-a0ed-6d9bf346d4cc/8faa4c03-ea7a-4415-a8f8-590f25e1e51c/a6dc1613-3ffc-41d2-bc14-b8d48aa6ce58) supplies those independent source strings and hashes.

The store has no `read_events` callable. Tests use its public writer, compactor, events and receipts commands as the older-format producer and output oracle. Production reads through the current installed mailbox dependency.

| File | Git blob |
|---|---|
| `scripts/lane-mail` | `72be27152fc9ab2744e35fb611409e9f2e8944a2` |
| `scripts/lib/lane-mail-store.py` | `861479ed277cc23651fde6aba5942b1d04f7f4f3` |
| `scripts/lib/mailbox-append.sh` | `a280f69f33009f43b0e0a3580b6500d550e33440` |
| `scripts/lib/common-root.sh` | `393143fa094e349daab9c4655877b2f7644006a4` |
| `scripts/lib/file-lock.sh` | `f08ee3d7075dd66117eed642f5fdb9614fea22f9` |
| `scripts/lib/kendex-env.sh` | `9095a8deeea9db77cca1715ea5dbb821712d7edf` |
