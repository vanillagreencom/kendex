// In-memory stand-in for the Tauri invoke bridge, loaded only under
// VITE_MOCK=1: the WebKit app window cannot be driven by browser
// automation, so UI validation runs the real pages in Chromium against
// this bridge instead.
import { accountHandlers, installAccountReader } from "./mock-account";
import { auditHandlers } from "./mock-audit";
import { communityHandlers } from "./mock-community";
import { coreHandlers } from "./mock-core";
import { marketplaceHandlers } from "./mock-marketplaces";
import { mineHandlers } from "./mock-mine";
import { packageHandlers } from "./mock-packages";
import { sourceHandlers } from "./mock-sources";
import { type Handler, resetState } from "./mock-state";

export const handlers: Record<string, Handler> = {
  ...coreHandlers,
  ...auditHandlers,
  ...sourceHandlers,
  ...packageHandlers,
  ...marketplaceHandlers,
  ...communityHandlers,
  ...mineHandlers,
  ...accountHandlers,
};

export { resetState as resetMock };

// The command behind the store's account read cannot answer with a name,
// so the harness answers in its place.
installAccountReader();

const pause = () => new Promise((resolve) => setTimeout(resolve, 120));

export async function mockInvoke(
  cmd: string,
  args: unknown = {},
): Promise<unknown> {
  const handler = handlers[cmd];
  if (!handler) {
    return Promise.reject(`mock has no handler for command '${cmd}'`);
  }
  await pause();
  return structuredClone(await handler(args as never));
}

declare global {
  interface Window {
    __TAURI_INTERNALS__?: unknown;
  }
}

if (typeof window !== "undefined") {
  window.__TAURI_INTERNALS__ = {
    invoke: mockInvoke,
    transformCallback: () => 0,
  };
}
