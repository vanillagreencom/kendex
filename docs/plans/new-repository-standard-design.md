# New repository standard design

Fleet's existing `repo-create` writes the repository files and GitHub merge rules, but a new repository still needs owner actions before it has the full standard. The gaps are the refresh environment, app installation coverage, project instructions, worktree link settings, fleet registration completion, and the Linear GitHub link. [F1][K1][K2]

## Scope and evidence

- **Issue**: [KEN-2704][I1]. This document proposes changes for owner approval. The build waits for that approval. The design PR can merge before build approval.
- **Evidence**: supplied fleet source and help text, the current kendex source, the merged consumer refresh design, and the live KEN-2613 brief. Source inspection establishes what code does. It does not establish current GitHub settings or a successful repository creation. [F1][F2][F3][K3][I2]
- **Status terms**: Done means the source implements the part. Partial means the source implements part of it. Missing means the inspected creation path supplies no implementation. Owner step means the existing tool requires an owner action. None means `repo-render` does not perform that part. These terms do not certify a live repository.

## Gap table

| Part of the standard | `repo-create` today | `repo-render` today | Smallest proposed change and owner |
| --- | --- | --- | --- |
| Merge settings | Done: enables auto-merge and squash; disables merge and rebase commits; uses the PR title and body; deletes merged branches; disables wikis. [F1] | None. [F1] | Fleet: keep `MERGE_SETTINGS` as the definition. Read back the result before reporting complete. |
| Rulesets | Done: adds the name to the organization protections; creates or corrects repository queue and required-checks rulesets. `CI` is bound to GitHub Actions. [F1][F3] | None. [F1] | Fleet: reuse the existing definitions and drift reader. Do not create a second ruleset policy. |
| Required CI workflow | Partial: commits `CI` on PR and merge-group events. Its job reports success with no test jobs yet. [F1] | Partial: writes it only when absent. [F1] | Fleet: label this as initial repository wiring. The repository owner adds project tests through the existing harness-ci template. Passing initial CI proves no project test coverage. |
| Refresh caller | Partial: runs the installed adopter only when the workflow is absent. It skips the workflow when environment checks report an owner step. Today's template contains the full job. [F1][K1] | Same render path. It does not update an existing workflow. [F1] | Fleet: retain the adopter as the writer. Follow the KEN-2613 migration before selecting the shared caller. Kendex: retain ownership of caller adoption. [K3][I2] |
| `kendex.toml` and harness declarations | Done for a fresh repository: `kendex add` selects Claude, Codex, Copilot, and Pi for orch and linear. It adds xcode-run when the fleet row declares Apple. An existing manifest skips this add. [F1][K4] | Same absent-manifest rule. [F1] | Fleet: preserve the current explicit harness selection. Report an existing incomplete manifest as owed work; do not replace user intent. |
| Worktree symlink entries | Missing in the inspected render. `WORKTREE_SYMLINKS` belongs in `kendex.settings.toml`, not `kendex.toml`. Its package default is empty. The current add arguments expose no settings input. [F1][K2][K4] | Same gap. [F1][K2] | Kendex: extend `kendex add` to accept declared project settings through its existing settings writer. Fleet: supply link entries for ignored cache and private files only where they exist and sharing is intended. Preserve assigned values. [K2][K5] |
| `.gitignore` | Done for kendex local state through `kendex add`. Kendex writes its managed ignore block. This is not a language-specific ignore file. [F1][K6] | Same when add runs; no separate ignore writer. [F1] | Kendex: retain the managed block. Fleet: supply only project-specific rules that the project needs. Do not copy kendex's block into a template. |
| `AGENTS.md` skeleton | Missing: `first_render` has no project instruction writer. Kendex's shim code reads existing instruction files. [F1][K7] | Same gap. [F1] | Fleet: add an absent-file step in `first_render`, using kendex's existing root instruction template. Fill the repository name and supplied purpose. Omit unknown commands and paths. Kendex: retain ownership of the template and harness shims. [K7][K8] |
| `kendex` environment and secrets | Owner step: prints the existing provisioning command when adoption reports an unprovisioned environment. It continues without the refresh workflow. [F1] | Same owner step. An unreadable environment fails the render. [F1] | Kendex: add a repository selector to `provision-environment.sh`. The owner provisions the new repository on the owner's machine. Fleet: retain the owner-step result until a rerun passes the existing environment check. [K1] |
| GitHub App installations | Owner action: creation uses the repos and people apps. Missing lanes app coverage fails creation at `step=lanes-token` before rendering and merge rules. The owner repairs installation coverage and reruns the action. This verb does not install apps. [F1][F2] | Needs an existing lanes app installation. A refused token stops the command. [F1][F2] | Fleet: carry the existing installation failure and repair step into the proposed completion report. The organization owner installs the needed apps. Reuse review-gate's standard report for its configured app. [K1] |
| Fleet registration | Partial: `repositories.json` records creation. `repo-row` separately writes `repos.toml` through a fleet PR and waits for installation. The supplied source does not show the action worker calling it. [F1] | None. It can read an existing row for platform selection. [F1] | Fleet: reuse `repo-row` in the existing create-repository action. Verify current worker wiring before changing it. Report ready only after the row is installed. No new registration tool. |
| Linear team | Done when the agents token and reference team permit it. It creates or resumes a recorded team and copies settings. Refusals become owner steps; creation still reports `linear-team=none`. [F1][F2] | None. [F1] | Fleet: keep the existing team step. Carry its owed state into the completion result. Do not report a missing team as a full-standard repository. |
| Linear GitHub sync link | Owner step: prints the settings page and the GitHub-to-Linear link instructions. The source states that Linear's API cannot read or write the link. [F1] | None. [F1] | Fleet: keep the owner step in the existing action result. Record the owner's confirmation separately from API verification. Do not invent an automated link API. |

## Creation and completion

- **Creation route**: require every new organization repository, including an owner's repository, to use the existing create-repository action. It invokes `lane-host-daytona repo-create NAME --visibility private|internal --owner LOGIN` under the action worker. The current command refuses a repository it did not create. [F1][F2]
- **Employee route**: the issue reports that members cannot create repositories. That setting is unverified in this session. If it holds, employees already use the creation action. The owner can still create a repository outside that route. [I1]
- **Current completion**: an unprovisioned refresh environment and a failed Linear team step produce owner steps while creation continues. Missing lanes app coverage stops `cmd_repo_create` at `step=lanes-token`. GitHub can already hold the created repository, but rendering, merge rules, and team steps have not run. This failure occurs whenever the lanes app installation excludes the new repository. Its frequency is unmeasured. The owner repairs installation coverage and reruns the action. Action-worker registration wiring and reporting remain unverified. [F1][F2]
- **Proposed completion**: extend the existing action result to distinguish a repository that exists from a repository that meets the standard. Preserve its current step records and failures. Report missing environment provisioning, app coverage, fleet row, Linear team, or owner-confirmed sync as owed work. This broader completion report is proposed fleet work. [F1][F2]
- **Proposed owner sequence**: the action reports the target repository and owed owner steps. The owner repairs missing app coverage, provisions its environment, and confirms the Linear link. The action resumes its recorded creation and runs the existing renderer. Add checks for repository rules, environment placement, rendered files, and the installed fleet row through their current owners. [F1][K1][K7]
- **Privileged writes**: keep environment provisioning on the owner's machine. Its existing script requires Administration write and Environments write. Lane credentials must not hold those permissions. A repository selector limits the write; it does not move the private key onto the fleet host. [K1]
- **Reruns**: preserve the creation record and existing read-before-write behavior. A lost reply must not create another team. An existing edited workflow or assigned setting must stay intact. [F1][K5][K9]

## Repositories created in GitHub

- **Policy**: use the creation route above for new repositories. No inspected command brings an arbitrary GitHub-created repository to the whole standard. `repo-create` refuses it. `repo-render` supplies files only. It cannot install apps, set merge rules, create the Linear team, register the repository, or make the sync link. [F1]
- **Existing exception**: the owner applies fleet's documented organization repository steps, provisions the environment, and supplies the team, registration, and link. `repo-render` supplies the owed files through a PR. This is a manual recovery route, not a second default creation process. [F1][F3][K1]
- **Template**: no template repository is needed. The current render already writes the manifest, render, and CI file. The same `first_render` function can supply the missing instruction skeleton and project settings. A copied refresh caller would add another file that can become stale. [F1][K3]

## Another organization's refresh

- **Design answer**: another organization can use its own GitHub App and the same secret names in its own repository's `kendex` environment under the shared-workflow design. The called workflow declares the two app secret names, and the caller maps each to its same-named secret ([D003's 2026-10-04 caller-secrets amendment](../decisions/D003-one-merge-path.md#amendment-2026-10-04-the-callers-secrets), approved by the owner's ruling on ask 1791104990-3321519-1790). The called job declares the environment and scopes its repository token to the calling repository. Run 37191124465 proves this route for a caller in vanillagreencom; a caller in another organization is not proven on it. [K3][I2]
- **GitHub access**: GitHub permits a call to a public reusable workflow when the calling organization and repository allow that use. The owner does not have to belong to vanillagreencom for this public-workflow route. The caller uses `vanillagreencom/kendex/.github/workflows/refresh-consumer.yml@v1` once the published major tag holds it. The calling organization's Actions policy is unverified here. [G1][K3]
- **Secret semantics**: GitHub says a caller cannot pass environment secrets. A called job can declare an environment and use its secrets. The documentation does not identify which repository supplies that environment. Build A's acceptance runs bear on it. With no `secrets:` key the job read both app secrets empty (run 37187198901). With the names declared under `on.workflow_call.secrets` and the caller mapping each to its same-named secret, it read both set, and the sandbox held no repository or organization secret (run 37191124465). The values come from the calling repository's `kendex` environment; [D003's caller-secrets amendment](../decisions/D003-one-merge-path.md#amendment-2026-10-04-the-callers-secrets) states the evidence and its limit. This design uses neither inherited secrets nor repository secrets. [G2][K3]
- **Actual source status**: this checkout contains the old copied workflow and adopter. It contains no `.github/workflows/refresh-consumer.yml` or `refresh/` implementation. KEN-2613 is In Progress in the live read. Its actual shared workflow and adoption branch are unavailable here. Their implementation and acceptance result are unverified. [K9][K10][I2]
- **App permissions**: the current template requests repository Contents, Pull requests, and Workflows write, plus read permissions for the environment and standard checks. The external app needs the permissions the shared workflow requests when that implementation is available. Do not assume an app with fewer permissions passes. [K10][I2]
- **Upstream issue filing**: the current copied job separately requests an Issues token for `vanillagreencom/kendex`. An outside app's local installation does not establish access there. The refresh design permits missing upstream filing to leave a live rendered-file finding open, which can hold merging under thread resolution. Core refresh and upstream filing need separate proof. [K3][K10]
- **Provisioning**: the existing standard report and provision command support organization-specific app, environment, and secret settings. The refresh workflow still fixes `kendex` and `FLEET_GH_APP_ID;FLEET_GH_APP_PRIVATE_KEY`. Store the outside app's values under those names. Its installation and the calling organization's shared-workflow access remain unverified. [K1][K10][I2]
- **Build A requirements**: the called job must use the caller's repository and environment. The caller maps the two app secret names the called workflow declares, each to its same-named secret, which replaced this design's no-secret requirement once the acceptance run disproved it. The adopter must validate the shared workflow's fixed environment and secret names instead of extracting empty names from the short caller. It must preserve edited workflows. The acceptance run must prove default-branch secret access and non-default-branch refusal before this route is treated as working. [K3][I2]
- **Dispatch**: schedule and manual triggers belong to the caller. Instant catalog dispatch is organization wiring in the current template. Do not promise an outside organization instant dispatch from its own app without evidence of that wiring. [K3][K10]

## Proposed build work

These are proposals for the owning repositories. This item files no fleet issue. Owner approval is required before build work starts. [I1]

| Proposed item | Repository | Scope and evidence of completion |
| --- | --- | --- |
| FLT proposal: complete the existing first render | Fleet | Add the absent project instruction skeleton and project link settings to `first_render`. Reuse kendex's writers and template. Preserve user edits. Prove the fresh path and rerun path through the existing repo-create and repo-render tests. [F1][K2][K5][K8] |
| FLT proposal: report full-standard completion | Fleet | Inspect the create-repository worker first. Reuse `repo-row` if registration wiring is missing. Carry owner steps and Linear failures through the existing result. Read back merge settings. Verify installation before ready. Keep the current ruleset definitions. [F1][F2][F3] |
| FLT proposal: adopt the released shared refresh route | Fleet | After the KEN-2613 migration permits first adoption, use its released adopter from the existing render step. Preserve the owner-only provisioning boundary. Verify the selected caller and one passing refresh run. [F1][K3][I2] |
| Kendex proposal: target environment provisioning | Kendex | Add a repository selector to the existing owner-run command. Retain its current organization and installation checks. Reuse its environment writer and read-only checker. Verify the selected write and preservation of other repositories. [K1] |
| Kendex proposal: project settings in add | Kendex | Extend the existing add command to pass declared settings to its engine writer. Fleet is the caller for initial worktree links. Prove settings validation and preservation of assigned values. Do not add a second settings writer. [K4][K5] |
| Owner action: installation and Linear link | Organization owner | Confirm app coverage and the repository-to-team link. Environment provisioning needs the owner's credential. The source cannot certify the link through its API. [F1][K1] |

## Build acceptance and unknowns

- **First proof**: use drovr only after the owner confirms an empty new repository exists and approves its use. The issue reports an archived drovr and an empty recreated Linear team. Those facts are unverified here. Otherwise, the owner names a throwaway repository. [I1]
- **Creation proof**: read the resulting merge settings and effective rules. Confirm the current render, caller, environment placement, app coverage, installed fleet row, and Linear team. Obtain the owner's sync confirmation. An initial green `CI` does not replace these checks. [F1][F3][K1]
- **Refresh proof**: run the chosen released caller after adoption. The shared-workflow secret route needs KEN-2613's default-branch success and non-default-branch secret refusal proof. Another organization's app needs its own acceptance run. No run is measured in this design. [K3][I2]
- **Impact and likelihood**: an unprovisioned environment leaves a created repository without automatic refresh. The inspected path reaches this result whenever adoption reports that owner step. Its frequency is unmeasured. [F1]
- **Impact and likelihood**: initial `CI` can pass while project defects remain untested. This is the explicit initial workflow behavior before project test jobs are added. Its defect rate is unmeasured. [F1]
- **Source disagreement**: fleet's supplied rulesets document still lists drovr as held out. The supplied `OUTSIDE_STANDARD` constant does not include drovr. Use the constant for the inspected drift behavior. Current drovr settings remain unverified. [F1][F3]
- **Remaining evidence**: current organization creation permissions, app installation coverage, KEN-2613 code and acceptance, action-worker registration wiring, and the proof repository are unverified. Read them during the owning build work before claiming complete default setup. [I1][I2][F1]

## Sources

- **F1**: fleet `bin/lane_host/repos.py`, supplied read-only source. The issue names its installed location as `/opt/fleet/lib/lane_host/repos.py`. Functions: `cmd_repo_create`, `first_render`, `cmd_repo_render`, `cmd_repo_row`, `linear_team_step`, and `ruleset_drift`.
- **F2**: fleet `bin/lane-host-daytona` help, supplied read-only output. Sections: `repo-create` and `repo-render`.
- **F3**: fleet [docs/rulesets.md][F3], supplied read-only source. Section: Organization repositories.
- **K1**: kendex [environment provisioning](../../skills/review-gate/scripts/provision-environment.sh) and [adoption settings](../../skills/review-gate/references/adoption.md#settings).
- **K2**: kendex [worktree settings](../../skills/worktree/kendex.settings.toml.example) and [worktree package](../../skills/worktree/SKILL.md#configuration).
- **K3**: kendex [consumer refresh source design](consumer-refresh-source-design.md#design), its [migration order](consumer-refresh-source-design.md#migration-order), and its [documentation evidence](consumer-refresh-source-design.evidence.json). The [D003 refresh outcome](../decisions/D003-one-merge-path.md#revisit-outcome-2026-10-02) records the approved direction.
- **K4**: kendex [add declarations](../../crates/core/src/engine/ops/add.rs) and [CLI add](../../crates/cli/src/commands/add.rs).
- **K5**: kendex [settings writer](../../crates/core/src/engine/settings_write.rs).
- **K6**: kendex [managed ignore writer](../../crates/core/src/engine/posture.rs).
- **K7**: kendex [instruction shim observer](../../crates/core/src/engine/instruction_shims/observe.rs) and [instruction shims](../../crates/core/src/engine/instruction_shims.rs).
- **K8**: kendex [root instruction template](../../skills/docs-writing/templates/root-AGENTS.md).
- **K9**: kendex [current adopter](../../skills/review-gate/scripts/adopt-refresh.sh).
- **K10**: kendex [current refresh template](../../skills/review-gate/templates/kendex-refresh.yml).
- **I1**: [KEN-2704][I1], live brief read in this session.
- **I2**: [KEN-2613][I2], live brief read in this session.
- **G1**: GitHub Docs, [access to reusable workflows][G1], read in this session.
- **G2**: GitHub Docs, [environment secrets in reusable workflows][G2], read in this session. Context7 refused its configured API key; direct official documentation supplies these claims.

[F1]: https://github.com/vanillagreencom/fleet/blob/main/bin/lane_host/repos.py
[F2]: https://github.com/vanillagreencom/fleet/blob/main/bin/lane-host-daytona
[F3]: https://github.com/vanillagreencom/fleet/blob/main/docs/rulesets.md
[K1]: ../../skills/review-gate/scripts/provision-environment.sh
[K2]: ../../skills/worktree/kendex.settings.toml.example
[K3]: consumer-refresh-source-design.md
[K4]: ../../crates/core/src/engine/ops/add.rs
[K5]: ../../crates/core/src/engine/settings_write.rs
[K6]: ../../crates/core/src/engine/posture.rs
[K7]: ../../crates/core/src/engine/instruction_shims/observe.rs
[K8]: ../../skills/docs-writing/templates/root-AGENTS.md
[K9]: ../../skills/review-gate/scripts/adopt-refresh.sh
[K10]: ../../skills/review-gate/templates/kendex-refresh.yml
[I1]: https://linear.app/vanillagreen/issue/KEN-2704
[I2]: https://linear.app/vanillagreen/issue/KEN-2613
[G1]: https://docs.github.com/en/actions/reference/workflows-and-actions/reusing-workflow-configurations#access-to-reusable-workflows
[G2]: https://docs.github.com/en/actions/how-tos/reuse-automations/reuse-workflows#using-inputs-and-secrets-in-a-reusable-workflow
