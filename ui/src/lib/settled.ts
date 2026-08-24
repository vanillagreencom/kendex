type CommandResult<T> =
  | { status: "ok"; data: T }
  | { status: "error"; error: string };

/** Await a command so it always answers. A rejected call — transport
 *  failing, not the engine refusing — used to escape the stores entirely,
 *  leaving no error and no result: to the person that silence read as a
 *  read still on its way. Here it lands as the same shape as a returned
 *  refusal, so every store has exactly one failure state. */
export async function settled<T>(
  read: Promise<CommandResult<T>>,
): Promise<CommandResult<T>> {
  try {
    return await read;
  } catch (thrown) {
    return {
      status: "error",
      error: thrown instanceof Error ? thrown.message : String(thrown),
    };
  }
}
