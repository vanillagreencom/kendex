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
export const DEPENDENCY_AMBIGUOUS_NOTE =
  "this marketplace offers it more than once — nothing to choose between them";
