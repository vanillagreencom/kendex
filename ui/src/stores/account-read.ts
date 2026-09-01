// How the account is read, and who answers when it is.
//
// The store keeps what the last read settled on; this is the read itself —
// the command, the rename from its wire shape, and the seam a test takes
// over to answer as a state no server is behind.
import { type AccountStatus, commands } from "@/bindings";
import type { SettledAccount } from "./account";

/** What a read of the account answers: the state it settled on, or why it
 * could not be read. */
export type AccountRead = { ok: SettledAccount } | { error: string };

type ReadAccount = () => Promise<AccountRead>;

/** The wire answers every settled state this store keeps; the unread one
 * is the UI's own, so the mapping is a rename. */
const settled = (wire: AccountStatus["state"]): SettledAccount => {
  switch (wire.state) {
    case "signed-out":
      return { kind: "signed-out" };
    case "signed-in":
      return { kind: "signed-in", identity: wire.identity };
    case "offline":
      return { kind: "offline", identity: wire.identity };
    case "expired":
      return { kind: "expired" };
  }
};

/** The command asks the server who the credential belongs to, so it can
 * answer with a name, with the last name it knew when the server is away,
 * and with the rejection when the credential is dead. */
const fromBridge: ReadAccount = async () => {
  const status = await commands.accountStatus();
  if (status.status === "error") return { error: status.error };
  return { ok: settled(status.data.state) };
};

let reader: ReadAccount = fromBridge;

/** Answer reads with `read` rather than the command, so a test can serve
 * any state the backend reports without a server behind it. Null puts the
 * command back. */
export function setAccountReader(read: ReadAccount | null): void {
  reader = read ?? fromBridge;
}

/** One read of the account, through whoever is answering. Called through
 * rather than exported directly, so a harness installed after the store was
 * imported is still the one asked.
 *
 * The throw is caught here rather than in each reader: a bridge that throws
 * and a reply that says no are the same answer, the account could not be
 * read, and this is the one place every reader passes through. Letting a
 * throw out would leave the read with nothing recorded, nothing to retry
 * from, and an unhandled rejection wherever the store is loaded as
 * `void load()`. */
export const readAccount: ReadAccount = async () => {
  try {
    return await reader();
  } catch (error: unknown) {
    return { error: String(error) };
  }
};
