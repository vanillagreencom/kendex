import { listed } from "@/lib/listed";
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

/** One place a write cannot land in, said by [RecordsUnreadableWriteNote]
 * where a subscription's place is being chosen. Subscribing plans against
 * the chosen place's lock, so a record this build can't read refuses the
 * subscription outright. */
export const unreadableRecordsWriteLine = (place: string): string =>
  `kendex can't read ${place}'s records, so nothing can be added there yet.`;

export const SEE_PROBLEMS_LABEL = "See Problems";

/** The link that launched the app could not be asked for: the person
 *  clicked something and is waiting for it, so the failure is said where
 *  they are looking. */
export const deepLinkLostToast = (reason: string): string =>
  `The link that opened kendex could not be read: ${reason}`;

// What subscribing does, said wherever Subscribe is offered so nobody has
// to press it to find out. Subscribing writes a source declaration into
// one place's manifest and fetches it; the packages it offers become
// installable there, and the ones actually installed are what the Updates
// page then checks.
export const SUBSCRIBE_MEANS =
  "Subscribing adds this marketplace to one place on this machine. Its packages become installable there, and updates to the ones you install show up on the Updates page.";
// Installing from a marketplace nobody subscribes to yet. The subscription
// is the thing that makes an install possible, so the click that installs
// makes it — said before the click, not discovered after it. The place it
// subscribes into is named: the button is a control in a list, and a
// control in a list names its target.
export const SUBSCRIBE_TO_INSTALL_MEANS =
  "Installing from here subscribes you personally to this marketplace first — that is what makes its packages installable.";
export const SUBSCRIBE_TO_INSTALL_LABEL = "Subscribe and install";

// The About tab's source details: which places subscribe to this
// marketplace, under which alias, and where its bytes come from. The heading
// names the section once — the panel does not repeat it, and what the panel
// says about the model is in copy-model.ts.
export const MARKETPLACE_PLACES_TITLE = "Projects that use it";

// How a marketplace names itself and where it comes from. A folder on this
// machine says so beside its path: a working checkout and the remote
// catalogue it was cloned from declare the same name, and without this the
// two cards read as one marketplace listed twice.
export const LOCAL_FOLDER_LABEL = "Local folder";
/** A declaration naming neither a repository nor a folder, whose alias
 *  spells no name either. Nothing has been read and nothing was written
 *  down, so the card says that rather than showing a bare `.`. */
export const UNNAMED_MARKETPLACE = "Unnamed marketplace";
export const SOURCE_LOCATION_LABEL = "Comes from";
/** The alias one place's manifest keys this source under — what
 *  `kendex marketplace` addresses it by, and what an unsubscribe names. It
 *  is a per-place key rather than the marketplace's name, so it is stated
 *  here and never used as a title. */
export const SOURCE_ALIAS_LABEL = "Source name";

/** How many places a package or curated set is installed in, as the one
 *  control that opens them. Personal is listed on Projects beside every
 *  project, so it counts as one of them; the list behind the click names
 *  each one. */
export const projectCountLabel = (count: number): string =>
  count === 1 ? "1 project" : `${count} projects`;
export const installedInLabel = (count: number): string =>
  `Installed in ${projectCountLabel(count)}`;
/** The column head over [projectCountLabel] in the packages table, where the
 *  head carries the verb and the cell carries the count. */
export const INSTALLED_IN_HEADING = "Installed in";

/** How many places a marketplace is subscribed in, for its card. */
export const placeCountLabel = (count: number): string =>
  count === 1 ? "In 1 place" : `In ${count} places`;

/** A listed marketplace's counts, as metadata rather than prose. */
export const directoryCountsLabel = (
  packages: number,
  bundles: number,
): string =>
  bundles > 0
    ? `${packages} package${packages === 1 ? "" : "s"} · ${bundles} bundle${bundles === 1 ? "" : "s"}`
    : `${packages} package${packages === 1 ? "" : "s"}`;

export const SUBSCRIBED_MARKER = "Subscribed";
export const FEATURED_MARKER = "Featured";
// The two directories the Community tab searches, named as the segmented
// control's two choices.
export const DIRECTORY_KENDEX_LABEL = "Kendex";
export const DIRECTORY_SKILLSSH_LABEL = "Skills.sh";

// The About tab's profile of one marketplace. Every line is the catalog's
// own claim about itself or a fact about its repository — never a word
// about how kendex read it, which is the catalog author's problem and not
// something a person choosing a marketplace has any use for.
export const ABOUT_AUTHOR_LABEL = "Author";
export const ABOUT_LICENSE_LABEL = "License";
export const ABOUT_HOMEPAGE_LABEL = "Homepage";
export const ABOUT_UPDATED_LABEL = "Last updated";
export const ABOUT_CONTAINS_LABEL = "Contains";
// The heading over what the catalog's own configuration gets wrong. Absent
// with nothing to list: a section that appears only to say it is empty is
// a line about kendex's reading, not about the marketplace.
export const ABOUT_FINDINGS_TITLE = "Things the catalog gets wrong";
// A catalog with nothing in any of the tab's three parts, which is the
// `empty` guard in about-section.tsx term for term: no description, no
// profile row at all (no author, no license, no homepage, no history to
// date it by, nothing counted), and nothing wrong with its own
// configuration — findings get their own section rather than this line.
// The tab has read it and has nothing to show. The source's own details
// are not part of it: they are this machine's declaration, not a claim the
// catalog makes.
export const ABOUT_NOTHING_SAID = "This marketplace says nothing about itself.";

/** What a catalog holds, as one line. The joining is the app's one list
 *  rule; all this adds is that a catalog with nothing counted has no line
 *  at all, so the row is left out rather than reading "nothing". */
export const catalogContents = (counts: string[]): string | null =>
  counts.length === 0 ? null : listed(counts);
