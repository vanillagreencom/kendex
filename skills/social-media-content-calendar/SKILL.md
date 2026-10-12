---
name: social-media-content-calendar
description: "Load to plan a social media campaign, build a content calendar, or adapt existing material into post drafts."
summary: "Plans campaign briefs, platform-specific drafts and asset handoffs for the publicist's recorded approval gate."
license: MIT
user-invocable: true
metadata:
  author: "Ben Barclay (benbarclay), Hermes Agent; kendex adaptation by vanillagreen"
  source: kendex
  repository: "https://github.com/vanillagreencom/kendex"
  bugs: "https://github.com/vanillagreencom/kendex/issues"
tags: [planning]
---

# Social media content calendar

Plan campaigns as plain files in the consumer's workspace. The calendar holds post drafts for the publicist's approval gate. This skill stops at draft handoff. It sends no post, upload, comment or message, and creates no scheduled job.

## Use

- Build a calendar for a launch, an event or a date range.
- Adapt articles, videos or product material into drafts for selected social platforms.
- Follow [Plan a campaign](workflows/plan-campaign.md) for campaign planning and draft handoff.
- Use the harness's native file and research tools. Keep the calendar, claim inventory, copy and asset briefs as Markdown or CSV files. Use the consumer's existing working-file location.
- Keep accounts, channel identifiers, brand voice and product facts in consumer files. Reference those files from the campaign brief.

## Draft states

| State | Meaning |
|---|---|
| `draft` | Copy or assets remain incomplete. |
| `needs review` | A complete draft awaits review or recorded approval. |
| `approved` | The user approved this exact piece on its tracker item. The calendar links to that record. |

An editorial review does not supply user approval. A changed piece returns to `needs review`. The publicist's approval gate owns any later sending action. A planned date and an approved draft do not prove that a post was scheduled or published.

## Source and licence

Adapted from Ben Barclay's [Hermes social media content calendar](https://github.com/NousResearch/hermes-agent/blob/91a545ab1e09a266aead11da62665ab7230d9840/optional-skills/creative/social-media-content-calendar/SKILL.md). Upstream commit: `91a545ab1e09a266aead11da62665ab7230d9840`.

Copyright (c) 2025 Nous Research. The upstream MIT permission and warranty notice is preserved in [LICENSE](LICENSE).
