- Set `ORCH_PR_ORDER` to choose `review-first`, `open-first` or `push-first` for any repository. Push-first lets covered implementation and internal-fix rounds defer validation to required pull request CI before publication. Submit verifies required CI on the published head before merge. Uncovered work keeps local validation.

  You do: in `kendex.settings.toml` under `[env]`, set `ORCH_PR_ORDER = "push-first"` and `DEV_VALIDATE_CI_CONTEXT = "<the required status check whose pull request run covers DEV_VALIDATE_CMD>"`.
