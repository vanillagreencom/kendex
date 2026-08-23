import type {
  AppSettings,
  AuditView,
  AvailablePackage,
  BundleRow,
  DetectedHarness,
  ItemKind,
  Manifest_Serialize,
  MarketplaceRow,
  ObservedItem,
  ProvenanceRow,
  SourceRow,
} from "@/bindings";
import { bundles } from "./fixture-bundles";
import { manifests, sources, views } from "./fixture-declared";
import {
  marketplacePackages,
  marketplaces,
  repoPackages,
} from "./fixture-marketplaces";
import { harnesses, items } from "./fixture-observed";
import { provenance } from "./fixture-provenance";
import { ACME, API } from "./fixture-scopes";

export { ACME, API, AVAILABLE_SKILLS } from "./fixture-scopes";

export interface MockState {
  settings: AppSettings;
  harnesses: DetectedHarness[];
  items: ObservedItem[];
  missingProjects: string[];
  warnings: string[];
  views: AuditView[];
  manifests: Record<string, Manifest_Serialize>;
  sources: SourceRow[];
  bundles: BundleRow[];
  marketplaces: MarketplaceRow[];
  /// What each readable subscription offers, keyed scope-label::source.
  marketplacePackages: Record<string, AvailablePackage[]>;
  /// What a listed repository offers when browsed before subscribing.
  repoPackages: Record<string, AvailablePackage[]>;
  provenance: ProvenanceRow[];
  /// Packages whose update notifications the mock user muted.
  ignored: { kind: ItemKind; name: string }[];
}

export function initialState(): MockState {
  return {
    settings: {
      schema: 1,
      projects: [ACME, API],
      appearance: "system",
      safety: { "warn-below": 80, "block-below": 60 },
      zoom: 100,
    },
    harnesses: harnesses(),
    items: items(),
    missingProjects: [],
    warnings: [],
    views: views(),
    manifests: manifests(),
    sources: sources(),
    bundles: bundles(),
    marketplaces: marketplaces(),
    marketplacePackages: marketplacePackages(),
    repoPackages: repoPackages(),
    provenance: provenance(),
    ignored: [],
  };
}
