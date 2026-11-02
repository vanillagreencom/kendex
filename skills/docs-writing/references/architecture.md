# `docs/architecture/<name>.md`

Read when writing, editing or reviewing a doc under `docs/architecture/`.

Optional. Read by an agent about to do the work the doc governs. A doc exists for one reader's task and the harmful mistake it prevents: name the work an agent does with the doc open, and what that agent breaks without it. A subsystem name alone is no reason for a file, and the rules one reader uses for one task are one doc, whatever folders they cross. No file count, size or line limit holds. It holds the approach, why, the rules as do and never lines that name the check enforcing a rule where one exists, the boundary an agent could break unknowingly, one canonical code example to copy, when to read it, the condition that reopens the approach, and what the principle does not govern. A value table, such as tokens, sizes or manifest keys, lives in code; the doc points to the file. No overview is required: the root `AGENTS.md` gives task triggers or routes to named nested instructions, and every retained doc has a trigger line at the root or in those nested instructions. Never: code walkthroughs, file or function inventories, test-row or fixture narration, run order, measurements, dates, upstream line numbers, task history.

The contrast, a journal paragraph against the principle it should be:

| Journal | Principle |
|---|---|
| `trash.rs::move_to_trash` is the one writer: the apply engine's `Trash` op, the project restore and a Pi package's replacement land through it, under a name that opens with the moment it was moved. Enforced by the tests `a_name_is_dated_by_the_stamp_it_opens_with` and `a_listing_reports_name_age_and_bytes_newest_first` in `trash/tests.rs`. | Removal never deletes. Every removed file goes to the trash through one writer, `trash::move_to_trash`, so a person can get it back; a second writer would be a removal nobody can undo. |

Three lines that read as rules and are not:

| Rule | Not a rule |
|---|---|
| A pointer to the enforcing check: "Never name a plugin id in the core; `scripts/check-plugin-boundary.py` refuses it." | Test-case narration: "Enforced by `test_attribution.py::two_speakers_one_microphone`, whose control removes the second speaker, and by `::no_transcript` for an empty recording." The reader learns which tests exist, not what the code must never do, and every test name goes stale at the next rename. |
| A contract: "One judge, `manifest.py::validate`, decides every manifest; a key it does not list refuses the manifest." | A field inventory: a table of every manifest key with its type, whether it is required and what it means. The judge's declaration owns the shape and defaults; the reference links to it and explains semantics. A hand-copied table is wrong the day a key changes. |
| A high-level rule: "A release is built once; every stage deploys that one artifact and never rebuilds." | A call sequence: "`make release` runs `scripts/bundle.sh`, which writes `dist/app.tar`; `deploy staging` uploads it, restarts the service and runs `smoke.sh`; `deploy prod` repeats the steps." The reader is walked through the scripts and still does not know what a change to them must preserve. |

Examples: [examples/architecture-plugins.md](../examples/architecture-plugins.md), [examples/architecture-design-system.md](../examples/architecture-design-system.md).
