import { useState } from "react";
import type { SecretsView } from "@/bindings";
import { Pill } from "@/components/pill";
import { StatusLine, StatusNote } from "@/components/status-note";
import { Button } from "@/components/ui/button";
import {
  DEFAULT_SECRET_FILE,
  SECRET_FILE_CANCEL,
  SECRET_FILE_CHANGE,
  SECRET_FILE_DEFAULT_NOTE,
  SECRET_FILE_LABEL,
  SECRET_FILE_RECORDED,
  SECRET_FILE_REFUSED,
  SECRET_FILE_WILL_CREATE,
  SECRET_FILE_WILL_IGNORE,
  SECRET_NO_CANDIDATES,
} from "@/lib/copy-customize";

/**
 * Where this project keeps its secrets, said before anything is typed
 * into a field above it.
 *
 * Everything here is the read's answer rather than a claim: whether git
 * would carry the file, whether saving has to make it, and whether the
 * ignore line goes in first. Picking another file re-reads the place
 * against that file, so what the person sees is what a save would find
 * rather than what the name suggests.
 */
export function SecretDestination({
  secrets,
  picked,
  onPick,
}: {
  secrets: SecretsView;
  /** The file the person picked here, null while they have not. */
  picked: string | null;
  onPick: (file: string | null) => void;
}) {
  const [choosing, setChoosing] = useState(false);
  const { destination, candidates } = secrets;
  // The default is prepended below whether or not this project uses it,
  // so a candidate list still holding it would render it twice — two
  // identical pills under one React key. `candidates` drops only the file
  // in use, which is a different file whenever the project named another.
  const others = candidates.filter(
    (file) => file !== destination.file && file !== DEFAULT_SECRET_FILE,
  );

  return (
    <div className="flex flex-col gap-2 pb-3.5">
      <div className="flex flex-wrap items-center gap-2 text-[13px]">
        <span className="text-muted-foreground">{SECRET_FILE_LABEL}</span>
        <code className="font-mono text-[13px]">{destination.file}</code>
        <Button
          variant="ghost"
          size="sm"
          onClick={() => setChoosing((was) => !was)}
        >
          {choosing ? SECRET_FILE_CANCEL : SECRET_FILE_CHANGE}
        </Button>
      </div>
      {choosing ? (
        <div className="flex flex-wrap items-center gap-1.5">
          {[DEFAULT_SECRET_FILE, ...others].map((file) => (
            <Pill
              key={file}
              selected={file === destination.file}
              // Picking the file already in use is not a choice. It reads
              // as one where a higher settings layer names it — the root
              // file does not own that choice, so `chosen` is false — and
              // a save would then write `KENDEX_ENV_FILE` into the root
              // file for a decision the layer above it already made and
              // overrides.
              // The pill stays a real control — `Pill` keeps the selected
              // one focusable and `aria-pressed`, which is how the choice
              // is announced — so the click is what does nothing.
              onClick={() => {
                if (file !== destination.file) onPick(file);
              }}
            >
              {file}
            </Pill>
          ))}
          {others.length === 0 ? (
            <span className="text-[13px] text-muted-foreground">
              {SECRET_NO_CANDIDATES}
            </span>
          ) : null}
        </div>
      ) : null}
      {destination.state.state === "refused" ? (
        <StatusNote tone="warning" title={SECRET_FILE_REFUSED}>
          <p>{destination.state.problem}</p>
          <p className="mt-1">{destination.state.fix}</p>
        </StatusNote>
      ) : null}
      {destination.state.state === "missing" ? (
        <StatusLine tone="info">
          {SECRET_FILE_WILL_CREATE(destination.file)}
          {destination.state.ignore
            ? ` ${SECRET_FILE_WILL_IGNORE(destination.state.ignore, destination.file)}`
            : ""}
        </StatusLine>
      ) : null}
      {picked !== null && !destination.chosen ? (
        <StatusLine tone="info">
          {SECRET_FILE_RECORDED(destination.file)}
        </StatusLine>
      ) : null}
      {picked === null && !destination.chosen ? (
        <p className="text-xs text-muted-foreground">
          {SECRET_FILE_DEFAULT_NOTE}
        </p>
      ) : null}
    </div>
  );
}
