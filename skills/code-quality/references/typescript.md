# TypeScript and JavaScript

- Represent exclusive cases as discriminated unions. Switch exhaustively with a `never` default in TypeScript instead of strings or booleans that encode cases.
- Distinguish a missing value from a present but falsy value, including an empty string or zero, at every guard.
- Do not use `any` at module boundaries.
