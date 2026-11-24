# Set up publishers

- Run for a publisher setup task launched with the `publicist` agent.
- Read that agent's § Setup before acting.

## Steps

Install approved third-party selections in the consumer through `kendex add`. Keep their source files with their publishers.

1. Before each install command, resolve the publisher's selected full commit.
2. Read its complete licence at that commit.
   - Stop installation and report to Jarvis if the licence is unreadable or does not establish the required licence in the table.
3. Record its publisher, checked commit, licence and licence URL in the consumer's `kendex.toml`, before running the command.
   - Use a manifest comment for this record.
4. Set `heygen_commit`, `hyperframes_commit` and `marketing_commit` to those checked full commits. The commands below bind new remote subscriptions to them.
5. An existing subscription is reused; the positional revision does not change its revision setting. For an existing subscription:
   - Confirm that the existing source's `rev` setting names the checked full commit and any retained package revision resolves to that commit. A branch or tag does not bind the checked commit.
   - Change only the relevant consumer revision setting when the recorded setup approval covers that change.
   - Preserve unrelated consumer choices.
   - If the source cannot resolve to the checked commit within that approval, stop installation and report the mismatch to Jarvis.
6. Select the consumer's project and environment.
7. Install for `claude,codex,copilot,pi` with the commands below.

| Source | Required licence |
|---|---|
| `heygen-com/skills` | MIT |
| `heygen-com/hyperframes` | Apache-2.0 |
| `coreyhaines31/marketingskills` | MIT |
| Consumer checkout of `google/skills` | Apache-2.0 |

For each Google Ads skill, set `google_checkout` to the absolute path of the consumer's checkout of `google/skills`. Apply the pre-install commit and licence checks above to that checkout before each install. Keep it unchanged and available as the local source.

```sh
kendex add "heygen-com/skills@$heygen_commit" --skill heygen/heygen-avatar,heygen/heygen-video --harness claude,codex,copilot,pi --yes --leave
kendex add "heygen-com/hyperframes@$hyperframes_commit" --skill core-skills/hyperframes,core-skills/hyperframes-animation,core-skills/hyperframes-audio,core-skills/hyperframes-cli,core-skills/hyperframes-core,core-skills/hyperframes-creative,core-skills/hyperframes-keyframes,core-skills/hyperframes-registry,core-skills/hyperframes-studio,core-skills/media-use --harness claude,codex,copilot,pi --yes --leave
kendex add "coreyhaines31/marketingskills@$marketing_commit" --skill marketing-skills/video,marketing-skills/social,marketing-skills/copywriting,marketing-skills/cold-email,marketing-skills/ads --harness claude,codex,copilot,pi --yes --leave
kendex add "$google_checkout/skills/ads/google-ads-api-quickstart" --skill google-ads-api-quickstart --harness claude,codex,copilot,pi --yes --leave
kendex add "$google_checkout/skills/ads/google-ads-api-mcp-setup" --skill google-ads-api-mcp-setup --harness claude,codex,copilot,pi --yes --leave
```

After each install:

1. After each remote install, read the installed revision from the consumer's installation record.
   - Confirm that it equals the checked commit.
2. For Google, confirm that the checkout remains unchanged at the checked commit and that the installation record names the selected local folder. A local-folder record has no remote commit field.
3. Report a mismatch to Jarvis and stop setup.
   - Do not accept that install.
   - Do not use that install.

Then assign and check the skills:

1. Extend the consumer's `publicist` assignment in `[agent-skills]` with the logical skill names selected above.
   - Preserve its existing same-catalog assignments.
2. Run `kendex apply` in that consumer.
3. Check the rendered agent's required paths or Claude preload names against each installed native name.
4. Then check that every selected skill loads in Claude Code, Codex, Copilot CLI and Pi through each harness's native skill list or loader.
5. Stop setup and report the failed skill and harness if any selection fails.
