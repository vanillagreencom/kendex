import type { ItemKind } from "@/bindings";
import { packageCount } from "@/lib/copy-templates";
import type { InstallSubject } from "@/stores/install-flow";
import type { Template } from "@/stores/templates";

/** What the guided install asks about when the answer is a template.
 *
 *  One subject with no marketplace groups: a template's members can span
 *  marketplaces and its own copies, which is more than one
 *  `marketplace_install` carries, so the flow sends the template through
 *  the operation core owns instead. The kinds are the template's, so the
 *  tools picker offers exactly what these packages can install to. */
export function templateSubject(template: Template): InstallSubject {
  const members = template.members ?? [];
  const kinds = [
    ...new Set(
      members
        .map((member) => member.kind)
        .filter((kind): kind is ItemKind => kind !== "bundle"),
    ),
  ];
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
