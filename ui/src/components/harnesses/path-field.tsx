import { FolderOpen } from "lucide-react";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { pickFolder } from "@/lib/pick-folder";

/**
 * A path field with the folder picker inside it, rather than a labelled
 * input, a browse button and a submit button in a row of three — a label
 * would only repeat the placeholder, and the picker is part of filling the
 * field in, not a step of its own.
 */
export function PathField({
  id,
  placeholder,
  value,
  onChange,
  disabled,
  browseLabel,
}: {
  id: string;
  placeholder: string;
  value: string;
  onChange: (value: string) => void;
  disabled?: boolean;
  browseLabel: string;
}) {
  return (
    <div className="relative flex-1">
      <Input
        id={id}
        className="pr-9 font-mono text-[13px]"
        placeholder={placeholder}
        value={value}
        disabled={disabled}
        onChange={(e) => onChange(e.target.value)}
      />
      <Button
        type="button"
        variant="ghost"
        size="icon-sm"
        className="absolute top-1/2 right-0.5 -translate-y-1/2"
        aria-label={browseLabel}
        title={browseLabel}
        disabled={disabled}
        onClick={() => {
          void pickFolder().then((picked) => {
            if (picked) onChange(picked);
          });
        }}
      >
        <FolderOpen className="size-4" />
      </Button>
    </div>
  );
}
