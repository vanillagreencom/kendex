// @vitest-environment jsdom
// The rule two pages read their per-address content under: the offered
// package's preview and one of its files. Both move between addresses while
// a read is out — a repository page carrying on as the subscription it just
// gained, a move between packages in the Community tab — so an older answer
// landing last is the ordinary case, not a race.
import { useState } from "react";
import { describe, expect, it, vi } from "vitest";
import { mount, settle } from "@/test/dom";
import { useOrderedRead } from "./use-ordered-read";

/** A read left in flight, with the resolver to land it by hand. */
const parked = <T,>() => {
  let land: (value: T) => void = () => {};
  const promise = new Promise<T>((resolve) => {
    land = resolve;
  });
  return { promise, land };
};

type Answer =
  | { status: "ok"; data: string }
  | { status: "error"; error: string };

/** A host that reads at whichever address it was last told to, and draws
 *  the answer, so a test reads the same thing a page's reader would. */
function Host({ read }: { read: (address: string) => Promise<Answer> }) {
  const [address, setAddress] = useState("older");
  const answer = useOrderedRead<string>(address, () => read(address));
  return (
    <div>
      <button type="button" onClick={() => setAddress("newer")}>
        move
      </button>
      <p>
        {answer.status === "loading"
          ? "loading"
          : answer.status === "ok"
            ? answer.data
            : `failed: ${answer.error}`}
      </p>
    </div>
  );
}

const move = (host: HTMLElement) => {
  const button = host.querySelector("button");
  if (!button) throw new Error("no move button");
  button.click();
};

describe("a read whose address changes while it is out", () => {
  it("keeps the newer answer when the older read lands last", async () => {
    const first = parked<Answer>();
    const second = parked<Answer>();
    const read = vi
      .fn<(address: string) => Promise<Answer>>()
      .mockReturnValueOnce(first.promise)
      .mockReturnValueOnce(second.promise);

    const host = mount(<Host read={read} />);
    await settle();
    expect(read).toHaveBeenCalledTimes(1);

    await settle();
    move(host);
    await settle();
    expect(read).toHaveBeenCalledTimes(2);

    second.land({ status: "ok", data: "the newer answer" });
    await settle();
    first.land({ status: "ok", data: "the older answer" });
    await settle();

    expect(host.textContent).toContain("the newer answer");
    expect(host.textContent).not.toContain("the older answer");
  });

  // The same for a refusal. An older one landing last would put an error
  // over an address that has since read perfectly well, and the retry it
  // offers would be for a page nobody is looking at.
  it("keeps the newer answer when the older read fails last", async () => {
    const first = parked<Answer>();
    const second = parked<Answer>();
    const read = vi
      .fn<(address: string) => Promise<Answer>>()
      .mockReturnValueOnce(first.promise)
      .mockReturnValueOnce(second.promise);

    const host = mount(<Host read={read} />);
    await settle();
    move(host);
    await settle();

    second.land({ status: "ok", data: "the newer answer" });
    await settle();
    first.land({ status: "error", error: "that catalog is gone" });
    await settle();

    expect(host.textContent).toContain("the newer answer");
    expect(host.textContent).not.toContain("that catalog is gone");
  });

  // Moving addresses puts the page back to loading rather than leaving the
  // answer for the address before it on screen under the new name.
  it("shows nothing of the address before it while the new read is out", async () => {
    const first = parked<Answer>();
    const second = parked<Answer>();
    const read = vi
      .fn<(address: string) => Promise<Answer>>()
      .mockReturnValueOnce(first.promise)
      .mockReturnValueOnce(second.promise);

    const host = mount(<Host read={read} />);
    await settle();
    first.land({ status: "ok", data: "the older answer" });
    await settle();
    expect(host.textContent).toContain("the older answer");

    move(host);
    await settle();

    expect(host.textContent).toContain("loading");
    expect(host.textContent).not.toContain("the older answer");
  });

  // A transport rejection is a read that failed, not an exception for the
  // page to drop: left raw it spent the ticket with no landing at all,
  // leaving the reader a skeleton or a blank with nothing to retry from
  // and an unhandled rejection on its way out.
  it("shows the failure when the read rejects rather than answering", async () => {
    const read = vi
      .fn<(address: string) => Promise<Answer>>()
      .mockRejectedValue(new Error("the bridge is gone"));

    const host = mount(<Host read={read} />);
    await settle();

    expect(host.textContent).toContain("failed: the bridge is gone");
    expect(host.textContent).not.toContain("loading");
  });

  // The control: with nothing newer behind it a read lands as it always
  // did, so the cases above hold the ordering rather than a reader that
  // never shows anything.
  it("shows the only answer there is", async () => {
    const read = vi
      .fn<(address: string) => Promise<Answer>>()
      .mockResolvedValue({ status: "ok", data: "the only answer" });

    const host = mount(<Host read={read} />);
    await settle();

    expect(host.textContent).toContain("the only answer");
  });

  // A page not ready to read yet asks for nothing and stays loading; the
  // read that follows is still the newest when it comes.
  it("asks for nothing at a null address", async () => {
    const read = vi
      .fn<(address: string) => Promise<Answer>>()
      .mockResolvedValue({ status: "ok", data: "unreachable" });

    const host = mount(
      <Waiting>{() => useOrderedRead<string>(null, () => read(""))}</Waiting>,
    );
    await settle();

    expect(read).not.toHaveBeenCalled();
    expect(host.textContent).toContain("loading");
  });
});

/** Renders whatever the hook it is handed answers, for the one case that
 *  needs a different address than [Host] takes. */
function Waiting({
  children,
}: {
  children: () => ReturnType<typeof useOrderedRead<string>>;
}) {
  return <p>{children().status}</p>;
}
