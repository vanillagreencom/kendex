import { HarnessList } from "@/components/harnesses/harness-list";
import { PageHeader } from "@/components/page-header";
import { HARNESSES_SUBTITLE } from "@/lib/copy-harnesses";

/** The harnesses on this computer, and where each keeps its files. */
export function HarnessesPage() {
  return (
    <div>
      <PageHeader title="Harnesses" subtitle={HARNESSES_SUBTITLE} />
      <HarnessList />
    </div>
  );
}
