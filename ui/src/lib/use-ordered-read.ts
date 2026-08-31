import { useEffect, useRef, useState } from "react";
import { readOrder } from "@/lib/read-state";
import { settled } from "@/lib/settled";

/** How a read of one address stands. `loading` is both the first read and
 *  every re-read after the address changes: what is on screen belonged to
 *  the address before it, and drawing it under the new one would name the
 *  wrong package. */
export type OrderedRead<T> =
  | { status: "loading" }
  | { status: "ok"; data: T }
  | { status: "error"; error: string };

/** A command read that re-runs whenever `address` changes, landing only the
 *  newest answer.
 *
 *  The address changes under an in-flight read on ordinary paths — a
 *  repository page carrying on as the subscription it just gained, a move
 *  between packages in the Community tab — and the answer to the address
 *  before it must not land on the page now on screen. The same rule every
 *  store's standing lands under, so a page that reads per address does not
 *  hand-roll its own.
 *
 *  `read` is called for its current value rather than watched: it closes
 *  over the address, so it is a new function every render and would restart
 *  the read forever. `address` alone says when to ask again. */
export function useOrderedRead<T>(
  address: string | null,
  read: () => Promise<
    { status: "ok"; data: T } | { status: "error"; error: string }
  >,
): OrderedRead<T> {
  const latest = useRef(read);
  latest.current = read;
  const order = useRef(readOrder());
  const [answer, setAnswer] = useState<OrderedRead<T>>({ status: "loading" });

  useEffect(() => {
    // A null address asks nothing and leaves whatever is on screen: the
    // first read's loading state before any answer, and the last answer
    // after one. A page whose address goes null has not moved — it is
    // waiting on something else, as available-package does while a dropped
    // summary re-reads — so holding its view beats flashing a skeleton.
    if (address === null) return;
    const ticket = order.current.begin();
    setAnswer({ status: "loading" });
    // `settled` so a transport rejection lands as the failure the page
    // already knows how to draw, under this ticket like any other answer.
    // Left raw, the landing never ran at all: the ticket was spent, the
    // page held its skeleton or drew a blank with no message and no retry,
    // and the rejection went out unhandled.
    void settled(latest.current()).then((response) => {
      if (!order.current.lands(ticket)) return;
      setAnswer(
        response.status === "ok"
          ? { status: "ok", data: response.data }
          : { status: "error", error: response.error },
      );
    });
  }, [address]);

  return answer;
}
