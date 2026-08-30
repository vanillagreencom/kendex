- Syncing the Linear cache now fetches comments in their own paginated request
  and pages them to completion, so every thread it fetches is cached whole
  rather than cut off at its first page.
