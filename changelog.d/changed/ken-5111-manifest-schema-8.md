- `kendex.toml` moves to schema 8. Skills kendex keeps for you on unsubscribe, adopts, forks or installs from a template record `links = "shared-tree"`, and a template saves such a skill as a `shared-copy` member. Skills declared without the key install exactly as before. A kendex older than this release refuses a schema 8 manifest and a template index holding a `shared-copy` member, leaving both files unchanged.

  You do: upgrade kendex on every machine that applies this project or uses your templates; the next apply rewrites `kendex.toml` to schema 8 itself.
