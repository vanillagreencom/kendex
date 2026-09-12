import type { InstalledColumns } from "@/components/library/installed-row";
import { Skeleton } from "@/components/ui/skeleton";
import { TableCell, TableRow } from "@/components/ui/table";

// One entry per placeholder row: how wide its name bar is, so the
// placeholder reads as a list of different things rather than one loading
// bar drawn eight times. Each width appears once, which makes it the row's
// identity too.
const NAME_WIDTHS = [
  "w-40",
  "w-28",
  "w-36",
  "w-24",
  "w-44",
  "w-32",
  "w-20",
  "w-48",
];

/** What the table shows before the first scan lands. A table that says
 *  "Nothing installed yet" while it is still counting is telling the reader
 *  something false about their machine.
 *
 *  It draws the columns the table is drawing, one placeholder each: a
 *  placeholder row wider or narrower than the header it sits under is a
 *  loading state that moves the columns when the rows arrive. */
export function InstalledSkeleton({ columns }: { columns: InstalledColumns }) {
  return (
    <>
      {NAME_WIDTHS.map((width) => (
        <TableRow key={width}>
          <TableCell>
            <div className="flex items-start gap-2">
              <Skeleton className="mt-0.5 size-4 rounded" />
              <div className="flex flex-col gap-1.5">
                <Skeleton className={`h-3.5 ${width}`} />
                <Skeleton className="h-3 w-56" />
              </div>
            </div>
          </TableCell>
          <TableCell>
            <Skeleton className="h-3.5 w-14" />
          </TableCell>
          {columns.tags ? (
            <TableCell>
              <Skeleton className="h-3.5 w-16" />
            </TableCell>
          ) : null}
          {columns.harnesses ? (
            <TableCell>
              <span className="flex gap-1">
                <Skeleton className="h-5 w-6 rounded-md" />
                <Skeleton className="h-5 w-6 rounded-md" />
              </span>
            </TableCell>
          ) : null}
          <TableCell>
            <Skeleton className="h-3.5 w-16" />
          </TableCell>
          {columns.from ? (
            <TableCell>
              <Skeleton className="h-3.5 w-16" />
            </TableCell>
          ) : null}
          {columns.updated ? (
            <TableCell>
              <Skeleton className="ml-auto h-3 w-12" />
            </TableCell>
          ) : null}
          <TableCell>
            <Skeleton className="mx-auto size-2 rounded-full" />
          </TableCell>
        </TableRow>
      ))}
    </>
  );
}
