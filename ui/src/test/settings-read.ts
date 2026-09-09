import type { ScopeSettings, SecretsView } from "@/bindings";

/** The place-wide half of a settings read, for cases that are about
 *  something else.
 *
 *  A `ScopeSettings` answers for the whole place — which file its public
 *  settings go in, where its credentials go, and what its packages
 *  disagree about — and most cases care about one skill's rows. Spelling
 *  the rest here keeps a case's fixture to what the case is about, and
 *  keeps every case answering the same way about the parts it does not
 *  name. */
export const placeRead = {
  file: "kendex.settings.toml",
  secrets: {
    destination: {
      file: ".env.local",
      chosen: false,
      state: { state: "ready" },
    },
    candidates: [],
    base: "p1",
  } satisfies SecretsView,
  contested: [],
} satisfies Pick<ScopeSettings, "file" | "secrets" | "contested">;
