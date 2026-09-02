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

// A package's declared dependencies, on the two surfaces that show them
// before an install: the package page's facts column and the install
// picker. "Requires" installs whatever the person does; "Optional" is
// theirs to tick, and starts off.
export const REQUIRES_HEADING = "Requires";
export const OPTIONAL_HEADING = "Optional";
export const REQUIRES_NOTE = "Installed with this package.";
export const OPTIONAL_NOTE = "Installed only if you tick it.";
export const DEPENDENCY_INSTALLED_NOTE = "already installed";
export const DEPENDENCY_NOT_OFFERED_NOTE = "not offered here";
export const DEPENDENCY_REMOVED_NOTE =
  "you removed it — add it back to restore it";
/** The landing scope's lock could not be read, so whether this dependency
 * is already there is not known — and neither is whether an install would
 * be refused on that same record. */
export const DEPENDENCY_UNKNOWN_NOTE =
  "not known here — this place's records can't be read";
export const DEPENDENCY_AMBIGUOUS_NOTE =
  "this marketplace offers it more than once — nothing to choose between them";
/** A row in a place whose lock kendex cannot read. What the source
 * offers is still listed — that is a fact about the source — but the row
 * says nothing about what is installed, because the record that would
 * answer could not be read. */
export const PACKAGE_STATE_UNKNOWN = "Not known";

/** One place whose records could not be read, named once however many
 * marketplaces it subscribes to. The Problems page carries the reason and
 * the way out, so the line sends the reader there rather than repeating a
 * shortened version of it. The name is a place, not a project: the
 * personal scope has a lock of its own and reads as "Personal" here. */
export const unreadableRecordsLine = (place: string): string =>
  `kendex can't read ${place}'s records, so its rows don't say what's installed.`;

/** One place whose marketplaces themselves could not be read. Their
 * packages are missing from the table, which is what the reader needs to
 * know before trusting an empty result. */
export const unreadableSourcesLine = (place: string): string =>
  `kendex couldn't read some of ${place}'s marketplaces, so their packages aren't listed.`;

export const SEE_PROBLEMS_LABEL = "See Problems";
