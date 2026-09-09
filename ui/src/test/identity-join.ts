import type { ProvenanceRow } from "@/bindings";
import { useProvenanceStore } from "@/stores/provenance";
import { useScanStore } from "@/stores/scan";

/** Put the identity join in the state a test means by "it has answered".
 *
 *  Readiness is whether the rows answer about the scan ON SCREEN, so the
 *  generation is read rather than written down: a fixture that pinned a
 *  number would go stale the moment anything in its file ran a scan, and
 *  would then be asserting against a state the app never reaches.
 *
 *  For the states where it has NOT answered — never read, or read and
 *  failed — set the store directly; those are what each of those tests is
 *  about, and they are not one shape. */
export const joinAnswered = (rows: ProvenanceRow[] = []): void =>
  useProvenanceStore.setState({
    rows,
    loaded: true,
    answeredFor: useScanStore.getState().generation,
  });
