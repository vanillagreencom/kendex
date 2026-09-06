// A `kendex://` link from the website's "Open in app" button, followed to
// the page it names. The backend parsed it; what is left is the same move
// a click in the Community tab makes, so a marketplace nobody subscribes to
// opens as a repository, Subscribe offered, and a package opens on that
// repository's package page. A link the backend refused lands on the
// marketplace list with the refusal said, never nowhere.
import { toast } from "sonner";
import { commands, type DeepLink, events } from "@/bindings";
import { deepLinkLostToast } from "@/lib/copy-marketplaces";
import { caught } from "@/lib/settled";
import { useNavStore } from "@/stores/nav";

/** Take the app where one link points. */
export function follow(link: DeepLink): void {
  const nav = useNavStore.getState();
  switch (link.open) {
    case "marketplace":
      nav.goToMarketplace({ by: "repo", repo: link.repo });
      return;
    case "package":
      nav.goToAvailablePackage({
        catalog: { by: "repo", repo: link.repo },
        kind: link.kind,
        name: link.name,
      });
      return;
    case "refused":
      nav.goToMarketplaces();
      toast.error(link.reason);
      return;
  }
  const unfollowed: never = link;
  throw new Error(`a deep link shape nothing follows: ${String(unfollowed)}`);
}

/** Start receiving links: listen, then ask for the one that launched the
 *  app. In that order, because asking is what switches the backend from
 *  holding links to emitting them — a link arriving between the two would
 *  otherwise be emitted at nobody. Answers with the way to stop listening. */
export async function receiveDeepLinks(): Promise<() => void> {
  const unlisten = await events.deepLinkOpened.listen((event) =>
    follow(event.payload),
  );
  // Asked twice at most: the ask is what switches the backend to
  // emitting, so one lost in transport would leave every later link held
  // for nobody. A second failure is said where the person is looking,
  // since the link that launched the app is the one they are waiting on.
  let launched = await caught(commands.deepLinkTake());
  if (launched.status === "error")
    launched = await caught(commands.deepLinkTake());
  if (launched.status === "error") {
    toast.error(deepLinkLostToast(launched.error));
  } else if (launched.data) {
    follow(launched.data);
  }
  return unlisten;
}
