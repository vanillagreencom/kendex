import { Badge } from "@/components/ui/badge";
import {
  Tooltip,
  TooltipContent,
  TooltipTrigger,
} from "@/components/ui/tooltip";
import {
  SHARED_FILES_BADGE_LABEL,
  SHARED_FILES_CONSEQUENCE,
  sharedFileReaders,
  sharedFilesHelp,
} from "@/lib/copy";
import type { SharedFile } from "@/lib/derive";

/**
 * "Shared files": one copy of this package that several harnesses read.
 *
 * The two words alone are a fact about the app's plumbing that a reader has
 * no way to check or act on, so the badge carries its own explanation — the
 * paths themselves, who reads each, and what that costs on the next edit —
 * on hover, on focus, and to a screen reader. Nothing is shared, no badge:
 * the empty list is the same answer as the absent one.
 */
export function SharedFilesBadge({ files }: { files: SharedFile[] }) {
  if (files.length === 0) return null;
  return (
    <Tooltip>
      <TooltipTrigger
        render={
          <Badge variant="secondary" tabIndex={0}>
            {SHARED_FILES_BADGE_LABEL}
            <span className="sr-only">{sharedFilesHelp(files)}</span>
          </Badge>
        }
      />
      <TooltipContent className="max-w-96">
        <span className="flex flex-col gap-1">
          {files.map((file) => (
            <span key={file.path}>
              {sharedFileReaders(file.harnesses)} read{" "}
              <span className="font-mono break-all">{file.path}</span>
            </span>
          ))}
          <span>{SHARED_FILES_CONSEQUENCE}</span>
        </span>
      </TooltipContent>
    </Tooltip>
  );
}
