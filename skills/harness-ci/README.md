# harness-ci

One function for a repository that commits its kendex render: changed paths in, `harness_only=true|false` out, so CI can stand its expensive lanes down on a diff that touches nothing it builds, lints, typechecks or tests. Opt-in: a repository that wants CI over its harness directories does not install it.

## Install

```bash
kendex add vanillagreencom/kendex --skill harness-ci
```

Install with the default symlink delivery, which writes the shared `.agents/skills/harness-ci/` tree every wiring example names. Copy delivery writes a tree per harness and no `.agents` tree, so a repository on it points its step at whichever tree it committed.

## What it does

- Classifies a diff between two commits as render-only or not.
- Treats content the repository authors inside the render trees as product source: a skill its manifest declares `source = "in-place"`, any script under `.agents/hooks`, and a Pi carrier package whose metadata declares extension entry points and tests.
- Answers `false` for anything it cannot prove, which runs every lane.
- Ships workflow shapes to copy, and the tests that pin the semantics, run in kendex CI.

## How it works

```bash
.agents/skills/harness-ci/scripts/harness-only \
  --event pull_request --base "$BASE_SHA" --head "$HEAD_SHA"
```

The consumer owns one thin step calling the rendered script, written by hand once from [references/wiring.md](references/wiring.md); the package never touches `.github/`, because a workflow installed into a stranger's CI renames jobs, drops required contexts and wedges merge queues. Checkout with `fetch-depth: 0`: the classifier diffs two real commits. Flags and exit codes: `harness-only --help`. The rules a wiring must hold: [SKILL.md](SKILL.md) § The rules to hold when wiring it.

## Semantics

- The generated roots are `.agents/`, `.claude/`, `.codex/`, `.opencode/`, `.cursor/`, `.pi/`, and the root `opencode.json` or `opencode.jsonc`. A Pi package with extension entry points and tests is product input. Its metadata is read from both diff endpoints, so deleting it also runs the product lanes. Prefixes match on the separator and the config names match whole, so `.agentsfoo/x`, `opencode.json.bak` and `ui/opencode.json` are product paths.
- `pull_request` diffs from the merge base (`base...head`); `push` and `merge_group` diff the two endpoints (`base head`), because a force-push leaves the `before` sha off the head's history.
- Rename detection is off, so both sides of a `git mv` into a render tree are listed and the diff answers `false`.
- `stdout` carries the verdict line and nothing else; changed paths and reasons go to `stderr`.
- Exit `0` with every verdict; `2` on a wiring error, which prints no verdict.

## Fail-closed

Every unprovable case answers `false`: an unclassified event; a missing, empty or unresolvable endpoint, the all-zero sha of a first push included; a diff git cannot read; an empty changed-file set; a path git had to quote; a manifest the head tree lists but that will not read. No flag turns any of these into a `true`.

## Customise

Nothing to configure. The script is upstream's: `kendex refresh` rewrites the render tree, so a local edit under `.agents/skills/harness-ci/` is drift. Send changes to [vanillagreencom/kendex](https://github.com/vanillagreencom/kendex); maintainer notes are in [DEVELOPMENT.md](DEVELOPMENT.md).
