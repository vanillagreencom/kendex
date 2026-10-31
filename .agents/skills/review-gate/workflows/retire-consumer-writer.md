# Retire the gate writer in an existing consumer

Run once in a consumer that holds the retired gate package. The retirement prerequisite: [references/adoption.md § Trusted removal for an existing consumer](../references/adoption.md#trusted-removal-for-an-existing-consumer).

1. After the catalog removal merges, the consumer's owning lane sets `KENDEX_RELEASE` to a checkout of that kendex release. From the consumer root, it refreshes the packages and runs the reviewed adopter:

   ```bash
   kendex refresh
   "$KENDEX_RELEASE/refresh/adopt-refresh.sh" --retire-writer
   kendex verify --scope project
   git add -A
   ```

2. Commit the package update, retired workflow deletion and inventory removal in a normal PR. It takes the surviving CI checks, a final-head Copilot approval and resolved review threads. It does not use the automatic render-only route. An edited, symlinked or unrecorded workflow stops adoption and needs an owner decision.
3. With those checks met, the repository's overseer sends the owner one line that the removal PR is ready to arm. The owner removes `Review gate` from that repository's required-checks ruleset and binds its other contexts to GitHub Actions (`integration_id` 15368). The target layout is the KEN-2067 design note § Target, attached to that Linear issue.
4. After the owner replies done, arm the removal PR. The required-check transition precedes writer removal, or later PRs wait for a status no workflow posts. Once the removal PR merges, automatic refresh starts from the fully migrated default branch.
