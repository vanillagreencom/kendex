# KEN-2416 refresh runs: talk

talk has 32 failed runs out of 143 listed runs in the fixed interval.

## Scope and counts

- [Measurement index](ken-2416-refresh-runs.md) owns the interval, inventory, denominators and code definitions.
- Repository: `vanillagreencom/talk`.
- Created-at interval, inclusive UTC: `2026-09-24T14:14:50Z` through `2026-10-01T14:14:50Z`.
- Retained created-at bounds: `2026-09-30T09:08:04Z` through `2026-10-01T14:13:23Z`.
- Listing: `tmp/ken-2416-control-evidence.tgz!ken-2416-evidence/talk/runs.json`.
- Counts: listed 143; completed 143; failure 32; success 111; cancelled 0; pending 0.
- Listed failure rate: 22.38%. Completed failure rate: 22.38%.

## Failure classes

| Cause class | Count |
| --- | ---: |
| `publication-class` | 25 |
| `publication-lease` | 1 |
| `publication-queue` | 1 |
| `remote-read` | 1 |
| `retired-agent-declaration` | 4 |

## Raw rows

Created cells are full UTC timestamps. Each URL preserves the run ID. Event, outcome, cause and evidence codes use the index definitions. Each row preserves the original observed outcome.

- Evidence F: `tmp/ken-2416-control-evidence.tgz!ken-2416-evidence/talk/log-failed-RUN_ID.txt`; stderr companion `log-failed-RUN_ID.err`.
- Evidence X: cancellation with no failed-step bytes at that same archive member. Its cause remains unclassified.
- Evidence L: the listing above.
- Archive members supply no attempt or head SHA fields. No report invents them.

| Created UTC | Run URL | Event | Outcome | Cause | Evidence |
| --- | --- | --- | --- | --- | --- |
| 2026-09-30T09:08:04Z | [run](https://github.com/vanillagreencom/talk/actions/runs/36694135100) | C | F | N | F |
| 2026-09-30T09:40:15Z | [run](https://github.com/vanillagreencom/talk/actions/runs/36697581944) | C | F | P | F |
| 2026-09-30T09:55:23Z | [run](https://github.com/vanillagreencom/talk/actions/runs/36699189886) | D | F | P | F |
| 2026-09-30T10:07:43Z | [run](https://github.com/vanillagreencom/talk/actions/runs/36700494082) | C | F | P | F |
| 2026-09-30T10:09:57Z | [run](https://github.com/vanillagreencom/talk/actions/runs/36700724062) | D | F | P | F |
| 2026-09-30T10:38:46Z | [run](https://github.com/vanillagreencom/talk/actions/runs/36703673796) | C | F | P | F |
| 2026-09-30T10:41:06Z | [run](https://github.com/vanillagreencom/talk/actions/runs/36703907105) | D | F | P | F |
| 2026-09-30T11:06:47Z | [run](https://github.com/vanillagreencom/talk/actions/runs/36706515381) | C | F | P | F |
| 2026-09-30T11:09:45Z | [run](https://github.com/vanillagreencom/talk/actions/runs/36706820378) | D | F | P | F |
| 2026-09-30T11:34:26Z | [run](https://github.com/vanillagreencom/talk/actions/runs/36709370547) | D | F | P | F |
| 2026-09-30T11:36:15Z | [run](https://github.com/vanillagreencom/talk/actions/runs/36709557263) | C | F | P | F |
| 2026-09-30T12:01:11Z | [run](https://github.com/vanillagreencom/talk/actions/runs/36712113643) | D | F | P | F |
| 2026-09-30T12:12:04Z | [run](https://github.com/vanillagreencom/talk/actions/runs/36713263781) | C | F | P | F |
| 2026-09-30T12:32:14Z | [run](https://github.com/vanillagreencom/talk/actions/runs/36715371254) | D | F | P | F |
| 2026-09-30T12:32:32Z | [run](https://github.com/vanillagreencom/talk/actions/runs/36715404840) | D | F | P | F |
| 2026-09-30T12:40:36Z | [run](https://github.com/vanillagreencom/talk/actions/runs/36716297703) | D | F | P | F |
| 2026-09-30T12:52:37Z | [run](https://github.com/vanillagreencom/talk/actions/runs/36717647382) | C | F | P | F |
| 2026-09-30T13:11:42Z | [run](https://github.com/vanillagreencom/talk/actions/runs/36719880887) | C | F | P | F |
| 2026-09-30T13:18:24Z | [run](https://github.com/vanillagreencom/talk/actions/runs/36720679598) | D | F | P | F |
| 2026-09-30T13:38:22Z | [run](https://github.com/vanillagreencom/talk/actions/runs/36723095775) | C | F | P | F |
| 2026-09-30T13:42:46Z | [run](https://github.com/vanillagreencom/talk/actions/runs/36723642095) | D | F | P | F |
| 2026-09-30T14:02:30Z | [run](https://github.com/vanillagreencom/talk/actions/runs/36726094910) | D | F | P | F |
| 2026-09-30T14:08:28Z | [run](https://github.com/vanillagreencom/talk/actions/runs/36726843125) | C | F | P | F |
| 2026-09-30T14:37:11Z | [run](https://github.com/vanillagreencom/talk/actions/runs/36730479473) | D | F | P | F |
| 2026-09-30T14:40:13Z | [run](https://github.com/vanillagreencom/talk/actions/runs/36730860797) | C | F | P | F |
| 2026-09-30T14:41:51Z | [run](https://github.com/vanillagreencom/talk/actions/runs/36731063703) | D | F | P | F |
| 2026-09-30T14:57:11Z | [run](https://github.com/vanillagreencom/talk/actions/runs/36733009412) | M | O | O | L |
| 2026-09-30T15:08:51Z | [run](https://github.com/vanillagreencom/talk/actions/runs/36734494181) | C | O | O | L |
| 2026-09-30T15:09:58Z | [run](https://github.com/vanillagreencom/talk/actions/runs/36734632046) | D | O | O | L |
| 2026-09-30T15:17:34Z | [run](https://github.com/vanillagreencom/talk/actions/runs/36735604066) | D | O | O | L |
| 2026-09-30T15:28:59Z | [run](https://github.com/vanillagreencom/talk/actions/runs/36737066049) | D | O | O | L |
| 2026-09-30T15:34:55Z | [run](https://github.com/vanillagreencom/talk/actions/runs/36737825363) | D | O | O | L |
| 2026-09-30T15:39:28Z | [run](https://github.com/vanillagreencom/talk/actions/runs/36738404749) | C | O | O | L |
| 2026-09-30T15:53:29Z | [run](https://github.com/vanillagreencom/talk/actions/runs/36740152000) | D | O | O | L |
| 2026-09-30T16:08:47Z | [run](https://github.com/vanillagreencom/talk/actions/runs/36742055246) | C | O | O | L |
| 2026-09-30T16:13:18Z | [run](https://github.com/vanillagreencom/talk/actions/runs/36742605817) | D | O | O | L |
| 2026-09-30T16:21:34Z | [run](https://github.com/vanillagreencom/talk/actions/runs/36743608166) | D | O | O | L |
| 2026-09-30T16:39:05Z | [run](https://github.com/vanillagreencom/talk/actions/runs/36745751521) | C | O | O | L |
| 2026-09-30T16:40:32Z | [run](https://github.com/vanillagreencom/talk/actions/runs/36745929668) | D | O | O | L |
| 2026-09-30T17:06:05Z | [run](https://github.com/vanillagreencom/talk/actions/runs/36748983325) | D | O | O | L |
| 2026-09-30T17:06:48Z | [run](https://github.com/vanillagreencom/talk/actions/runs/36749070032) | C | O | O | L |
| 2026-09-30T17:25:28Z | [run](https://github.com/vanillagreencom/talk/actions/runs/36751269302) | D | O | O | L |
| 2026-09-30T17:29:14Z | [run](https://github.com/vanillagreencom/talk/actions/runs/36751716916) | D | O | O | L |
| 2026-09-30T17:36:52Z | [run](https://github.com/vanillagreencom/talk/actions/runs/36752645875) | C | O | O | L |
| 2026-09-30T17:39:55Z | [run](https://github.com/vanillagreencom/talk/actions/runs/36753006996) | D | O | O | L |
| 2026-09-30T17:44:57Z | [run](https://github.com/vanillagreencom/talk/actions/runs/36753613111) | D | O | O | L |
| 2026-09-30T18:02:00Z | [run](https://github.com/vanillagreencom/talk/actions/runs/36755653360) | D | O | O | L |
| 2026-09-30T18:09:30Z | [run](https://github.com/vanillagreencom/talk/actions/runs/36756560070) | C | O | O | L |
| 2026-09-30T18:12:21Z | [run](https://github.com/vanillagreencom/talk/actions/runs/36756893746) | D | O | O | L |
| 2026-09-30T18:15:45Z | [run](https://github.com/vanillagreencom/talk/actions/runs/36757310239) | D | O | O | L |
| 2026-09-30T18:17:28Z | [run](https://github.com/vanillagreencom/talk/actions/runs/36757514938) | D | O | O | L |
| 2026-09-30T18:20:04Z | [run](https://github.com/vanillagreencom/talk/actions/runs/36757824304) | D | O | O | L |
| 2026-09-30T18:32:17Z | [run](https://github.com/vanillagreencom/talk/actions/runs/36759285839) | D | O | O | L |
| 2026-09-30T18:41:38Z | [run](https://github.com/vanillagreencom/talk/actions/runs/36760401361) | D | O | O | L |
| 2026-09-30T18:42:05Z | [run](https://github.com/vanillagreencom/talk/actions/runs/36760452397) | C | O | O | L |
| 2026-09-30T19:06:45Z | [run](https://github.com/vanillagreencom/talk/actions/runs/36763368910) | C | O | O | L |
| 2026-09-30T19:08:48Z | [run](https://github.com/vanillagreencom/talk/actions/runs/36763609786) | D | O | O | L |
| 2026-09-30T19:35:03Z | [run](https://github.com/vanillagreencom/talk/actions/runs/36766683091) | C | O | O | L |
| 2026-09-30T20:08:56Z | [run](https://github.com/vanillagreencom/talk/actions/runs/36770580464) | C | O | O | L |
| 2026-09-30T20:28:19Z | [run](https://github.com/vanillagreencom/talk/actions/runs/36772853874) | D | O | O | L |
| 2026-09-30T20:31:01Z | [run](https://github.com/vanillagreencom/talk/actions/runs/36773176793) | D | O | O | L |
| 2026-09-30T20:36:59Z | [run](https://github.com/vanillagreencom/talk/actions/runs/36773868909) | C | O | O | L |
| 2026-09-30T20:39:22Z | [run](https://github.com/vanillagreencom/talk/actions/runs/36774142223) | D | O | O | L |
| 2026-09-30T20:56:08Z | [run](https://github.com/vanillagreencom/talk/actions/runs/36776073610) | D | O | O | L |
| 2026-09-30T21:03:38Z | [run](https://github.com/vanillagreencom/talk/actions/runs/36776919565) | D | O | O | L |
| 2026-09-30T21:07:04Z | [run](https://github.com/vanillagreencom/talk/actions/runs/36777311663) | C | O | O | L |
| 2026-09-30T21:11:03Z | [run](https://github.com/vanillagreencom/talk/actions/runs/36777752428) | D | O | O | L |
| 2026-09-30T21:36:06Z | [run](https://github.com/vanillagreencom/talk/actions/runs/36780476681) | D | O | O | L |
| 2026-09-30T21:37:47Z | [run](https://github.com/vanillagreencom/talk/actions/runs/36780648832) | C | O | O | L |
| 2026-09-30T21:48:59Z | [run](https://github.com/vanillagreencom/talk/actions/runs/36781815274) | D | O | O | L |
| 2026-09-30T22:07:18Z | [run](https://github.com/vanillagreencom/talk/actions/runs/36783683770) | C | O | O | L |
| 2026-09-30T22:23:18Z | [run](https://github.com/vanillagreencom/talk/actions/runs/36785273856) | D | O | O | L |
| 2026-09-30T22:23:40Z | [run](https://github.com/vanillagreencom/talk/actions/runs/36785308076) | D | O | O | L |
| 2026-09-30T22:35:10Z | [run](https://github.com/vanillagreencom/talk/actions/runs/36786417599) | D | O | O | L |
| 2026-09-30T22:37:32Z | [run](https://github.com/vanillagreencom/talk/actions/runs/36786644307) | C | O | O | L |
| 2026-09-30T22:45:00Z | [run](https://github.com/vanillagreencom/talk/actions/runs/36787336563) | D | O | O | L |
| 2026-09-30T23:03:16Z | [run](https://github.com/vanillagreencom/talk/actions/runs/36789023776) | D | O | O | L |
| 2026-09-30T23:06:47Z | [run](https://github.com/vanillagreencom/talk/actions/runs/36789348888) | C | O | O | L |
| 2026-09-30T23:12:29Z | [run](https://github.com/vanillagreencom/talk/actions/runs/36789857402) | D | O | O | L |
| 2026-09-30T23:12:44Z | [run](https://github.com/vanillagreencom/talk/actions/runs/36789878617) | D | O | O | L |
| 2026-09-30T23:35:45Z | [run](https://github.com/vanillagreencom/talk/actions/runs/36791896657) | C | O | O | L |
| 2026-09-30T23:44:26Z | [run](https://github.com/vanillagreencom/talk/actions/runs/36792634820) | D | O | O | L |
| 2026-09-30T23:50:29Z | [run](https://github.com/vanillagreencom/talk/actions/runs/36793149498) | D | O | O | L |
| 2026-10-01T00:05:11Z | [run](https://github.com/vanillagreencom/talk/actions/runs/36794371831) | D | O | O | L |
| 2026-10-01T00:23:55Z | [run](https://github.com/vanillagreencom/talk/actions/runs/36795975982) | C | O | O | L |
| 2026-10-01T00:27:45Z | [run](https://github.com/vanillagreencom/talk/actions/runs/36796298678) | D | O | O | L |
| 2026-10-01T00:33:44Z | [run](https://github.com/vanillagreencom/talk/actions/runs/36796789815) | D | O | O | L |
| 2026-10-01T00:56:29Z | [run](https://github.com/vanillagreencom/talk/actions/runs/36798662417) | D | O | O | L |
| 2026-10-01T01:00:46Z | [run](https://github.com/vanillagreencom/talk/actions/runs/36799012761) | D | O | O | L |
| 2026-10-01T01:10:02Z | [run](https://github.com/vanillagreencom/talk/actions/runs/36799777431) | D | O | O | L |
| 2026-10-01T01:21:58Z | [run](https://github.com/vanillagreencom/talk/actions/runs/36800748266) | C | O | O | L |
| 2026-10-01T01:31:09Z | [run](https://github.com/vanillagreencom/talk/actions/runs/36801482978) | D | O | O | L |
| 2026-10-01T01:45:58Z | [run](https://github.com/vanillagreencom/talk/actions/runs/36802647706) | D | O | O | L |
| 2026-10-01T01:58:18Z | [run](https://github.com/vanillagreencom/talk/actions/runs/36803611273) | C | O | O | L |
| 2026-10-01T02:08:17Z | [run](https://github.com/vanillagreencom/talk/actions/runs/36804397849) | D | O | O | L |
| 2026-10-01T02:27:54Z | [run](https://github.com/vanillagreencom/talk/actions/runs/36805957124) | D | O | O | L |
| 2026-10-01T02:37:53Z | [run](https://github.com/vanillagreencom/talk/actions/runs/36806740190) | C | O | O | L |
| 2026-10-01T02:39:37Z | [run](https://github.com/vanillagreencom/talk/actions/runs/36806868688) | D | O | O | L |
| 2026-10-01T03:02:52Z | [run](https://github.com/vanillagreencom/talk/actions/runs/36808684105) | D | O | O | L |
| 2026-10-01T03:05:59Z | [run](https://github.com/vanillagreencom/talk/actions/runs/36808921844) | D | F | L | F |
| 2026-10-01T03:11:21Z | [run](https://github.com/vanillagreencom/talk/actions/runs/36809344721) | D | O | O | L |
| 2026-10-01T03:13:15Z | [run](https://github.com/vanillagreencom/talk/actions/runs/36809496179) | C | O | O | L |
| 2026-10-01T03:33:08Z | [run](https://github.com/vanillagreencom/talk/actions/runs/36811031302) | D | O | O | L |
| 2026-10-01T03:46:08Z | [run](https://github.com/vanillagreencom/talk/actions/runs/36812026142) | C | O | O | L |
| 2026-10-01T03:52:18Z | [run](https://github.com/vanillagreencom/talk/actions/runs/36812488301) | D | O | O | L |
| 2026-10-01T04:09:15Z | [run](https://github.com/vanillagreencom/talk/actions/runs/36813780305) | C | O | O | L |
| 2026-10-01T04:11:35Z | [run](https://github.com/vanillagreencom/talk/actions/runs/36813959443) | D | O | O | L |
| 2026-10-01T04:14:24Z | [run](https://github.com/vanillagreencom/talk/actions/runs/36814171736) | D | F | J | F |
| 2026-10-01T04:41:30Z | [run](https://github.com/vanillagreencom/talk/actions/runs/36816288420) | C | O | O | L |
| 2026-10-01T05:07:31Z | [run](https://github.com/vanillagreencom/talk/actions/runs/36818292560) | C | O | O | L |
| 2026-10-01T05:38:26Z | [run](https://github.com/vanillagreencom/talk/actions/runs/36820739835) | C | O | O | L |
| 2026-10-01T05:47:46Z | [run](https://github.com/vanillagreencom/talk/actions/runs/36821502436) | D | O | O | L |
| 2026-10-01T06:05:02Z | [run](https://github.com/vanillagreencom/talk/actions/runs/36822922067) | D | O | O | L |
| 2026-10-01T06:13:19Z | [run](https://github.com/vanillagreencom/talk/actions/runs/36823626746) | C | O | O | L |
| 2026-10-01T06:55:05Z | [run](https://github.com/vanillagreencom/talk/actions/runs/36827358312) | C | O | O | L |
| 2026-10-01T07:01:20Z | [run](https://github.com/vanillagreencom/talk/actions/runs/36827950612) | D | F | A | F |
| 2026-10-01T07:15:48Z | [run](https://github.com/vanillagreencom/talk/actions/runs/36829315223) | C | F | A | F |
| 2026-10-01T07:44:57Z | [run](https://github.com/vanillagreencom/talk/actions/runs/36832128749) | C | F | A | F |
| 2026-10-01T07:54:00Z | [run](https://github.com/vanillagreencom/talk/actions/runs/36833029051) | D | F | A | F |
| 2026-10-01T08:10:35Z | [run](https://github.com/vanillagreencom/talk/actions/runs/36834692875) | C | O | O | L |
| 2026-10-01T08:45:47Z | [run](https://github.com/vanillagreencom/talk/actions/runs/36838354243) | C | O | O | L |
| 2026-10-01T09:09:25Z | [run](https://github.com/vanillagreencom/talk/actions/runs/36840883433) | C | O | O | L |
| 2026-10-01T09:40:23Z | [run](https://github.com/vanillagreencom/talk/actions/runs/36844236635) | C | O | O | L |
| 2026-10-01T10:07:53Z | [run](https://github.com/vanillagreencom/talk/actions/runs/36847175059) | C | O | O | L |
| 2026-10-01T10:36:11Z | [run](https://github.com/vanillagreencom/talk/actions/runs/36850159755) | D | O | O | L |
| 2026-10-01T10:38:06Z | [run](https://github.com/vanillagreencom/talk/actions/runs/36850355326) | C | O | O | L |
| 2026-10-01T11:06:49Z | [run](https://github.com/vanillagreencom/talk/actions/runs/36853317936) | C | O | O | L |
| 2026-10-01T11:12:17Z | [run](https://github.com/vanillagreencom/talk/actions/runs/36853892335) | D | O | O | L |
| 2026-10-01T11:37:17Z | [run](https://github.com/vanillagreencom/talk/actions/runs/36856509056) | C | O | O | L |
| 2026-10-01T12:07:49Z | [run](https://github.com/vanillagreencom/talk/actions/runs/36859730220) | D | O | O | L |
| 2026-10-01T12:11:51Z | [run](https://github.com/vanillagreencom/talk/actions/runs/36860160143) | C | O | O | L |
| 2026-10-01T12:27:35Z | [run](https://github.com/vanillagreencom/talk/actions/runs/36861884463) | D | O | O | L |
| 2026-10-01T12:38:02Z | [run](https://github.com/vanillagreencom/talk/actions/runs/36863061448) | D | O | O | L |
| 2026-10-01T12:49:17Z | [run](https://github.com/vanillagreencom/talk/actions/runs/36864340806) | C | O | O | L |
| 2026-10-01T13:10:25Z | [run](https://github.com/vanillagreencom/talk/actions/runs/36866750907) | C | O | O | L |
| 2026-10-01T13:37:04Z | [run](https://github.com/vanillagreencom/talk/actions/runs/36869998259) | D | O | O | L |
| 2026-10-01T13:39:52Z | [run](https://github.com/vanillagreencom/talk/actions/runs/36870344643) | C | O | O | L |
| 2026-10-01T13:40:56Z | [run](https://github.com/vanillagreencom/talk/actions/runs/36870477640) | D | O | O | L |
| 2026-10-01T13:46:35Z | [run](https://github.com/vanillagreencom/talk/actions/runs/36871195578) | D | O | O | L |
| 2026-10-01T13:55:49Z | [run](https://github.com/vanillagreencom/talk/actions/runs/36872369911) | D | O | O | L |
| 2026-10-01T14:07:21Z | [run](https://github.com/vanillagreencom/talk/actions/runs/36873862175) | D | O | O | L |
| 2026-10-01T14:08:19Z | [run](https://github.com/vanillagreencom/talk/actions/runs/36873985646) | C | O | O | L |
| 2026-10-01T14:13:23Z | [run](https://github.com/vanillagreencom/talk/actions/runs/36874643331) | D | O | O | L |
