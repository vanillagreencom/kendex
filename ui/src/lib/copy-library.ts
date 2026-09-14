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
