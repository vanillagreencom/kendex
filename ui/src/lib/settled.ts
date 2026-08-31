type CommandResult<T> =
  | { status: "ok"; data: T }
  | { status: "error"; error: string };

/** Stands in when a rejection carries no message at all. An empty error
 *  body renders as blank under whatever title shows it, and consumers that
 *  test the message by truthiness would read the failure as no failure. */
export const NO_REASON_GIVEN = "Something went wrong, but no reason was given";

/** The one failure shape a rejection leaves, however it was thrown. */
const failure = (thrown: unknown): { status: "error"; error: string } => {
  const message = thrown instanceof Error ? thrown.message : String(thrown);
  return { status: "error", error: message === "" ? NO_REASON_GIVEN : message };
};

/** Await work so it always answers. A rejected call — transport failing,
 *  not the engine refusing — used to escape the stores entirely, leaving
 *  no error and no result: to the person that silence read as a read still
 *  on its way. Here it lands as the one failure shape, whatever the work
 *  answers with when it succeeds. */
export async function caught<T>(work: Promise<T>): Promise<CommandResult<T>> {
  try {
    return { status: "ok", data: await work };
  } catch (thrown) {
    return failure(thrown);
  }
}

/** Await a command so it always answers, in the one failure shape every
 *  store reads. */
export async function settled<T>(
  read: Promise<CommandResult<T>>,
): Promise<CommandResult<T>> {
  try {
    const response = await read;
    // The engine can return a refusal with an empty reason too — normalize
    // it the same way as an unsaid rejection.
    if (response.status === "error" && response.error === "") {
      return { status: "error", error: NO_REASON_GIVEN };
    }
    return response;
  } catch (thrown) {
    return failure(thrown);
  }
}
