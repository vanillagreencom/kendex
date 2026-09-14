# Attention

The design KEN-1463 builds. It sorts every event the desktop app shows a person into one of five classes, and fixes for each class its name, where it appears, its colour, whether a person may dismiss it, and whether it carries read state.

## The rule

A persistent item that a person cannot dismiss is one the person must act on before kendex can finish its job. Every other item is a notice: it clears once the person has seen or dismissed it.

## Classes

| Class | Meaning | Tone key | Where it appears | Dismissable | Read state |
|---|---|---|---|---|---|
| Problem | kendex cannot finish its job until the person fixes something | `critical` (red) | Problems page, footer marker, Home row | No | None. It stays until the next read no longer finds it |
| Decision | kendex waits on a choice only the person can make | `warning` (orange) | Problems page, footer marker, Home row | No | None. It stays until the person decides |
| Notice | Information. Nothing is wrong and nothing waits | `notice` (yellow) | Home row | Yes | Unread until dismissed. The dismissal survives a reload |
| Update | New versions to take | `info` (blue) | Home row, Updates sidebar badge, app release card | Yes | Unread until dismissed or the Updates page is opened. A changed set of updates is unread again |
| Result | The outcome of an action the person just took | `good` (green) when done, `critical` (red) when failed | Toast, error dialog | Closes on its own or when closed | None. Not kept |

Healthy is the state with no Problem and no Decision. The Problems page shows its empty state, and the footer shows no marker.

## Events emitted today

Each row is one event the app shows, its producer, how it appeared before this design, and its class.

| Event | Producer | Before this design | Class |
|---|---|---|---|
| A place's manifest or lock cannot be read (lock-corrupt, manifest-outdated, manifest-invalid, schema-too-new, other) | `ui/src/stores/problems.ts::deriveProblems`, from each audit view's `error` | Problems card, red. Counted in the footer | Problem |
| The machine scan failed | `deriveProblems`, from the scan store's `error` | Problems card, red. Counted in the footer. A note on Home: red when no scan ever landed, orange over kept figures | Problem |
| A project folder cannot be read | `ScanResult.missingProjects` | Home row, orange. Not counted in the footer, not on Problems | Problem |
| Installed files are gone | update rows with `filesMissing` | Home row, orange. Not counted in the footer, not on Problems | Problem |
| Another tool's file cannot be read, and the person can repair it | `ScanWarning` with `standing` `actionable` | Problems card, orange. Home row, orange. Counted in the footer | Problem |
| The audit could not finish | the audit store's `read.error` | Home row, orange. A note on Problems in place of the blocked-place cards | Problem |
| The update check failed | the updates store's `read.error` | Home row, orange. Sidebar badge orange, `?` when no rows were kept | Problem |
| Places with no update standing | the updates store's `unreadable` | Home row, orange, sending the person to Problems. Sidebar badge orange, with the places in its tooltip | Problem |
| Unmanaged files block a declared install | `ui/src/lib/audit-counts.ts::blockedPlaces` | Problems card per place, orange. The footer counted each declaration, not each place | Decision |
| An edited package holds its update | update rows with `blockedByLocalEdit` | Home row, orange. Not counted in the footer, not on Problems | Decision |
| An empty MCP container where kendex manages nothing | `ScanWarning` with any other `standing` | Problems page, under "Nothing to fix", blue card | Notice |
| Package updates are available | `ui/src/lib/update-groups.ts::availableUpdateCount` | Home row, blue. Sidebar badge in the neutral fill | Update |
| A new app release is available | `ui/src/stores/notice.ts` | Sidebar card, dismissable per version through the `muted-app-notice` setting | Update |
| A write failed | `useProblemsStore.showError`, and `toast.error` in the scan, audit, marketplace, deep-link, folder-picker and bookmark paths | Error dialog with a red title, or a toast | Result |
| A write succeeded or had nothing to do | `toast.success`, `toast.info` | Toast | Result |

The footer marker was red for every item it counted, while the Problems page drew most of those items orange.

### Not emitted today

A Copilot `disableAllHooks` setting that switches hooks off reaches the app as no event. The engine's `kendex-hooks-disabled` warning in `crates/core/src/engine/copilot.rs` lands in the plan's `ItemWarning` list, and no UI surface reads an audit view's `warnings`. The scan in `crates/core/src/scan/copilot.rs` marks each entry `enabled: false`, which the package page draws as a disabled installation. This design adds no class for it.

## One derivation

`ui/src/components/home/attention-rows.ts::attentionRows` classifies every Problem, Decision, Notice and Update item. Each item is one row with its class. An item with a dedicated Problems card also carries that card's data.

`ui/src/components/home/use-attention-rows.ts::useAttentionRows` gathers the reads the derivation needs. Home, the status footer and the Problems page call it, and none of them filters or counts the stores on its own.

The Updates sidebar badge is not an attention row. It reads the Updates page's count (`visibleUpdateCount`), the update check's failure, the places with no update standing and the `updates` read slot, and takes its tone from `CLASS_TONES`.

- `problemsPageRows` keeps the Problem and Decision rows. `footerMarker` counts them.
- A place with a manifest or lock Problem is left out of the row for places with no update standing. The audit and the update check both refuse that one file, so it counts once.
- Each Problems card takes its tone from `CLASS_TONES`: the place error and unreadable file cards the Problem tone, the blocked place card the Decision tone.
- Home draws every row, in class order: Problems, then Decisions, then Updates, then Notices.
- A Result is never a row. Toasts and the error dialog carry it.

## Surfaces

- **Status footer**: the marker counts one per item the Problems page shows, and a blocked place counts once however many declarations it holds. It is red when any Problem stands and orange when only Decisions do. Its words name both counts. It opens the Problems page.
- **Problems page**: only Problem and Decision items. A place read error, an unreadable file and a blocked place keep their cards. Every other item draws as the shared attention row with its action. The "Nothing to fix" section is gone.
- **Home, Needs attention**: every row. A Notice or Update row carries a dismiss control. A Problem or Decision row carries none. A later scan failure keeps the page note heading the kept figures, and its Problem row stands in the list as well.
- **Updates sidebar badge**: the count stays. The fill is the Update tone while the update notice is unread and the neutral fill once it is read. A failed check or a place with no standing wears the Problem tone.
- **App release card**: already a dismissable Update keyed by version. No change.
- **Error dialog**: the title reads the failed Result tone.
- **Toasts**: sonner draws them without a tone, so the Result tone does not reach them.

The row for places with no update standing sends the person to Updates, which lists the reason per place. On the Problems page a link to Problems would do nothing.

## Read state

`ui/src/stores/read-notices.ts` keeps a map from a notice slot to the identity it had when read, in `localStorage`. Every read and write is in a `try`/`catch`. A storage read that throws leaves every notice unread. A write that throws keeps the read state for the session only.

- A scan note's slot and identity are its path.
- The package update notice's slot is `updates`. Its identity is the sorted set of rows the Updates page lists as news, each with its latest version, so new news or a newer version is unread again.
- The Updates badge is unread while it counts news and that slot does not hold the current identity. Home's update row shows only while an update is available, and reads the same slot.
- Opening the Updates page marks the current update set read.
- A Problem or Decision has no slot, no dismiss control and no read state.

## Colour tokens

`CLASS_TONES` in `attention-rows.ts` maps each class to a tone key. `done` and `failed` are the Result class's two outcomes. Every surface reads its tone from that table, and the tone key resolves through `STATUS_TONES` in `ui/src/components/status-note.tsx` and `StatusDot`.

The `--notice` token is new: a yellow beside `--warning` in the light and dark palettes, mapped as `--color-notice`. KEN-1464 owns the token sweep and tunes its values.
