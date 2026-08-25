import { Info, MoreHorizontal } from "lucide-react";
import { Button } from "@/components/ui/button";
import {
  DropdownMenu,
  DropdownMenuCheckboxItem,
  DropdownMenuContent,
  DropdownMenuTrigger,
} from "@/components/ui/dropdown-menu";
import { TableHead, TableHeader, TableRow } from "@/components/ui/table";
import {
  Tooltip,
  TooltipContent,
  TooltipTrigger,
} from "@/components/ui/tooltip";
import {
  FOLLOW_SOURCE_COLUMN,
  FOLLOW_SOURCE_HELP,
  SHOW_VERSION_LABEL,
  TABLE_OPTIONS_LABEL,
  UPDATES_NAME_COLUMN,
  UPDATES_PLACE_COLUMN,
  UPDATES_TYPE_COLUMN,
  UPDATES_VERSION_COLUMN,
} from "@/lib/copy-updates";

/** The updates table's header: the columns, the one-sentence explanation
 *  of the Follow source switch on its own column, and — where the page
 *  puts it — the `…` menu at the table's top right that shows the Version
 *  column. */
export function UpdatesTableHeader({
  showVersion,
  onShowVersion,
}: {
  showVersion: boolean;
  /** Present on the one table that carries the menu: the setting is the
   *  page's, and every table on it follows. */
  onShowVersion?: (show: boolean) => void;
}) {
  return (
    <TableHeader>
      <TableRow>
        <TableHead>{UPDATES_NAME_COLUMN}</TableHead>
        <TableHead className="w-24">{UPDATES_TYPE_COLUMN}</TableHead>
        <TableHead className="w-36">{UPDATES_PLACE_COLUMN}</TableHead>
        {showVersion ? (
          <TableHead className="w-36">{UPDATES_VERSION_COLUMN}</TableHead>
        ) : null}
        <TableHead className="w-28 text-center">
          <span className="inline-flex items-center gap-1">
            {FOLLOW_SOURCE_COLUMN}
            {/* The words sit in the trigger for a keyboard and a screen
                reader; the popup repeats them for a pointer. */}
            <Tooltip>
              <TooltipTrigger
                render={
                  <button
                    type="button"
                    className="text-muted-foreground hover:text-foreground"
                  >
                    <Info className="size-3.5" />
                    <span className="sr-only">{FOLLOW_SOURCE_HELP}</span>
                  </button>
                }
              />
              <TooltipContent className="max-w-72">
                {FOLLOW_SOURCE_HELP}
              </TooltipContent>
            </Tooltip>
          </span>
        </TableHead>
        <TableHead>
          <div className="flex items-center justify-end">
            <span className="sr-only">Actions</span>
            {onShowVersion ? (
              <DropdownMenu>
                <DropdownMenuTrigger
                  render={
                    <Button
                      size="icon-xs"
                      variant="ghost"
                      aria-label={TABLE_OPTIONS_LABEL}
                    >
                      <MoreHorizontal className="size-4" />
                    </Button>
                  }
                />
                <DropdownMenuContent align="end">
                  <DropdownMenuCheckboxItem
                    checked={showVersion}
                    onCheckedChange={onShowVersion}
                  >
                    {SHOW_VERSION_LABEL}
                  </DropdownMenuCheckboxItem>
                </DropdownMenuContent>
              </DropdownMenu>
            ) : null}
          </div>
        </TableHead>
      </TableRow>
    </TableHeader>
  );
}
