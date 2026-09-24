# Answering suppressed findings

The route [merge-pr.md](../workflows/merge-pr.md) § 3.2 and [oversee-events.md](oversee-events.md) send a lane to when the review gate reports findings a reviewer wrote into its review body. No thread carries them, so `review-pr-comments` reaches none of them and the thread count reads zero while the gate stays red.

Take the complete entry list from the review body's `Suppressed comments (N)` or `Previously missed (N)` block. The status detail is bounded at 140 characters and says how many entries it dropped, so it is never the list. Every entry needs an answer.

Disposition and answer every entry under [finding-disposition.md](finding-disposition.md), which owns the one-comment `Dispositions at <sha>` shape and what a reply may say. The gate subtracts only what that comment answers.

Never an admin merge, an empty commit, or a restack to earn a fresh head. A code change is only ever the fix itself.

Only the PR AUTHOR's comment counts: the gate reads the comment's login, and one posted under any other identity is ignored while the gate stays red. Resolve the posting identity against the PR author:

```bash
gh api user --jq .login
```

Equal, `auto-recommended` posts the comment once and re-checks, recording `review-suppressed-findings` if a term still blocks. Not equal, it records `review-suppressed-findings` naming the author who must post it, and never reports the findings as answered.
