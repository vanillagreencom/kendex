import type { Scope } from "@/bindings";
import { type Handler, same, sourceRow, store } from "./mock-state";

export const sourceHandlers: Record<string, Handler> = {
  sources_overview: () => store.state.sources,
  source_add: ({
    scope,
    name,
    reference,
  }: {
    scope: Scope;
    name: string;
    reference: string;
  }) => {
    if (sourceRow(scope, name)) {
      return Promise.reject(`a source named '${name}' already exists here`);
    }
    const isRemote = !reference.startsWith("/") && !reference.startsWith(".");
    store.state.sources.push({
      scope,
      name,
      reference,
      isRemote,
      enabled: true,
      head: isRemote ? "e4d0b2f" : null,
      declaredItems: [],
    });
    return store.state.sources;
  },
  source_remove: ({ scope, name }: { scope: Scope; name: string }) => {
    const row = sourceRow(scope, name);
    if (!row) return Promise.reject(`no source named '${name}' here`);
    if (row.declaredItems.length > 0) {
      return Promise.reject(
        `'${name}' still provides ${row.declaredItems.length} item(s) — disable it instead`,
      );
    }
    store.state.sources = store.state.sources.filter((r) => r !== row);
    return store.state.sources;
  },
  source_toggle: ({
    scope,
    name,
    enabled,
  }: {
    scope: Scope;
    name: string;
    enabled: boolean;
  }) => {
    const row = sourceRow(scope, name);
    if (!row) return Promise.reject(`no source named '${name}' here`);
    row.enabled = enabled;
    for (const it of store.state.items) {
      if (same(it.scope, scope) && row.declaredItems.includes(it.name)) {
        it.enabled = enabled;
      }
    }
    return store.state.sources;
  },
  bundles_overview: () => store.state.bundles,
  bundle_install: ({
    scope,
    source,
    name,
  }: {
    scope: Scope;
    source: string;
    name: string;
  }) => {
    const row = store.state.bundles.find(
      (bundle) =>
        bundle.name === name &&
        bundle.source === source &&
        same(bundle.scope, scope),
    );
    if (!row) return Promise.reject(`no bundle named '${name}' here`);
    row.installed = true;
    return {
      bundles: store.state.bundles,
      repoEffects: { shown: [], withheld: [] },
    };
  },
  sources_refresh: () => {
    for (const row of store.state.sources) {
      if (row.isRemote && row.enabled) row.head = "e4d0b2f";
    }
    return [];
  },
};
