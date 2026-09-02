import type {
  CandidateGroup,
  CandidateOrigin,
  ImportCandidate,
} from "@/bindings";
import { Checkbox } from "@/components/ui/checkbox";
import { Input } from "@/components/ui/input";
import {
  Select,
  SelectContent,
  SelectItem,
  SelectTrigger,
  SelectValue,
} from "@/components/ui/select";

/** What the wizard tracks for one chosen candidate. */
export interface RowChoice {
  checked: boolean;
  hash: string;
  destination: string;
  licenseConfirmed: boolean;
  licenseBasis: string;
}

/** Where each unselectable origin was and why. One line per origin and no
 * dedup here: core's inventory folds a place refused for the same reason
 * into one row, so the file claimed both as a marketplace's edited copy
 * and by the unmanaged scan arrives already merged. */
function refusals(origins: CandidateOrigin[]): string[] {
  return origins.map((origin) => {
    const place = origin.locations.join(" = ");
    return origin.problem ? `${place} — ${origin.problem}` : place;
  });
}

export function groupLabel(group: CandidateGroup): string {
  switch (group.group) {
    case "own":
      return "Your own";
    case "unmanaged":
      return "Found on disk";
    case "marketplace":
      return group.license
        ? `From '${group.source}' · ${group.license}`
        : `From '${group.source}' · no licence found`;
    case "edited":
      return group.license
        ? `Your edited copy from '${group.source}' · ${group.license}`
        : `Your edited copy from '${group.source}' · no licence found`;
  }
}

/** One candidate: the checkbox, the origin picker when bytes differ, the
 * rename input when a harness would refuse the name, and the licence
 * evidence for marketplace-origin content.
 *
 * A candidate with nothing selectable lists where its bytes were and the
 * reason core gave for each: a marketplace nobody fetched, an agent in a
 * format a catalog cannot store. The label beside the name says only that
 * nothing here can be imported, because "not readable" would be the wrong
 * cause for a Codex agent, which reads fine. */
export function MineImportRow({
  candidate,
  choice,
  onChange,
}: {
  candidate: ImportCandidate;
  choice: RowChoice;
  onChange: (next: RowChoice) => void;
}) {
  const readable = candidate.origins.filter((origin) => origin.hash !== "");
  const chosen =
    readable.find((origin) => origin.hash === choice.hash) ?? readable[0];
  const licensed =
    chosen &&
    (chosen.group.group === "marketplace" || chosen.group.group === "edited")
      ? chosen.group
      : null;

  return (
    <div className="space-y-2 rounded-md border border-border p-3">
      <div className="flex items-center gap-2">
        <Checkbox
          aria-label={`Import ${candidate.name}`}
          checked={choice.checked}
          disabled={readable.length === 0}
          onCheckedChange={(checked) =>
            onChange({ ...choice, checked: checked === true })
          }
        />
        <span className="font-medium">{candidate.name}</span>
        <span className="text-xs text-muted-foreground">
          {candidate.kind}
          {chosen
            ? ` · ${groupLabel(chosen.group)}`
            : " · nothing kendex can import"}
        </span>
      </div>
      {/* Refusals only when nothing on the row is selectable: beside a
          selectable origin the reason explains a copy the person cannot act
          on, and the picker below already offers only what can be chosen. */}
      {readable.length === 0 ? (
        <ul className="pl-6 text-xs text-warning">
          {refusals(candidate.origins).map((refusal) => (
            <li key={refusal}>{refusal}</li>
          ))}
        </ul>
      ) : null}
      {choice.checked && readable.length > 1 ? (
        <div className="pl-6">
          <Select
            value={choice.hash}
            onValueChange={(hash) =>
              onChange({ ...choice, hash: hash ?? choice.hash })
            }
          >
            <SelectTrigger className="w-full">
              <SelectValue>
                {(current: string) => {
                  const origin = readable.find((o) => o.hash === current);
                  return origin
                    ? `${groupLabel(origin.group)} — ${origin.locations[0]}`
                    : "Which copy?";
                }}
              </SelectValue>
            </SelectTrigger>
            <SelectContent>
              {readable.map((origin) => (
                <SelectItem key={origin.hash} value={origin.hash}>
                  {groupLabel(origin.group)} — {origin.locations.join(" = ")}
                </SelectItem>
              ))}
            </SelectContent>
          </Select>
        </div>
      ) : null}
      {choice.checked && candidate.nameProblem ? (
        <div className="space-y-1 pl-6">
          <p className="text-xs text-warning">{candidate.nameProblem}</p>
          <Input
            aria-label={`New name for ${candidate.name}`}
            placeholder="a name every harness accepts"
            value={choice.destination}
            onChange={(e) =>
              onChange({ ...choice, destination: e.target.value })
            }
          />
        </div>
      ) : null}
      {choice.checked && licensed ? (
        licensed.license && licensed.licenseRecognized ? (
          <div className="flex items-center gap-2 pl-6 text-sm">
            <Checkbox
              aria-label={`The ${licensed.license} licence lets me republish ${candidate.name}`}
              checked={choice.licenseConfirmed}
              onCheckedChange={(checked) =>
                onChange({ ...choice, licenseConfirmed: checked === true })
              }
            />
            <span>The {licensed.license} licence lets me republish this</span>
          </div>
        ) : (
          <div className="space-y-1 pl-6">
            <p className="text-xs text-warning">
              {licensed.license
                ? `'${licensed.license}' is not a licence kendex recognizes as redistributable.`
                : `No licence was found in '${licensed.source}'.`}{" "}
              Copying needs a basis you can stand behind.
            </p>
            <Input
              aria-label={`Licence basis for ${candidate.name}`}
              placeholder="e.g. the author gave me permission on …"
              value={choice.licenseBasis}
              onChange={(e) =>
                onChange({ ...choice, licenseBasis: e.target.value })
              }
            />
          </div>
        )
      ) : null}
    </div>
  );
}
