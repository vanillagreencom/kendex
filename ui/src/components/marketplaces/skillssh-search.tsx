import { Search } from "lucide-react";
import { useEffect, useState } from "react";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { type SkillsShMode, useCommunityStore } from "@/stores/community";

const CHIP_VIEWS: { view: Exclude<SkillsShMode, "search">; label: string }[] = [
  { view: "trending", label: "Trending" },
  { view: "hot", label: "Hot" },
  { view: "all-time", label: "Top" },
];

/** Search skills.sh's whole index directly — public API, no account, only
 * skills.sh sees the query. Trending / Hot / Top come through the
 * kendex.ai proxy and hide when it is not there. Install hands the
 * skill's URL to the Subscribe dialog: the repository is subscribed and
 * the skill opens for install, bound to what kendex's own discovery
 * finds there. */
export function SkillsShSearch({
  onOpen,
  onInstall,
}: {
  /** Open the repository a hit lives in, to browse before installing. */
  onOpen: (repo: string) => void;
  onInstall: (url: string) => void;
}) {
  const hits = useCommunityStore((s) => s.skillsshHits);
  const mode = useCommunityStore((s) => s.skillsshMode);
  const chips = useCommunityStore((s) => s.skillsshChips);
  const searching = useCommunityStore((s) => s.skillsshSearching);
  const error = useCommunityStore((s) => s.skillsshError);
  const search = useCommunityStore((s) => s.searchSkillssh);
  const loadLeaderboard = useCommunityStore((s) => s.loadLeaderboard);
  const [query, setQuery] = useState("");

  // Opening the sub-tab shows what is moving rather than an empty box;
  // if the proxy is missing this collapses to search-only.
  useEffect(() => {
    if (chips && hits === null && !searching) void loadLeaderboard("trending");
  }, [chips, hits, searching, loadLeaderboard]);

  return (
    <div className="space-y-4">
      <div className="flex max-w-2xl items-center gap-2">
        <form
          className="flex flex-1 items-center gap-2"
          onSubmit={(e) => {
            e.preventDefault();
            void search(query);
          }}
        >
          <Input
            placeholder="Search skills.sh"
            value={query}
            onChange={(e) => setQuery(e.target.value)}
          />
          <Button type="submit" variant="outline" disabled={searching}>
            <Search className="size-4" />
            {searching ? "Searching…" : "Search"}
          </Button>
        </form>
        {chips ? (
          <div className="flex items-center gap-1">
            {CHIP_VIEWS.map(({ view, label }) => (
              <Button
                key={view}
                size="sm"
                variant={mode === view ? "secondary" : "ghost"}
                disabled={searching}
                onClick={() => void loadLeaderboard(view)}
              >
                {label}
              </Button>
            ))}
          </div>
        ) : null}
      </div>

      {error ? (
        <p className="text-sm text-critical" role="alert">
          {error}
        </p>
      ) : hits === null ? (
        <p className="text-sm text-muted-foreground">
          Search the skills.sh index — installing brings the skill in the kendex
          way: subscribed, locked and safety-checked.
        </p>
      ) : hits.length === 0 ? (
        <p className="text-sm text-muted-foreground">
          {mode === "search"
            ? "Nothing on skills.sh matches this search."
            : "The leaderboard came back empty."}
        </p>
      ) : (
        <div className="divide-y rounded-lg border">
          {hits.map((hit) => (
            <div
              key={`${hit.repo}/${hit.skill}`}
              className="flex items-center gap-3 px-4 py-3"
            >
              <button
                type="button"
                className="min-w-0 flex-1 cursor-pointer text-left"
                onClick={() => onOpen(hit.repo)}
              >
                <p className="truncate text-sm font-medium">{hit.skill}</p>
                <p className="truncate font-mono text-xs text-muted-foreground">
                  {hit.repo}
                </p>
              </button>
              <span className="shrink-0 text-xs text-muted-foreground">
                {installsLabel(hit.installs)} installs
              </span>
              <Button
                size="sm"
                variant="outline"
                onClick={() =>
                  onInstall(`https://skills.sh/${hit.repo}/${hit.skill}`)
                }
              >
                Install
              </Button>
            </div>
          ))}
        </div>
      )}
      <p className="text-xs text-muted-foreground">
        Search goes straight to skills.sh; installs through kendex do not count
        on their leaderboard.
      </p>
    </div>
  );
}

function installsLabel(installs: number): string {
  if (installs >= 1_000_000) return `${(installs / 1_000_000).toFixed(1)}M`;
  if (installs >= 1_000) return `${Math.round(installs / 1_000)}k`;
  return String(installs);
}
