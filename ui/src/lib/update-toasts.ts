import type { UpdateRow } from "@/bindings";
import { UPDATED_ALL_TOAST, updatedToastLabel } from "@/lib/copy";
import {
  updatedCountToastLabel,
  updatedSomeToastLabel,
} from "@/lib/copy-updates";
import { packageDisplayName } from "@/lib/labels";
import { packageCount } from "@/lib/update-groups";

/** What a finished bulk update may claim. The all-clear belongs to an
 *  empty list: a call that covered one package's places, or that left rows
 *  with news but nothing to apply, says what it did and no more. */
export function bulkUpdateToast(
  updated: UpdateRow[],
  skipped: number,
  remaining: UpdateRow[],
): string {
  const packages = packageCount(updated);
  if (skipped > 0) return updatedSomeToastLabel(packages, skipped);
  if (remaining.length === 0) return UPDATED_ALL_TOAST;
  if (packages === 1) return updatedToastLabel(packageDisplayName(updated[0]));
  return updatedCountToastLabel(packages);
}
