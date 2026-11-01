---
name: youtube-publish
description: "Load to draft a YouTube upload, comment or reply, or send a draft after the user's recorded approval."
summary: "YouTube Data API publishing with synthetic-content disclosure and an approval check on the sending path."
license: MIT
user-invocable: true
dependencies:
  required: [linear]
metadata:
  author: vanillagreen
  source: kendex
  repository: "https://github.com/vanillagreencom/kendex"
  bugs: "https://github.com/vanillagreencom/kendex/issues"
tags: [integration]
---

# YouTube publish

Use Python 3.8 or newer. The executable is `scripts/youtube-publish` under this installed skill.

## Consumer setup

- The consumer supplies `YOUTUBE_CHANNEL_ID` and `YOUTUBE_APPROVER_EMAIL` in the command environment. The email identifies the user who can approve a request on Linear.
- The consumer supplies `YOUTUBE_ACCESS_TOKEN` through a private credential route. Keep the OAuth client, its secret, refresh token and access token outside the package and version control. An API key does not authorize uploads or comments.
- Use the consumer's OAuth client with `youtube.upload` and `youtube.readonly` for uploads and their channel check. Use `youtube.force-ssl` for comments and replies. The consumer's authorization tool owns token acquisition, renewal and revocation. The script checks the token's channel with `channels.list` before a write. See [authorization](https://developers.google.com/youtube/v3/guides/authentication) and [channel lookup](https://developers.google.com/youtube/v3/docs/channels/list).
- The installed Linear skill supplies live tracker reads. Its configured credentials must be able to read the consumer's tracker item and comment authors.

## Draft and approval

To draft an upload, comment or reply, or to send a draft after its recorded approval, follow [workflows/publish.md](workflows/publish.md).

- Each draft prints an `approval_record` object. The user records their explicit yes by posting that object as the entire comment body on the named Linear item. The comment must come from `YOUTUBE_APPROVER_EMAIL`. A caller's assertion or an agent-authored approval is insufficient.
- Run `publish --draft PATH` only after that yes. The sending path reads the tracker item and comments live. It checks the author, decision, item and digest before any YouTube request. A changed draft or changed video needs a new approval.
- A failed or interrupted write can have an uncertain result. Stop and check the channel with the user before any new attempt. Do not repeat a successful request or reuse its approval for another send.

## Consent and spam

- YouTube requires specific express consent before uploads, comments and other actions. Identify the channel and visibility settings before consent. OAuth permission alone does not approve a particular send. Follow [Developer Policies III.E.3 and III.I.2](https://developers.google.com/youtube/terms/developer-policies).
- YouTube prohibits spam, harassment and disruptive commercial messages. Approval does not permit those actions. Draft a relevant comment or reply for its named recipient. Do not use repeated unsolicited promotion or bulk comment campaigns. Follow [Developer Policies III.I.11 and III.I.20](https://developers.google.com/youtube/terms/developer-policies).
- Report the returned visibility. Do not claim that a video became public from the requested setting alone. See [upload response](https://developers.google.com/youtube/v3/docs/videos/insert).
