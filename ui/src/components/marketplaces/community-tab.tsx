import { Globe, RefreshCw } from "lucide-react";
import { useEffect, useMemo, useState } from "react";
import { EmptyState } from "@/components/empty-state";
import { SubscribeDialog } from "@/components/marketplaces/subscribe-dialog";
import { Segmented } from "@/components/segmented";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import {
  Select,
  SelectContent,
  SelectItem,
  SelectTrigger,
  SelectValue,
} from "@/components/ui/select";
import {
  DIRECTORY_KENDEX_LABEL,
  DIRECTORY_SKILLSSH_LABEL,
} from "@/lib/copy-marketplaces";
import { PAGE_BODY, WIDE_CONTENT_WIDTH } from "@/lib/layout";
import { cn } from "@/lib/utils";
import { useCommunityStore } from "@/stores/community";
import {
  rowSubscribed,
  subscribedKeys,
  useMarketplacesStore,
} from "@/stores/marketplaces";
import { useNavStore } from "@/stores/nav";
import { agoLabel, DirectoryCard, dayOf } from "./directory-card";
import { SkillsShSearch } from "./skillssh-search";

const ANY_TAG = "any";

/** The kendex.ai directory plus Skills.sh. The list is served from the
 * app's cache — offline it stays on screen with its "as of" line, never
 * blank. */
export function CommunityTab() {
  const directory = useCommunityStore((s) => s.directory);
  const loading = useCommunityStore((s) => s.loading);
  const error = useCommunityStore((s) => s.error);
  const skillsshAvailable = useCommunityStore((s) => s.skillsshAvailable);
  const load = useCommunityStore((s) => s.load);
  const goToMarketplaces = useNavStore((s) => s.goToMarketplaces);
  const goToMarketplace = useNavStore((s) => s.goToMarketplace);
  const subscriptions = useMarketplacesStore((s) => s.rows);
  const subscriptionsCurrent = useMarketplacesStore(
    (s) => s.read.status === "landed",
  );

  const [section, setSection] = useState<"directory" | "skillssh">("directory");
  const [query, setQuery] = useState("");
  const [tag, setTag] = useState(ANY_TAG);
  // Keyed remount so a row's reference lands in the dialog's initial state.
  const [subscribeTo, setSubscribeTo] = useState<string | null>(null);

  useEffect(() => {
    void load(false);
  }, [load]);

  const held = useMemo(
    () => (subscriptionsCurrent ? subscribedKeys(subscriptions) : null),
    [subscriptions, subscriptionsCurrent],
  );
  const tags = useMemo(
    () =>
      [...new Set((directory?.rows ?? []).flatMap((row) => row.tags))].sort(),
    [directory],
  );
  const rows = useMemo(() => {
    const needle = query.trim().toLowerCase();
    return (
      (directory?.rows ?? [])
        .filter(
          (row) =>
            (tag === ANY_TAG || row.tags.includes(tag)) &&
            (!needle ||
              row.name.toLowerCase().includes(needle) ||
              row.repo.toLowerCase().includes(needle) ||
              (row.description ?? "").toLowerCase().includes(needle)),
        )
        // Featured first, then by name. A popularity order is what this grid
        // wants — the index the app fetches carries no installs, stars or
        // per-marketplace timestamp, so there is nothing here to sort by that
        // would not be made up.
        .sort(
          (a, b) =>
            Number(b.featured) - Number(a.featured) ||
            a.name.localeCompare(b.name),
        )
    );
  }, [directory, query, tag]);

  return (
    <div className={cn(PAGE_BODY, "pt-0")}>
      <div className={cn(WIDE_CONTENT_WIDTH, "space-y-4")}>
        {/* Two directories, one chosen — a segmented control, not two
            words that happen to sit beside each other. It is drawn when
            there is a second thing to choose, and whenever Skills.sh is
            what is on screen: the availability check is a round trip to
            kendex.ai that starts out true, so a click inside that window
            would otherwise unmount the only way back to the directory. */}
        {skillsshAvailable || section === "skillssh" ? (
          <Segmented
            label="Where to search"
            value={section}
            onChange={setSection}
            options={[
              { value: "directory", label: DIRECTORY_KENDEX_LABEL },
              { value: "skillssh", label: DIRECTORY_SKILLSSH_LABEL },
            ]}
          />
        ) : null}

        {section === "skillssh" ? (
          <SkillsShSearch
            onOpen={(repo) => goToMarketplace({ by: "repo", repo })}
            onInstall={(url) => setSubscribeTo(url)}
          />
        ) : error && !directory ? (
          <EmptyState icon={Globe} title="kendex.ai is not reachable">
            {error}
            <div className="mt-3">
              <Button size="sm" variant="outline" onClick={() => load(true)}>
                Try again
              </Button>
            </div>
          </EmptyState>
        ) : (
          <>
            <div className="flex items-center gap-2">
              <Input
                className="max-w-xs"
                placeholder="Search marketplaces"
                value={query}
                onChange={(e) => setQuery(e.target.value)}
              />
              {tags.length > 0 ? (
                <Select value={tag} onValueChange={(v) => setTag(v ?? ANY_TAG)}>
                  <SelectTrigger className="w-36">
                    <SelectValue>
                      {(current: string) =>
                        current === ANY_TAG ? "Any tag" : current
                      }
                    </SelectValue>
                  </SelectTrigger>
                  <SelectContent>
                    <SelectItem value={ANY_TAG}>Any tag</SelectItem>
                    {tags.map((t) => (
                      <SelectItem key={t} value={t}>
                        {t}
                      </SelectItem>
                    ))}
                  </SelectContent>
                </Select>
              ) : null}
              <div className="ml-auto flex items-center gap-1 text-xs text-muted-foreground">
                {directory
                  ? directory.stale
                    ? `Shown as of ${dayOf(directory.fetchedAt)} — kendex.ai is not reachable`
                    : `Updated ${agoLabel(directory.fetchedAt)}`
                  : null}
                <Button
                  size="icon-sm"
                  variant="ghost"
                  aria-label="Refresh the directory"
                  disabled={loading}
                  onClick={() => load(true)}
                >
                  <RefreshCw
                    className={cn("size-3.5", loading && "animate-spin")}
                  />
                </Button>
              </div>
            </div>

            {!directory ? (
              <p className="py-8 text-center text-sm text-muted-foreground">
                Reaching kendex.ai…
              </p>
            ) : directory && rows.length === 0 ? (
              <p className="t-desc py-8 text-center text-sm text-muted-foreground">
                {directory.rows.length === 0
                  ? "The directory has no listed marketplaces yet."
                  : "No listed marketplace matches this search."}
              </p>
            ) : (
              <div className="grid gap-3 md:grid-cols-2 2xl:grid-cols-3">
                {rows.map((row) => (
                  <DirectoryCard
                    key={row.repo}
                    row={row}
                    subscribed={rowSubscribed(row, held)}
                    onOpen={() =>
                      goToMarketplace({ by: "repo", repo: row.repo })
                    }
                    onSubscribe={() => setSubscribeTo(row.repo)}
                  />
                ))}
              </div>
            )}
            <p className="text-xs text-muted-foreground">
              Not listed here?{" "}
              <button
                type="button"
                className="underline underline-offset-2 hover:text-foreground"
                onClick={() => goToMarketplaces("mine")}
              >
                Submit your own marketplace
              </button>
            </p>
          </>
        )}
      </div>
      {subscribeTo !== null ? (
        <SubscribeDialog
          key={subscribeTo}
          open
          onOpenChange={(open) => {
            if (!open) setSubscribeTo(null);
          }}
          initialReference={subscribeTo}
        />
      ) : null}
    </div>
  );
}
