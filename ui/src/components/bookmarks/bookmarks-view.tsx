import { Bookmark as BookmarkIcon } from "lucide-react";
import { useEffect, useMemo, useRef, useState } from "react";
import type { ItemKind, SavedItem } from "@/bindings";
import { AddToTemplateDialog } from "@/components/templates/add-to-template-dialog";
import { Button } from "@/components/ui/button";
import { Card } from "@/components/ui/card";
import { Checkbox } from "@/components/ui/checkbox";
import { Input } from "@/components/ui/input";
import { memberOf } from "@/lib/bookmark-target";
import { TRY_AGAIN_LABEL } from "@/lib/copy";
import {
  BOOKMARKS_EMPTY,
  BOOKMARKS_EXPLAINER,
  BOOKMARKS_LAST_KNOWN,
  BOOKMARKS_NONE_MATCH,
  BOOKMARKS_SEARCH,
  BOOKMARKS_UNREADABLE,
  NOT_OFFERED_WORD,
  NOT_SUBSCRIBED_NOTE,
  NOT_SUBSCRIBED_WORD,
  REMOVE_BOOKMARK_ACTION,
  removeBookmarkLabel,
  savedSummary,
  UNAVAILABLE_WORD,
} from "@/lib/copy-bookmarks";
import {
  INSTALL_ACTION,
  installSelectedLabel,
  justThisLabel,
  packageCount,
  selectedLabel,
} from "@/lib/copy-install";
import { ADD_TO_TEMPLATE_LABEL } from "@/lib/copy-templates";
import { groupsOf, type WantedPackage } from "@/lib/install-ask";
import { PAGE_GUTTER, WIDE_CONTENT_WIDTH } from "@/lib/layout";
import { opensLabel, opensOnActivate } from "@/lib/opens-on-activate";
import { cn } from "@/lib/utils";
import { useBookmarksAnswer, useBookmarksStore } from "@/stores/bookmarks";
import { type InstallSubject, useInstallFlow } from "@/stores/install-flow";
import { useNavStore } from "@/stores/nav";

/** The rows an answer with none has, as one value rather than a fresh
 *  array per render. */
const NO_ITEMS: SavedItem[] = [];

/** What tells one saved row from another, for a tick that survives a
 *  re-read: the marketplace it came from, what it is, and its name. */
const rowKey = (item: SavedItem): string =>
  `${item.repoIdentity}::${item.bookmark.item.is === "bundle" ? "bundle" : item.bookmark.item.kind}::${item.bookmark.name}`;

/** Whether this row is one an install may start from. Only a marketplace
 *  this machine can serve and that still offers the item is: every other
 *  standing would send the guided install at content nobody has read, and
 *  core refuses it there too. */
const installable = (item: SavedItem): boolean =>
  item.reach.at === "offered" && item.catalog !== null;

/** What the guided install asks about when the answer is saved rows.
 *
 *  Packages are grouped by `groupsOf`, the one fold every selection goes
 *  through: one request per subscription, told apart by the place declaring
 *  it as well as its alias. A curated set keeps itself whole, so each set
 *  is its own request rather than a member of one: two sets from one
 *  marketplace are two requests. */
function requestsFor(items: SavedItem[]): InstallSubject["groups"] {
  const packages: WantedPackage[] = [];
  const sets: InstallSubject["groups"] = [];
  for (const { bookmark, catalog } of items) {
    if (catalog === null || catalog.by !== "subscription") continue;
    if (bookmark.item.is === "bundle") {
      sets.push({
        source: catalog.source,
        browsing: catalog.scope,
        items: [],
        bundle: bookmark.name,
      });
      continue;
    }
    packages.push({
      catalog,
      item: { kind: bookmark.item.kind, name: bookmark.name },
    });
  }
  return [...groupsOf(packages), ...sets];
}

/** The kinds an answer declares, which decides which tools may take it. A
 *  set declares none: what it holds is the catalog's to say, and naming
 *  the kinds beside it would offer a narrower list of tools than its own
 *  members need. */
const kindsOf = (items: SavedItem[]): ItemKind[] =>
  items.some((item) => item.bookmark.item.is === "bundle")
    ? []
    : [
        ...new Set(
          items.flatMap((item) =>
            item.bookmark.item.is === "package"
              ? [item.bookmark.item.kind]
              : [],
          ),
        ),
      ];

/** "Bookmarks": the saved marketplace items, searchable, one row each.
 *
 *  Personal across projects, so there is no location filter here — the one
 *  narrowing is the search box, which is the one search box this tab has. */
export function BookmarksView() {
  const answer = useBookmarksAnswer();
  const load = useBookmarksStore((s) => s.load);
  const remove = useBookmarksStore((s) => s.remove);
  const busy = useBookmarksStore((s) => s.busy);
  const refused = useBookmarksStore((s) => s.refused);
  const goToAvailablePackage = useNavStore((s) => s.goToAvailablePackage);
  const goToBundle = useNavStore((s) => s.goToBundle);
  const openInstall = useInstallFlow((s) => s.open);
  const [search, setSearch] = useState("");
  const [ticked, setTicked] = useState<ReadonlySet<string>>(new Set());
  const [addingToTemplate, setAddingToTemplate] = useState(false);
  const searchRef = useRef<HTMLInputElement>(null);
  const searchFocus = useNavStore((s) => s.searchFocus);

  useEffect(() => {
    void load();
  }, [load]);

  // The one search box this tab has, on the app's own shortcut. The "/"
  // shortcut fires from any page, so it bumps a counter rather than
  // reaching for a box that may not be mounted when it fires.
  useEffect(() => {
    if (searchFocus === 0) return;
    searchRef.current?.focus();
    searchRef.current?.select();
  }, [searchFocus]);

  // The rows this answer has, which is none for the two states that have
  // none: a wait and a read that failed with nothing behind it draw no
  // list and make no claim about one.
  const held =
    answer.shown === "waiting" || answer.shown === "unreadable"
      ? NO_ITEMS
      : answer.saved;
  const shown = useMemo(() => {
    const wanted = search.trim().toLowerCase();
    if (wanted === "") return held;
    return held.filter(
      (item) =>
        item.bookmark.name.toLowerCase().includes(wanted) ||
        item.bookmark.repo.toLowerCase().includes(wanted),
    );
  }, [held, search]);

  // A tick is an answer about a row that could be installed, read against
  // what the row is NOW rather than stored and left standing: a re-read
  // that finds a marketplace gone would otherwise leave a tick on a row
  // with nothing to install and offer it to the next Install.
  const chosen = useMemo(
    () => shown.filter((item) => installable(item) && ticked.has(rowKey(item))),
    [shown, ticked],
  );

  // Whether this answer has anything to say about what is saved. Neither a
  // wait nor an unreadable index does, so neither the explainer nor any
  // empty state is drawn over one.
  const answered = answer.shown === "read" || answer.shown === "lastKnown";

  const open = (item: SavedItem) => {
    const catalog = item.catalog;
    if (catalog === null) return;
    if (item.bookmark.item.is === "bundle") {
      goToBundle({ catalog, bundle: item.bookmark.name });
      return;
    }
    goToAvailablePackage({
      catalog,
      kind: item.bookmark.item.kind,
      name: item.bookmark.name,
    });
  };

  /** One saved row, or the ticked ones — the same guided install every
   *  other surface opens, which is where the destination and the tools are
   *  asked. */
  const askFor = (only?: SavedItem) => {
    const items = only ? [only] : chosen;
    const groups = requestsFor(items);
    if (groups.length === 0) return;
    openInstall({
      subjects: [
        {
          id: only ? "one" : "ticked",
          label: only
            ? justThisLabel(only.bookmark.name)
            : selectedLabel(items.length),
          what: only ? only.bookmark.name : packageCount(items.length),
          count: items.length,
          groups,
          kinds: kindsOf(items),
        },
      ],
    });
  };

  return (
    <div className={cn("flex min-h-0 flex-1 flex-col gap-4 pb-8", PAGE_GUTTER)}>
      <div className={cn("flex flex-col gap-3", WIDE_CONTENT_WIDTH)}>
        <Input
          ref={searchRef}
          value={search}
          onChange={(event) => setSearch(event.target.value)}
          placeholder={BOOKMARKS_SEARCH}
          aria-label={BOOKMARKS_SEARCH}
          className="max-w-sm"
        />
        {answer.shown === "unreadable" || answer.shown === "lastKnown" ? (
          <div className="flex items-center gap-3">
            <p className="text-[13px] text-muted-foreground">
              {answer.shown === "lastKnown"
                ? BOOKMARKS_LAST_KNOWN
                : BOOKMARKS_UNREADABLE}
            </p>
            <Button size="sm" variant="outline" onClick={() => void load()}>
              {TRY_AGAIN_LABEL}
            </Button>
          </div>
        ) : null}
        {answered ? (
          <p className="text-[13px] text-muted-foreground">
            {BOOKMARKS_EXPLAINER}
          </p>
        ) : null}
        {refused ? (
          <p className="text-[13px] text-critical">{refused}</p>
        ) : null}
      </div>
      <div
        className={cn("flex min-h-0 flex-1 flex-col gap-2", WIDE_CONTENT_WIDTH)}
      >
        {/* The selection's actions. They appear with the selection rather
            than sitting disabled above an untouched list, and Install stays
            primary — saving the selection into a template is the secondary
            action beside it, exactly as it is in a marketplace's table. */}
        {chosen.length > 0 ? (
          <div className="flex items-center justify-end gap-2">
            <Button
              size="sm"
              variant="outline"
              onClick={() => setAddingToTemplate(true)}
            >
              {ADD_TO_TEMPLATE_LABEL}
            </Button>
            <Button size="sm" onClick={() => askFor()}>
              {installSelectedLabel(chosen.length)}
            </Button>
          </div>
        ) : null}
        <AddToTemplateDialog
          saveable={{ members: chosen.map(memberOf), dropped: [] }}
          open={addingToTemplate}
          onOpenChange={setAddingToTemplate}
        />
        {shown.map((item) => (
          <SavedRow
            key={rowKey(item)}
            item={item}
            busy={busy}
            selected={ticked.has(rowKey(item))}
            onToggle={() =>
              setTicked((was) => {
                const next = new Set(was);
                const key = rowKey(item);
                if (next.has(key)) next.delete(key);
                else next.add(key);
                return next;
              })
            }
            onOpen={() => open(item)}
            onInstall={() => askFor(item)}
            onRetry={() => void load()}
            onRemove={() => void remove(item.bookmark)}
          />
        ))}
        {/* An empty state only where the list would otherwise be blank and
            a read has answered: a search that matches nothing is a
            different answer from a person with nothing saved, and a read
            that has not landed is neither. */}
        {answered && shown.length === 0 ? (
          <p className="py-2 text-sm text-muted-foreground">
            {held.length === 0 ? BOOKMARKS_EMPTY : BOOKMARKS_NONE_MATCH}
          </p>
        ) : null}
      </div>
    </div>
  );
}

/** One saved item: what it is, where it came from, where it stands, and
 *  the two things this list can do with it. The whole card opens the
 *  marketplace page the item lives on; every control inside it does its own
 *  thing and leaves the reader here. */
function SavedRow({
  item,
  busy,
  selected,
  onToggle,
  onOpen,
  onInstall,
  onRetry,
  onRemove,
}: {
  item: SavedItem;
  busy: boolean;
  selected: boolean;
  onToggle: () => void;
  onOpen: () => void;
  onInstall: () => void;
  onRetry: () => void;
  onRemove: () => void;
}) {
  const { bookmark, reach } = item;
  const offered = installable(item);
  // A row whose marketplace nothing can address opens nothing: opening
  // some other marketplace's page would be worse than the row sitting
  // still, and the row is kept either way so the bookmark can be read and
  // removed.
  const opens = item.catalog !== null;
  const standing =
    reach.at === "not-offered"
      ? NOT_OFFERED_WORD
      : reach.at === "unavailable"
        ? UNAVAILABLE_WORD
        : reach.at === "unsubscribed"
          ? NOT_SUBSCRIBED_WORD
          : null;
  const why =
    reach.at === "not-offered" || reach.at === "unavailable"
      ? reach.why
      : reach.at === "unsubscribed"
        ? NOT_SUBSCRIBED_NOTE
        : null;

  return (
    <Card
      {...(opens
        ? opensOnActivate(onOpen, opensLabel(bookmark.name))
        : { tabIndex: undefined })}
      className={cn(
        "gap-1 px-4 py-3",
        opens && "cursor-pointer hover:bg-accent/40",
      )}
    >
      <div className="flex items-center gap-3">
        {/* Ticking a row is not opening it: the box draws as a button, and
            `opensOnActivate` reads a control inside the card as having
            answered the click. A row nothing can install carries no box. */}
        <div className="w-5 shrink-0">
          {offered ? (
            <Checkbox
              checked={selected}
              aria-label={`Select ${bookmark.name}`}
              onCheckedChange={onToggle}
            />
          ) : null}
        </div>
        <BookmarkIcon className="size-4 shrink-0 text-muted-foreground" />
        <div className="min-w-0 flex-1">
          {/* What a screen reader is told opens the item. The card opens
              too, but a card announces its content rather than an action,
              so the name stays a real control. */}
          {opens ? (
            <button
              type="button"
              onClick={onOpen}
              className="block max-w-full cursor-pointer truncate text-left text-sm font-medium hover:underline"
            >
              {bookmark.name}
            </button>
          ) : (
            <span className="block max-w-full truncate text-sm font-medium">
              {bookmark.name}
            </span>
          )}
          <p className="truncate text-[13px] text-muted-foreground">
            {savedSummary(bookmark.item, bookmark.repo)}
          </p>
        </div>
        {standing ? (
          <span className="shrink-0 text-xs text-muted-foreground">
            {standing}
          </span>
        ) : null}
        {offered ? (
          <Button
            size="sm"
            variant="outline"
            disabled={busy}
            onClick={onInstall}
          >
            {INSTALL_ACTION}
          </Button>
        ) : (
          <Button size="sm" variant="outline" onClick={onRetry}>
            {TRY_AGAIN_LABEL}
          </Button>
        )}
        {/* Offered on every row, whatever its marketplace says: a
            bookmark a person can no longer act on is one they must still be
            able to let go of. */}
        <Button
          size="sm"
          variant="ghost"
          disabled={busy}
          aria-label={removeBookmarkLabel(bookmark.name)}
          onClick={onRemove}
        >
          {REMOVE_BOOKMARK_ACTION}
        </Button>
      </div>
      {/* Why this row cannot be installed, said on the row rather than
          only in a state word: the reader is the one who has to act on it. */}
      {why ? (
        <p className="pl-8 text-[13px] text-muted-foreground">{why}</p>
      ) : null}
    </Card>
  );
}
