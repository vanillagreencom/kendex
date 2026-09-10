import type { ItemKind } from "@/bindings";
import { packageCount } from "@/lib/copy-templates";
import type { InstallSubject } from "@/stores/install-flow";
import type { Template } from "@/stores/templates";

/** Whether a member is a whole set the catalog expands, rather than one
 *  package. A plugin is its registry's own curated set and core resolves
 *  it as one, so it counts here beside a bundle. */
const wholeSet = (kind: string): boolean =>
  kind === "bundle" || kind === "plugin";

/** What the guided install asks about when the answer is a template.
 *
 *  One subject with no marketplace groups: a template's members can span
 *  marketplaces and its own copies, which is more than one
 *  `marketplace_install` carries, so the flow sends the template through
 *  the operation core owns instead.
 *
 *  The kinds are the template's, so the tools picker offers exactly what
 *  these packages can install to — except where a member is a whole set,
 *  whose contents are the catalog's to say and not knowable from here. A
 *  set install declares every kind whatever the set happens to hold,
 *  which is the answer naming no kind gets: the same answer
 *  `pages/bundle-detail.tsx` gives for installing a set whole. Naming the
 *  kinds beside it would offer a narrower list of tools than the set's own
 *  members need. */
export function templateSubject(template: Template): InstallSubject {
  const members = template.members ?? [];
  // Every kind left in this branch is a package kind: no member here is a
  // set, and a Pi extension is refused as a member at all, so the two
  // member kinds that are not `ItemKind` cannot be among them.
  const kinds = members.some((member) => wholeSet(member.kind))
    ? []
    : [...new Set(members.map((member) => member.kind as ItemKind))];
  return {
    id: `template:${template.name}`,
    label: template.name,
    what: packageCount(members.length),
    count: members.length,
    groups: [],
    kinds,
    template: template.name,
  };
}
