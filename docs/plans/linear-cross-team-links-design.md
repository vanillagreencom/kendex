# Cross-team Linear links design

A lane links an issue in another team by writing that issue's full Linear URL in a comment, with its own team's key. Linear then adds a "related" link on both issues by itself, even when the writing key cannot see the other team. A lane waits on another team's issue with the `blocked` label plus that URL. The overseer reads the other issue's state when it picks work. No master and no cross-team blocking relation are needed. One finding comes first: the application token the fleet's lanes use today can already read every team, and by Linear's documentation it can write in every team too. Your rule that no lane can file in another team holds only once lanes write with a key limited to their own team.

Design for owner review (KEN-2689). This change builds nothing. Measurements and sanitized API answers: [linear-cross-team-links-design.evidence.json](linear-cross-team-links-design.evidence.json). Raw responses stay in the KEN-2689 worktree under `tmp/ken-2689/`, named in each section below.

## The lanes' app token reaches every team

The kendex lane's `linear.sh` uses `LINEAR_APP_TOKEN`, not a personal key. `linear.sh auth-check` reports `credential: app-token` and actor "vanillagreen agents", an OAuth application. The fleet publishes this one token to every lane: [skills/linear/README.md](../../skills/linear/README.md) § Settings says "The fleet publishes the token as `LINEAR_APP_TOKEN` to its secret store" and "Keep one minting host".

What Linear answered on 2026-10-03 at 21:45:01 UTC (14:45:01 PDT), read-only, with that token (`tmp/ken-2689/scope-app.json`):

| Question | Linear's answer |
|---|---|
| Is the actor an app? | `app: true`, `admin: false`, `owner: false`, `guest: false` |
| Can it reach any public team? | `canAccessAnyPublicTeam: true` |
| Which teams can it read? | All 11: MAC, TLK, FLT, VSY, VG, HTIO, DRO, KEN, VGS, MEM, HT. All are public. |
| Which teams is it a member of? | MAC and VG |
| Which teams can it administer (`administrableTeams`)? | All 11 |
| Which scopes does it hold? | No query returns them. The schema has `OauthClientApproval.scopes`, but no query the token can run reaches it. |
| Can it write? | Yes, in KEN. This round's `issues activate KEN-2689` moved the issue to In Progress at 21:35:08 UTC as "vanillagreen agents". No write was tried in another team. |

The skill mints the token with a fixed scope. [skills/linear/README.md](../../skills/linear/README.md) § Settings: "The client credentials grant always requests scope exactly `read,write`."

What Linear documents about these tokens:

- [OAuth 2.0 authentication](https://linear.app/developers/oauth-2-0-authentication), client credentials: "The token generated using this grant type will be an `app` actor token that has access to all public teams in the workspace and is valid for 30 days."
- Same page, scopes: "`read` - (Default) Read access for the user's account. This scope will always be present." and "`write` - Write access for the user's account. If your application only needs to create comments, use a more targeted scope". The other scopes listed are "`issues:create` - Allows creating new issues and their attachments", "`comments:create` - Allows creating new issue comments" and "`admin` - Full access to admin level endpoints."
- Same page: "The app user's team access can be modified through the [app details page](https://linear.app/settings/applications/) for your app at any point after the token is generated."
- [Agents, Management](https://linear.app/developers/agents): "The team access available to your app can be changed or revoked at any time by workspace admins."
- [Agents, Admin](https://linear.app/developers/agents): "Note that integrations using the `actor=app` mode are not able to also request `admin` scope."
- A scope limited to some teams: not documented. Linear documents team access for the app as a whole, not per scope.

What this means:

- Your premise holds for a personal key limited to one team. It does not hold for the app token. With `read,write` and access to all 11 public teams, the token can by Linear's documentation write in any of them. The linear skill's team setting does not stop this: [skills/linear/SKILL.md](../../skills/linear/SKILL.md) § Shared label maintenance says "`LINEAR_TEAM` requires a target before writes; it does not restrict an API key".
- A lane that holds the app token needs no read key: it already reads every team. The read key is needed only once a lane's write credential is limited to its own team.
- Decided: the design keeps your rule. The follow-up build makes each lane's write credential team-limited, then adds the read key. Two routes give a team-limited writer. KEN-2685's fleet load figure picks between them:
  - A personal key per team, each limited to its team (your proposed shape). Every one of them shares your one personal bucket of 2,500 requests per hour (§ Read cost). This route holds if KEN-2685 shows the whole fleet fits that bucket.
  - One OAuth app per team, each with its team access limited to that team on its app details page. Each app has its own bucket of 5,000 requests per hour. `linear.sh auth-mint` already mints these tokens. This route holds if the fleet does not fit your bucket.

## Linear's rules on keys and links

| Your fact | Linear's words | Verdict |
|---|---|---|
| A key takes one permission set and one team list | [API and Webhooks](https://linear.app/docs/api-and-webhooks): "For each key you create, you can choose to give it full access to the data your user can access, or restrict it to certain permissions (_Read, Write, Admin, Create issues, Create comments)._ You can also limit an API key's access to specific teams in your workspace." [Security & Access](https://linear.app/docs/security-and-access): "Create API keys for your account with specific permissions, optionally scoped to particular teams." | Documented: one permission choice and one team list per key. A different permission per team is not documented. No documented setting makes a key that reads all teams and writes one. |
| A relation needs a key that sees both issues | Not documented. [Issue relations](https://linear.app/docs/issue-relations): "When you reference issues in a description or comment, they'll automatically become a related issue." [Editor](https://linear.app/docs/editor): "Referenced issues are added as [related issues](https://linear.app/docs/issue-relations) automatically." | Partly wrong. A KEN-only key created a KEN-to-VGS "related" relation by writing a URL (§ Backlink measurement). The reported failure was the explicit blocking relation: KEN-2688 blocks VGS-787 returned "Entity not found: Issue" from the kendex key (KEN-2689 description). |
| Every key of one user shares one bucket | [Rate limiting](https://linear.app/developers/rate-limiting): "When authenticated using an API key you can make up to **2,500 requests per hour**. Requests are associated with the authenticated user, which means all requests by the same user share the same quota even when using different API keys." and "Requests authenticated using an API key can request up to **3,000,000 points per hour**. Requests are associated with the authenticated user, which means all requests by the same user share the same quota even when using different API keys." | Documented. The KEN-only key's headers read `X-Ratelimit-Requests-Limit: 2500` and `X-Ratelimit-Complexity-Limit: 3000000`. |
| An app has its own bucket | Same page, tables: "OAuth App \| 5,000 \| User (or App User) \| 1 hour" and "OAuth app \| 2,000,000 \| User (or App User) \| 1 hour". | Documented. The app token's headers read 5000 and 2000000. |

## Backlink measurement

Method:

1. Baseline. The app token read VGS-787 at 21:45:49 UTC (14:45:49 PDT): relations both ways, attachments, comments and history (`tmp/ken-2689/vgs787-baseline.json`). VGS-787 had one inverse relation (VGS-786 blocks it), no attachments, one comment and one history entry.
2. Write. The KEN-only personal key posted comment `6bb193a0-6a1a-4ae0-bbf3-a8a0b442073c` on KEN-2689 at 21:46:15 UTC (14:46:15 PDT). It held VGS-787's URL as Linear prints it and one sentence saying the KEN-2689 lane wrote it as this measurement (`tmp/ken-2689/comment-write.json`, headers in `comment-write.headers`). It cost 1 request and 5 complexity points.
3. Read again. The app token read VGS-787 at 21:46:18 UTC (`vgs787-after0.json`) and at 21:47:39 UTC, 84 seconds after the write (`vgs787-after1.json`). Both reads match each other.
4. KEN side. The KEN-only key and the app token read KEN-2689 at 21:46:26 UTC (`ken2689-after0.json`, `ken2689-after0-app.json`). The app token read the comment's stored text (`comment-bodydata.json`).

Result: Linear shows the backlink.

- VGS-787 gained a "related" inverse relation from KEN-2689 (relation `fb00b3bd-fade-4c07-bec3-47a3c0eaf418`, created 21:46:15.210 UTC). Its history gained an entry adding KEN-2689 as related, by your user, the key's owner. Its `updatedAt` moved to the same time. Nothing else changed.
- KEN-2689's history shows VGS-787 added as related at the same time.
- The KEN-only key cannot see that relation. Its read of KEN-2689's relations omits it. Its read of the relation by id returns "Entity not found: IssueRelation". The app token lists it.
- The comment stores the URL as a link, not as an issue mention.
- The link shows in the app too: [Issue relations](https://linear.app/docs/issue-relations) says "The issue and type of relationship will show up in the issue properties sidebar." No UI read is needed. To see it, open VGS-787 and look for KEN-2689 under Related in the sidebar.
- The team limit on a key does not stop this cross-team "related" link. It is the link requirement 2.3 asks for, and it needs no relation write and no master.
- The design writes the full URL. A bare identifier such as `VGS-787` was not measured.

## The design

| Your proposal | Verdict |
|---|---|
| 2.1 Writes use each repository's key, its own team only | Holds once the precondition in § The lanes' app token reaches every team is met. |
| 2.2 One read-only all-teams key, used only to read an issue outside the team (state, title, url) | Holds. A lane needs it to get the other issue's URL before it links. The overseer needs it to read a blocker's state. |
| 2.3 A link is the other issue's URL in a comment, written with the team key | Holds, measured. Linear adds the backlink itself. Write the URL from the issue's `url` field. |
| 2.4 A blocker is the `blocked` label plus that URL; the overseer reads its state at pick time | Holds. The URL also gives both issues a "related" link. The overseer launches the item once the blocker's state is Done or Canceled. |
| 2.5 No native cross-team relation | Holds. The "related" link arrives with 2.3. A cross-team blocking relation adds nothing the label and the overseer's read do not already give. |

Requirement 4: no new hook or gate. A Read-only key cannot write; Linear enforces that, so no check in the skill repeats it.

## Read cost

The read the skill would run, one request per batch:

```graphql
query($id: String!) { issue(id: $id) { identifier title url state { name type } } }
```

| Read | Requests | Complexity (`X-Complexity`) | Evidence |
|---|---:|---:|---|
| One issue in KEN, KEN-only key | 1 | 3 | `read1-key-ken.headers` |
| One issue in VGS, app token | 1 | 3 | `read1-app.headers` |
| One issue in VGS, KEN-only key (refused, "Entity not found: Issue") | 1 | 3 | `read1-key-vgs.headers` |
| Ten VGS issues in one request (aliases) | 1 | 25 | `read10-app.headers` |

Linear's formula gives each issue 2.5 points: "Each property is 0.1 point, each object is 1 point and any connection multiplies its children's points based on the given pagination argument, or the default 50. The score is then rounded up to the nearest integer." ([Rate limiting](https://linear.app/developers/rate-limiting)). Both measured values match it.

Figures for KEN-2685's load model:

- Per overseer pass: 1 request, and 2.5 points per cross-team blocker rounded up (3 for one, 25 for ten). A pass with no cross-team blocker reads nothing.
- Per lane start: 1 request and 3 points for each start whose issue names another team's issue. A start with none reads nothing.
- One request is 1/2,500 of your hourly request bucket (0.04%). The points are a negligible share of 3,000,000. Requests, not points, are the limit that binds.
- A refused read costs the same as a successful one.

## The key to create

No naming rule for keys or 1Password items is written in this repository. The search covered `docs/`, `skills/`, `kendex.settings.toml` and `kendex-local.toml`. The skill's own variables take the `LINEAR_` prefix and are declared in [skills/linear/kendex.settings.toml.example](../../skills/linear/kendex.settings.toml.example) `[secrets]`. This design proposes the names below.

| Field | Value |
|---|---|
| Name in Linear | `linear-read-all-teams` |
| Created by | You, in your account: Settings, Account, Security & Access, Personal API keys |
| Permissions | Read only |
| Teams | No team limit |
| 1Password | Vault `dev`, item `linear-read-all-teams`, field `credential` |
| Variable | `LINEAR_READ_API_KEY`, set to `op://dev/linear-read-all-teams/credential` in each overseer's and lane's private env file (`.env.local`). The skill already resolves `op://` references. |

Skill text the follow-up build changes:

- [skills/linear/kendex.settings.toml.example](../../skills/linear/kendex.settings.toml.example) `[secrets]`: add `LINEAR_READ_API_KEY`.
- [skills/linear/README.md](../../skills/linear/README.md) § Settings: add the variable's table row.
- `skills/linear/scripts/lib/auth.sh`: resolve `LINEAR_READ_API_KEY` for reads only.
- `skills/linear/scripts/commands/issues.sh` `get` and `bulk-get`: read an issue whose prefix is not the configured team's key with the read key.
- [skills/linear/SKILL.md](../../skills/linear/SKILL.md) § Blocked Label vs Issue Relations: a blocker in another team is the `blocked` label plus a comment holding its URL, never `--blocked-by`.
- Outside the linear skill: `skills/orch/workflows/oversee.md`, the candidate rule, reads a cross-team blocker's state with `issues bulk-get` before it launches the item.

## Summary for the owner

- The lanes' app token already reads all 11 teams. By Linear's docs it can also write in all of them. Your "own team only" rule holds only after lanes write with team-limited keys.
- A link written as the other issue's URL in a comment works with a team-only key. Linear adds a "related" link on both issues. Measured on KEN-2689 and VGS-787.
- Blockers in another team: the `blocked` label plus the URL. The overseer reads the blocker's state when it picks work. No master and no cross-team relation needed.
- One new key: `linear-read-all-teams`, Read only, all teams, created in your account, stored in 1Password vault `dev`, read as `LINEAR_READ_API_KEY`.
- Cost: 1 request (3 points) per read, out of your 2,500 requests per hour. A ten-issue batch is still 1 request.
- Team-limited write keys share your one bucket. If KEN-2685 shows the fleet does not fit, each team gets its own app limited to that team instead.
- Approve this design and the follow-up build is filed.
