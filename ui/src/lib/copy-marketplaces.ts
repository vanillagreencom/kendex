import type { Scope } from "@/bindings";
import { CHECK_FOR_UPDATES_LABEL } from "@/lib/copy";
import { listed } from "@/lib/listed";
import { placeWord } from "@/lib/place-word";
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
  "you removed it, so installing this package leaves it out";
/** The landing scope's lock could not be read, so whether this dependency
 * is already there is not known — and neither is whether an install would
 * be refused on that same record. */
export const DEPENDENCY_UNKNOWN_NOTE =
  "not known: kendex can't read this place's install record";
export const DEPENDENCY_AMBIGUOUS_NOTE =
  "this marketplace offers it more than once, so kendex cannot pick one";
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
  `kendex can't read ${place}'s install record, so these rows can't say what is installed there.`;

/** One place whose marketplaces themselves could not be read. Their
 * packages are missing from the table, which is what the reader needs to
 * know before trusting an empty result. */
export const unreadableSourcesLine = (place: string): string =>
  `kendex couldn't read some of ${place}'s marketplaces, so their packages aren't listed.`;

/** One place subscribed to a marketplace nothing has downloaded yet. Its
 * packages are missing from the table for the same reason the marketplace's
 * own page says with [MARKETPLACE_NOT_DOWNLOADED]: not a failure, and the
 * page's header carries the one control that fills it. */
export const notDownloadedSourcesLine = (place: string): string =>
  `Some of ${place}'s marketplaces haven't been downloaded yet, so their packages aren't listed. ${CHECK_FOR_UPDATES_LABEL} to download them.`;

/** One place a write cannot land in, said by [RecordsUnreadableWriteNote]
 * where a subscription's place is being chosen. Subscribing plans against
 * the chosen place's lock, so a record this build can't read refuses the
 * subscription outright. */
export const unreadableRecordsWriteLine = (place: string): string =>
  `kendex can't read ${place}'s install record, so it can't add a marketplace there.`;

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
  "Subscribing adds this marketplace to one place on this computer. You can then install its packages there. Updates to the packages you install appear on the Updates page.";
// Installing from a marketplace nobody subscribes to yet. The subscription
// is the thing that makes an install possible, so the click that installs
// makes it — said before the click, not discovered after it. The place it
// subscribes into is named: the button is a control in a list, and a
// control in a list names its target.
export const SUBSCRIBE_TO_INSTALL_MEANS =
  "Installing from here first subscribes your personal setup to this marketplace. kendex installs only from marketplaces you subscribe to.";
export const SUBSCRIBE_TO_INSTALL_LABEL = "Subscribe and install";

// The About tab's source details: which places subscribe to this
// marketplace, under which alias, and where its bytes come from. The heading
// names the section once — the panel does not repeat it, and what the panel
// says about the model is in copy-model.ts. Places, not projects: the list
// holds the personal setup beside every project, and a heading naming a kind
// of place its own list contradicts is the defect `place-word.ts` exists to
// stop.
export const MARKETPLACE_PLACES_TITLE = "Places that use it";

/** A subscription nothing has downloaded yet, on the tab that would have
 * listed its content. Not a failure: the declaration is there and its
 * mirror is empty, reading again answers the same, and the page's own
 * header carries the one control that fills it. Every tab that would have
 * listed content says this same line, so none of them describes the state
 * of the marketplace differently. */
export const MARKETPLACE_NOT_DOWNLOADED = `This marketplace hasn't been downloaded yet. ${CHECK_FOR_UPDATES_LABEL} to download it.`;

/** The Packages tab with a read that landed and no rows. Its neighbour
 * above takes the never-downloaded case, so a marketplace this reaches has
 * been read and offers nothing; naming a missing download here would state
 * a cause this branch can no longer be reached by. */
export const MARKETPLACE_OFFERS_NO_PACKAGES =
  "This marketplace offers no packages.";

/** The Packages tab with its read still out. Its slot being empty is not
 * the catalog offering nothing: only a read that has landed can say that,
 * and the sibling Bundles tab says the same of its own. */
export const MARKETPLACE_READING_PACKAGES = "Reading its packages…";

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
export const SOURCE_ALIAS_LABEL = "Short name";

/** Where a package or curated set is installed, counted, as the one control
 *  that opens those places. The word comes from the places themselves —
 *  `place-word.ts`, the rule the package page's customization mark already
 *  counts by — so a set holding the personal setup is never counted as
 *  projects. The menu behind the click names each place, Personal included.
 */
export const installedInCount = (scopes: Scope[]): string =>
  `${scopes.length} ${placeWord(scopes)}`;
export const installedInLabel = (scopes: Scope[]): string =>
  `Installed in ${installedInCount(scopes)}`;
/** The column head over [installedInCount] in the packages table, where the
 *  head carries the verb and the cell carries the count. */
export const INSTALLED_IN_HEADING = "Installed in";

/** How many places a marketplace is subscribed in, for its card. */
export const placeCountLabel = (count: number): string =>
  count === 1 ? "In 1 place" : `In ${count} places`;
/** The places past the card's named ones, counted inside its line of names. */
export const andMorePlacesLabel = (count: number): string =>
  `and ${count} more`;

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
export const DIRECTORY_KENDEX_LABEL = "kendex.ai";
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
export const ABOUT_FINDINGS_TITLE = "Setup problems in this marketplace";
// A catalog with nothing in any of the tab's three parts, which is the
// `empty` guard in about-section.tsx term for term: no description, no
// profile row at all (no author, no license, no homepage, no history to
// date it by, nothing counted), and nothing wrong with its own
// configuration — findings get their own section rather than this line.
// The tab has read it and has nothing to show. The source's own details
// are not part of it: they are this machine's declaration, not a claim the
// catalog makes.
export const ABOUT_NOTHING_SAID =
  "This marketplace gives no description or details.";

/** What a catalog holds, as one line. The joining is the app's one list
 *  rule; all this adds is that a catalog with nothing counted has no line
 *  at all, so the row is left out rather than reading "nothing". */
export const catalogContents = (counts: string[]): string | null =>
  counts.length === 0 ? null : listed(counts);

/** The Marketplaces header's way to the Mine tab, where a marketplace is
 *  created. It switches tab and opens no dialog, so it has no ellipsis. */
export const CREATE_LABEL = "Create";

/** A marketplace read that failed on the About tab, with the engine's
 *  reason. */
export const marketplaceUnreadableLine = (reason: string): string =>
  `kendex can't read this marketplace right now — ${reason}`;
export const READING_MARKETPLACE = "Reading this marketplace…";
/** A repository nobody subscribes to, while its first download is out. */
export const reachingLabel = (repo: string): string => `Reaching ${repo}…`;

// The Bundles tab, one bundle's own page, and the bundles a package is in.
export const bundlesUnreadableLine = (reason: string): string =>
  `kendex can't read this marketplace's bundles right now — ${reason}`;
export const READING_BUNDLES = "Reading its bundles…";
export const NO_BUNDLES =
  "This marketplace offers no bundles. Install its packages one at a time from the Packages tab.";
export const bundleUnreadableLine = (reason: string): string =>
  `kendex can't read this bundle right now — ${reason}`;
export const READING_BUNDLE = "Reading this bundle…";
export const IN_BUNDLES_HEADING = "In bundles";

/** An available package whose read failed, with the engine's reason. */
export const packageUnreadableLine = (reason: string): string =>
  `kendex can't read this package right now — ${reason}`;
/** The place already lists or installs a package of the same name from
 *  somewhere else, and the engine refuses to install over it. */
export const nameTakenLine = (marketplace: string): string =>
  `A package with this name is already listed or installed in this place. kendex will refuse to install it from ${marketplace}.`;

// The Subscribed tab and its cards.
export const SUBSCRIBE_TO_A_MARKETPLACE_LABEL = "Subscribe to a marketplace";
export const MARKETPLACES_EMPTY_BODY =
  "A marketplace is a repository of packages, such as skills and agents. Subscribe to one to install its packages.";
/** A marketplace switched off in some of the places that subscribe to it. */
export const switchedOffInLabel = (places: Scope[]): string =>
  `Switched off in ${places.length} ${placeWord(places)}`;
export const NOT_DOWNLOADED_LABEL = "Not downloaded yet";

// The Subscribe dialog. The name field is the short name the chosen place
// keys the subscription under; the marketplace's title comes from its own
// catalogue, so the short name shows only in the marketplace's details.
export const SUBSCRIBE_REFERENCE_HELP =
  "Enter a GitHub repository, a git URL, a skills.sh link or a folder path. Any repository that holds skills works.";
export const SHORT_NAME_FIELD_LABEL = "Short name (optional)";
export const SHORT_NAME_PLACEHOLDER = "shown in the marketplace's details";
export const SUBSCRIBE_PLACE_LABEL = "Place";

/** A browsed repository whose subscription is switched off. */
export const SWITCH_ON_LABEL = "Switch on";
export const switchOnInLabel = (place: string): string =>
  `Switch on in ${place}`;

// The Unsubscribe dialog.
export const unsubscribeTitle = (marketplace: string): string =>
  `Unsubscribe from ${marketplace}?`;
export const installedFromItLine = (parts: string, place: string): string =>
  `Installed in ${place} from this marketplace: ${parts}.`;
export const nothingInstalledFromItLine = (place: string): string =>
  `Nothing from this marketplace is installed in ${place}. Unsubscribing only removes the subscription.`;
export const unsubscribeRemoveDetail = (count: number, place: string): string =>
  `Remove ${count} package${count === 1 ? "" : "s"} from ${place}.`;
export const UNSUBSCRIBE_KEEP_TITLE = "Keep them as your own copies";
export const UNSUBSCRIBE_KEEP_DETAIL =
  "They stay installed, and updates from this marketplace stop. My Library lists them under Your own.";
export const editedOnDiskLine = (packages: string): string =>
  `Files edited on disk: ${packages}.`;
export const UNSUBSCRIBE_EDITED_NEXT =
  "Before you unsubscribe, keep each edited package as your own copy or discard its edits. Open it in My Library to choose.";

// The Community tab's two directories.
export const DIRECTORY_CHECK_AGAIN_LABEL = "Check kendex.ai again";
export const SKILLSSH_INTRO =
  "Search the skills.sh index. Install opens Subscribe for the skill's repository. You then install the skill from that marketplace.";
export const SKILLSSH_LIST_EMPTY = "This skills.sh list is empty.";
export const SKILLSSH_NOTE =
  "Your search goes to skills.sh directly. Installs through kendex don't count on the skills.sh leaderboard.";

// The Mine tab: marketplaces the reader authors, submits and imports into.
export const MINE_EMPTY_TITLE = "No marketplaces of your own yet";
export const CHECK_PASSES_BADGE = "Check passes";
export const NO_PACKAGES_FOUND = "no packages found";
export const MINE_FOLDER_LABEL = "Folder";
export const DELISTED_LINE = "Removed from the community directory";
export const SUBMIT_TO_COMMUNITY_LABEL = "Submit to the community…";
export const SUBMIT_HELP =
  "kendex.ai checks that you can push to the repository, reads its packages and lists it for anyone to subscribe to.";
export const SUBMITTED_LISTED = "It is listed in the community directory.";
export const SUBMITTED_IN_REVIEW =
  "It is waiting for review. Its row on Mine shows when it is listed.";
export const IMPORT_HELP =
  "Copies packages from this computer into the marketplace folder. The original files stay where they are, unchanged.";
export const IMPORT_READING = "Finding packages on this computer…";
export const IMPORT_NOTHING =
  "No packages to import. Install or create a package first.";
const licenseOrNone = (license: string | null): string =>
  license ? license : "no license found";
export const fromMarketplaceLabel = (
  source: string,
  license: string | null,
): string => `From marketplace '${source}' · ${licenseOrNone(license)}`;
export const editedCopyFromLabel = (
  source: string,
  license: string | null,
): string =>
  `Edited copy from marketplace '${source}' · ${licenseOrNone(license)}`;
export const republishConfirmLabel = (license: string, what: string): string =>
  `The ${license} license lets me republish ${what}`;
export const unrecognizedLicenseLine = (license: string): string =>
  `'${license}' is not a license kendex recognizes as redistributable.`;
export const noLicenseLine = (source: string): string =>
  `No license was found in marketplace '${source}'.`;
export const LICENSE_BASIS_ASK = "To copy it, say why you may republish it.";
export const licenseBasisLabel = (name: string): string =>
  `License basis for ${name}`;
