// Library copy: the Installed table's filter strip and row cells, and the
// Details block of the package page a row opens. Kept apart from the
// update and file words so one surface's strings are read side by side.

export const SEARCH_PACKAGES_LABEL = "Search installed packages";
/** The From picker with nothing chosen. Its choices are marketplaces,
 *  "Your own" and "Not managed", so the empty state names none of them. */
export const FROM_ANYWHERE = "From anywhere";
export const packagesCountLabel = (count: number): string =>
  count === 1 ? "1 package" : `${count} packages`;

export const PLACE_ROW_LABEL = "Place";
/** The marketplace commit kendex installed this package from. It can
 *  differ from the package's own version, which the Version menu marks:
 *  a marketplace moves on while one package's files stay the same. */
export const MARKETPLACE_VERSION_ROW_LABEL = "Marketplace version";
export const REPOSITORY_ROW_LABEL = "Repository";
export const REPOSITORY_NONE = "None. Managed from this computer";

/** The row naming the harnesses a package runs on, in the words of the
 *  `supported tools:` line `kendex show` prints. Shared by the installed
 *  package's Details and the available package's facts column. */
export const SUPPORTED_HARNESSES_LABEL = "Supported harnesses";
export const SUPPORTED_ALL = "All";
export const SUPPORTED_NONE = "None";
export const SUPPORTED_ALL_EXCEPT = "All except";
/** Harnesses that run no hooks, so a hook there is advice the model may
 *  ignore: neither supported outright nor unsupported. */
export const SUPPORTED_ADVISORY_ON = "Advisory on";
/** Harnesses that run the hook while a fallback there does its job. */
export const SUPPORTED_FALLBACK_ON = "Fallback on";
/** An installed hook whose header core could not read: its cause follows. */
export const SUPPORTED_UNKNOWN = "Unknown";
