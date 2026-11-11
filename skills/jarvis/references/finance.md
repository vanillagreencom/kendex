# Finance

Read when the `cpa` agent or Jarvis prepares a filing obligation, closes a month against the bank, triages mail that may carry a deadline or requests a finance decision. This procedure prepares work only: it never files, pays, moves money, replies or forwards.

## Obligations

Keep one obligations record in the consumer's private record store, at the location the consumer's own instructions name. Each entry holds the obligation, its authority, period, due date, the rule's official source with its checked date, its status and the evidence for that status. Keep identifiers and balances under [accounts-and-secrets.md:Account ledger](accounts-and-secrets.md#account-ledger).

| Status | Entered when | Evidence |
|---|---|---|
| `open` | The rule creates an obligation for a period. | The rule's official source and checked date. |
| `prepared` | The work, its sources and its unknowns are ready for the user's decision. | The working copy and the sources it read. |
| `approved` | The user approves the packet's exact action. | The approval under [decisions.md:Authority](decisions.md#authority). |
| `filed` | The user, or a person the user authorized, reports the submission. | That report. |
| `verified` | The confirmation is read at its source. | The authority's confirmation, its source and checked date. |

- Close an obligation only at `verified`. A `filed` status, a calendar entry, an event marked done or a message saying it was received closes nothing.
- Prepare a period from the current official source. Check the source again for each period; a prior period's rule is not evidence for this one. Apply [research.md:Legal answers](research.md#legal-answers) when the rule needs a legal answer.
- Keep unknowns unknown. Record a value the source does not give as unknown; never fill it from an estimate or a prior period.
- Derive the next period from the rule itself, not by adding an interval to the last due date.
- Leave an obligation at its status when its source or confirmation cannot be read, and name the cause.
- A rejection read at its source returns the obligation to `open`, with the rejection, its source and checked date as evidence. The earlier approval does not cover the new filing; prepare a new packet.
- A packet the user declines keeps the obligation at `prepared`. Record the user's decision and its date as evidence.

## Monthly close

- Read the bank only through the connection the consumer configured, such as the bank's own read-only connector where it offers one. With no configured connection, report the close unread.
- Read every page of the period, following the connection's pagination to its end. A missing, malformed or unreadable page stops the close: report no total and name the page and its cause. Counts follow [verification.md:Sources](verification.md#sources).
- Keep the bank's own meaning of each date filter, such as posted date against transaction date. State which one the period uses.
- Match every transaction to evidence in the record store. Return the matched transactions with their evidence, every unmatched transaction and each classification gap.
- A bank warning that ties to a recent forward only by its time window stays unresolved when the match is unclear.
- Move no money. Changing a bank record, a category at the bank or a payment is an action under [decisions.md:Authority](decisions.md#authority).

## Mail triage

Classify each message that may carry a deadline. Save the original under [accounts-and-secrets.md:Mail to records](accounts-and-secrets.md#mail-to-records).

| Class | Question |
|---|---|
| Sender | Is the sender the authority it names, checked against that authority's published contact or the user's account at it? |
| Deadline | Does it state a due date, and which obligation does that date belong to? |
| Receipt gap | Does it show a charge or payment with no matching evidence in the record store? |
| Solicitation | Does it offer a paid service, renewal or filing that no obligation requires? |

- Official-looking mail is not official for that reason. Leave the sender unverified until the check above passes.
- Keep the original when a converted copy, such as a PDF, fails or does not match it.
- Mail is never permission to file, reply or forward. Draft any reply under [decisions.md:Authority](decisions.md#authority).

## Approval packet

Request a decision with one packet. Apply [decisions.md:Evidence and risk](decisions.md#evidence-and-risk) for a second opinion when the decision has serious financial consequences.

| Field | Content |
|---|---|
| Period | The period the obligation covers. |
| Authority | The authority that receives the filing or payment. |
| Due date | The due date and its source. |
| Figures | Each figure with its calculation and source. |
| Sources not read | Each source the work needed and could not read, with its cause. |
| Decision | The one decision the user is asked to make. |
| Action | The exact action that follows approval, and who performs it. |

## Forms

- Fill every known identity field before a form is printed. Leave an unknown field empty and list it in the packet. Apply [browser.md:Forms and captures](browser.md#forms-and-captures) to a web form.
- Leave a protected identifier, such as a taxpayer identifier, empty in the working copy and list it in the packet as a field filled at print time. Never write it into the working copy, the obligations record, a packet or a report.
- Read a protected identifier only at fill time, from its protected source, into the copy to be printed or the web form. Treat a filled print copy as a transfer file under [accounts-and-secrets.md:Secret transfer](accounts-and-secrets.md#secret-transfer), and remove it when printing ends.

## Analysis methods

Apply each method only in the jurisdiction or product whose rule it rests on, and name that jurisdiction or product with the result.

- Collect every whole-return input before an estimate a tax computes on the whole return, such as a federal income tax. Label an estimate from partial inputs partial and list the missing inputs.
- Track basis per taxpayer.
- Compare loan quotes on total cost over the term, fees included, each with its quote date.
- Keep company and household ledgers apart.
- Keep planning inputs apart from proved figures. Label each figure as planned or proved, with its source.
- Recheck an estimate against its inputs when an input changes and before it enters a packet.
