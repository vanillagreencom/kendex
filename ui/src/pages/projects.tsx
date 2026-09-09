import { ProjectList } from "@/components/harnesses/project-list";
import { PageHeader } from "@/components/page-header";
import { PLACES_SUBTITLE } from "@/lib/copy-model";

/** Every place kendex installs packages into, and the way to register or
 *  drop one. The subtitle states the model the rest of the app follows. */
export function ProjectsPage() {
  return (
    <div>
      <PageHeader title="Projects" subtitle={PLACES_SUBTITLE} />
      <ProjectList />
    </div>
  );
}
