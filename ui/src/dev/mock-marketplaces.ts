// Reading marketplaces: the overview, a subscription's packages, a bundle,
// a package preview with its safety report, and the Library's provenance.
// Installing and subscribing live in mock-install.ts and mock-subscribe.ts.
import type {
  Catalog,
  CatalogSummary,
  ItemKind,
  ItemSource,
  PackageView,
} from "@/bindings";
import { aboutViews, repoSummaries } from "./fixture-marketplaces";
import { packageSafety } from "./fixture-package-safety";
import { bundleDetail, offeredHere, specSource } from "./mock-catalog";
import { installHandlers } from "./mock-install";
import { type Handler, same, store } from "./mock-state";
import { subscribeHandlers } from "./mock-subscribe";
import { unsubscribeHandlers } from "./mock-unsubscribe";

export const marketplaceHandlers: Record<string, Handler> = {
  ...installHandlers,
  ...subscribeHandlers,
  ...unsubscribeHandlers,

  marketplaces_overview: () => store.state.marketplaces,

  marketplace_packages: ({ catalog }: { catalog: Catalog }) =>
    offeredHere(catalog),

  marketplace_summary: ({
    catalog,
  }: {
    catalog: Catalog;
  }): CatalogSummary | Promise<never> => {
    const offered = offeredHere(catalog);
    if (offered instanceof Promise) return offered;
    if (catalog.by === "subscription") {
      return {
        provenance: catalog.source,
        repoKey:
          store.state.marketplaces.find(
            (row) =>
              row.name === catalog.source && same(row.scope, catalog.scope),
          )?.repoKey ?? null,
        commit: null,
        meta: null,
        mode: "discovered",
        counts: {},
        warning: null,
        subscription: { scope: catalog.scope, source: catalog.source },
      };
    }
    const held = store.state.marketplaces.find(
      (row) => row.repo === catalog.repo,
    );
    return {
      ...repoSummaries[catalog.repo],
      subscription: held ? { scope: held.scope, source: held.name } : null,
    };
  },

  marketplace_bundle: ({
    catalog,
    name,
  }: {
    catalog: Catalog;
    name: string;
  }) => {
    const offered = offeredHere(catalog);
    if (offered instanceof Promise) return offered;
    return bundleDetail(offered, specSource(catalog), name);
  },

  marketplace_package_preview: ({
    catalog,
    kind,
    name,
  }: {
    catalog: Catalog;
    kind: ItemKind;
    name: string;
  }): PackageView | Promise<never> => {
    const offered = offeredHere(catalog);
    if (offered instanceof Promise) return offered;
    const pkg = offered.find((p) => p.kind === kind && p.name === name);
    if (!pkg) {
      return Promise.reject(
        `'${name}' is not offered by '${specSource(catalog)}'`,
      );
    }
    return {
      preview: {
        kind: pkg.kind,
        name: pkg.name,
        description: pkg.description,
        tags: pkg.tags,
        readme:
          kind === "skill"
            ? `Use **${name}** for ${pkg.description?.toLowerCase()}.\n\nRead the checklist before acting.\n`
            : `# ${name}\n\n${pkg.description}\n`,
        files:
          kind === "skill"
            ? [
                { path: "SKILL.md", size: 1284, isReadme: false },
                { path: "README.md", size: 412, isReadme: true },
                { path: "checklist.md", size: 903, isReadme: false },
              ]
            : [
                {
                  path: `${name.split("/").at(-1)}.md`,
                  size: 764,
                  isReadme: false,
                },
              ],
        bundles: pkg.bundles,
        collision: pkg.collision,
      },
      safety: packageSafety(kind, name),
    };
  },

  marketplace_package_file: ({
    catalog,
    kind,
    name,
    path,
  }: {
    catalog: Catalog;
    kind: ItemKind;
    name: string;
    path: string;
  }): ItemSource | Promise<never> => {
    const offered = offeredHere(catalog);
    if (offered instanceof Promise) return offered;
    if (!offered.some((p) => p.kind === kind && p.name === name)) {
      return Promise.reject(`'${name}' is not offered`);
    }
    if (path.startsWith("/") || path.split("/").includes("..") || !path) {
      return Promise.reject(
        `${path}: a package file is named by a plain relative path`,
      );
    }
    const content = path.endsWith(".md")
      ? `# ${path}\n\nWhat **${name}** keeps in ${path}.\n`
      : `${path} of ${name}\n`;
    return { path, content, truncated: false };
  },

  marketplace_about: ({ catalog }: { catalog: Catalog }) => {
    const offered = offeredHere(catalog);
    if (offered instanceof Promise) return offered;
    const about = aboutViews[specSource(catalog)];
    if (!about) {
      return Promise.reject(
        `source '${specSource(catalog)}' is not fetched yet`,
      );
    }
    return about;
  },

  library_provenance: () => store.state.provenance,
};
