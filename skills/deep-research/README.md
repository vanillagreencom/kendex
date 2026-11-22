# deep-research

A research CLI that sends questions to Exa Deep Search. It writes a findings report with source links and saves the provider response beside it.

## Features

- Produce research reports from a question.
- Select lite, standard or full research.
- Check report structure and saved-response metadata.
- Return the provider response as JSON.

## Install

```bash
kendex add vanillagreencom/kendex --skill deep-research
```

## How it works

You give the CLI a question and a research mode. It sends the request to Exa. It writes the findings to markdown and saves the response in a JSON file. The validation command checks the report's structure and the saved response's metadata. It does not verify the findings against their sources.

## Setup

Requires Node 18 or newer and `EXA_API_KEY`.

- Set the key in the kendex app, on this package's Customize tab. The app writes it to the project's private env file: `.env.local`, unless `KENDEX_ENV_FILE` names another.
- Or set the key by hand in that file.
- Keep the key out of committed configuration.
- The value may be a 1Password `op://vault/item/field` reference when the `op` CLI is installed and signed in.
- Or keep the key in the computer's private key file: set `KENDEX_KEY_FILE` in your user environment to the file's absolute path. The file holds literal `KEY=value` lines.
  - The CLI reads the file's `EXA_API_KEY` line only when the environment and the project's private env file hold no key.
  - The CLI keeps the key to itself and passes it to no process it starts.
  - A project file cannot name the key file.
- Check the setup from the project root: `.agents/skills/deep-research/scripts/deep-research doctor` prints `"exaApiKey":true` when the environment or the project's private env file holds a key. It does not read the key file.

Domain, date, result-count and context flags are per call. `.agents/skills/deep-research/scripts/deep-research help` lists them.

## Licence

MIT, in the repository's LICENSE file.
