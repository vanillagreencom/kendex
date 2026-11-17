# Set up publishers

Run for a publisher setup task launched with the `publicist` agent. Read that agent's § Setup before acting.

## Steps

Install approved third-party selections on the consumer through `kendex add`. Keep their source files with their publishers. Do not copy them into the kendex catalog.

Before each install command, resolve the publisher's selected full commit and read its complete licence at that commit. Stop installation and report to Jarvis if the licence is unreadable or does not establish the required licence in the table. Record its publisher, checked commit, licence and licence URL in the consumer's `kendex.toml`, before running the command. Use a manifest comment for this record. Select the consumer's project and environment, then install for `claude,codex,copilot,pi`.

Set `heygen_commit`, `hyperframes_commit` and `marketing_commit` to those checked full commits. The commands below bind new remote subscriptions to them. An existing subscription is reused; the positional revision does not change its revision setting. Before installation, confirm that the existing source's `rev` setting names the checked full commit and any retained package revision resolves to that commit. A branch or tag does not bind the checked commit. Change only the relevant consumer revision setting when the recorded setup approval covers that change. Preserve unrelated consumer choices. If the source cannot resolve to the checked commit within that approval, stop installation and report the mismatch to Jarvis.

| Publisher and selection | Licence | Acceptance for this install |
|---|---|---|
| `heygen-com/skills`: `heygen/heygen-avatar`, `heygen/heygen-video` | MIT | Both skills must load in Claude Code, Codex, Copilot CLI and Pi. |
| `heygen-com/hyperframes`: the core set in the command below | Apache-2.0 | Each selected skill must load in Claude Code, Codex, Copilot CLI and Pi. |
| `coreyhaines31/marketingskills`: `marketing-skills/video`, `marketing-skills/social`, `marketing-skills/copywriting`, `marketing-skills/cold-email`, `marketing-skills/ads` | MIT | Each selected skill must load in Claude Code, Codex, Copilot CLI and Pi. |
| Consumer checkout of `google/skills`: `skills/ads/google-ads-api-quickstart` | Apache-2.0 | The skill must load in Claude Code, Codex, Copilot CLI and Pi. |
| Consumer checkout of `google/skills`: `skills/ads/google-ads-api-mcp-setup` | Apache-2.0 | The skill must load in Claude Code, Codex, Copilot CLI and Pi. |

```sh
kendex add "heygen-com/skills@$heygen_commit" --skill heygen/heygen-avatar,heygen/heygen-video --harness claude,codex,copilot,pi --yes --leave
kendex add "heygen-com/hyperframes@$hyperframes_commit" --skill core-skills/hyperframes,core-skills/hyperframes-animation,core-skills/hyperframes-audio,core-skills/hyperframes-cli,core-skills/hyperframes-core,core-skills/hyperframes-creative,core-skills/hyperframes-keyframes,core-skills/hyperframes-registry,core-skills/hyperframes-studio,core-skills/media-use --harness claude,codex,copilot,pi --yes --leave
kendex add "coreyhaines31/marketingskills@$marketing_commit" --skill marketing-skills/video,marketing-skills/social,marketing-skills/copywriting,marketing-skills/cold-email,marketing-skills/ads --harness claude,codex,copilot,pi --yes --leave
kendex add "$google_checkout/skills/ads/google-ads-api-quickstart" --skill google-ads-api-quickstart --harness claude,codex,copilot,pi --yes --leave
kendex add "$google_checkout/skills/ads/google-ads-api-mcp-setup" --skill google-ads-api-mcp-setup --harness claude,codex,copilot,pi --yes --leave
```

Google's plugin registry omits the Ads skills. The consumer retains an unchanged checkout of `google/skills` at its checked full commit. Set `google_checkout` to its absolute path. Confirm that commit and read its licence before each local-folder install. Keep the checkout unchanged and available as the local source.

After each remote install, read the installed revision from the consumer's installation record and confirm that it equals the checked commit. For Google, confirm that the checkout remains unchanged at the checked commit and that the installation record names the selected local folder. A local-folder record has no remote commit field. Report a mismatch to Jarvis and stop setup. Do not accept or use that install.

Extend the consumer's `publicist` assignment in `[agent-skills]` with the logical skill names selected above. Preserve its existing same-catalog assignments. Run `kendex apply` in that consumer. Check the rendered agent's required paths or Claude preload names against each installed native name. Then use each harness's native skill list or loader to check every selection. A file on disk alone does not prove loading. Stop setup and report the failed skill and harness if any selection fails.
