// Marketplaces copy: the Subscribed tab's read states and Home's tile
// detail — kept apart from the rest so the wording is reviewed in one
// place. A read that failed is said and retried where it failed; rows
// kept from a better read are drawn, never presented as current.
export const MARKETPLACES_UNCHECKED_DETAIL = "couldn't be checked";
export const MARKETPLACES_CHECK_FAILED_TITLE =
  "Couldn't check your marketplaces";
export const MARKETPLACES_EMPTY_TITLE = "No marketplaces yet";
export const MARKETPLACES_UNCONFIRMED_TITLE =
  "These are the last subscriptions kendex could check";

/** A row in a project whose lock kendex cannot read. What the source
 * offers is still listed — that is a fact about the source — but the row
 * says nothing about what is installed, because the record that would
 * answer could not be read. */
export const PACKAGE_STATE_UNKNOWN = "Not known";

/** One project whose records could not be read, named once however many
 * marketplaces it subscribes to. The Problems page carries the reason and
 * the way out, so the line sends the reader there rather than repeating a
 * shortened version of it. */
export const unreadableRecordsLine = (project: string): string =>
  `kendex can't read ${project}'s records, so its rows don't say what's installed.`;

/** One project whose marketplaces themselves could not be read. Their
 * packages are missing from the table, which is what the reader needs to
 * know before trusting an empty result. */
export const unreadableSourcesLine = (project: string): string =>
  `kendex couldn't read some of ${project}'s marketplaces, so their packages aren't listed.`;

export const SEE_PROBLEMS_LABEL = "See Problems";
