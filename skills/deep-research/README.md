# deep-research

A research CLI that sends questions to Exa Deep Search. It writes a findings report with source links and saves the provider response beside it.

## Install

```bash
kendex add vanillagreencom/kendex --skill deep-research
```

Requires Node 18 or newer and `EXA_API_KEY`. Store the key in `.env.local`. Use `scripts/deep-research doctor` to check the setup.

## Features

- Produce research reports from a question.
- Select lite, standard or full research.
- Validate a report against its saved provider response.
- Return the provider response as JSON.

## How it works

You give the CLI a question and a research mode. It sends the request to Exa. It writes the findings to markdown and saves the response in a JSON file. The validation command checks the report against that saved response.

## Settings

- `EXA_API_KEY`: the only setting; keep it in `.env.local`.
- Domain, date, result-count and context flags are per call, listed by `scripts/deep-research help`.
