// The package page's own reads of one package — its record, files, README
// and timeline, and the files opened on its Files tab — kept past the page,
// so coming back to a package nothing has changed draws what was already
// read instead of asking for all of it again.
//
// Kept by the page's whole address, never by kind and name: an installation
// nothing recorded can wear the same kind and name as a package that IS
// recorded, and each must open on its own answer. Kept only while current:
// the installed commit and the writes landed at the place still match, and
// [retainedReads] has not moved since the read began. A read that failed
// is drawn as it failed and asked again on the next visit, never reused.
import { create } from "zustand";
import {
  commands,
  type ItemSource,
  type PackageFile,
  type PackageMeta_Serialize,
  type SourceReadRefused,
  type VersionRow,
} from "@/bindings";
import { addressesDeclaration } from "@/lib/package-identity";
import {
  type PackageReads,
  SOURCE_READ_LANDED,
  SOURCE_READ_PENDING,
  sourceReadOf,
} from "@/lib/package-read-state";
import { READ_LANDED, READ_PENDING, readOf, readOrder } from "@/lib/read-state";
import { scopeKey } from "@/lib/scope";
import { settled } from "@/lib/settled";
import { retainedReads } from "./editor-cache";
import type { PackageRef } from "./nav";

/** What the page's reads answer about besides the address: the commit
 *  installed at the page's place, and how many writes have landed there.
 *  `use-package-data.ts` says why both. */
export interface PackageInputs {
  commit: string;
  written: string;
}

type FileAnswer =
  | { status: "ok"; data: ItemSource }
  | { status: "error"; error: SourceReadRefused | string };

/** One file opened on the Files tab. */
export interface OpenedFile {
  /** When its read began, on [retainedReads]. */
  at: number;
  /** Null while the read is out. */
  answer: FileAnswer | null;
}

export interface PackageAnswer {
  /** When the read behind these values began, on [retainedReads]. */
  at: number;
  /** Which read of this address wrote them. */
  ticket: number;
  inputs: PackageInputs;
  meta: PackageMeta_Serialize | null;
  files: PackageFile[];
  readme: ItemSource | null;
  versions: VersionRow[];
  reads: PackageReads;
  /** Files opened on the Files tab, by path, read under this `ticket`. */
  opened: Record<string, OpenedFile>;
}

/** No read has answered yet: the first load's own state. */
export const PACKAGE_UNREAD: PackageReads = {
  record: READ_PENDING,
  timeline: SOURCE_READ_PENDING,
  files: SOURCE_READ_PENDING,
  readme: SOURCE_READ_PENDING,
  reading: true,
};

/** The page's whole address as one key. */
export const packageReadKey = (ref: PackageRef): string =>
  JSON.stringify([
    scopeKey(ref.scope),
    ref.kind,
    ref.name,
    ref.identity,
    ref.at ?? null,
  ]);

export const usePackageReads = create<{
  answers: Record<string, PackageAnswer>;
}>(() => ({ answers: {} }));

// One order per address. Reads of one package overlap on every ordinary
// path — a focus moving the commit under a mount, the read-back behind a
// version switch — and only the newest-begun may write; two addresses are
// not competing answers.
const orders = new Map<string, ReturnType<typeof readOrder>>();
const orderOf = (key: string) => {
  let order = orders.get(key);
  if (!order) {
    order = readOrder();
    orders.set(key, order);
  }
  return order;
};

/** Change one address's answer where it is held; null leaves it alone. */
const put = (
  key: string,
  change: (held: PackageAnswer) => PackageAnswer | null,
) =>
  usePackageReads.setState((state) => {
    const held = state.answers[key];
    const next = held ? change(held) : null;
    return next ? { answers: { ...state.answers, [key]: next } } : state;
  });

const landed = (reads: PackageReads): boolean =>
  !reads.reading &&
  [
    reads.record.status,
    reads.timeline.read.status,
    reads.files.read.status,
    reads.readme.read.status,
  ].every((status) => status === "landed");

/** Whether `held` is what a read begun now would be asked under. */
const current = (held: PackageAnswer, inputs: PackageInputs): boolean =>
  held.inputs.commit === inputs.commit &&
  held.inputs.written === inputs.written &&
  !retainedReads.stale(held.at);

/** Read the package unless what is held still answers: landed in full, or
 *  on its way, under the same inputs and nothing moved since. */
export function ensurePackage(ref: PackageRef, inputs: PackageInputs): void {
  const held = usePackageReads.getState().answers[packageReadKey(ref)];
  if (
    held &&
    current(held, inputs) &&
    (held.reads.reading || landed(held.reads) || !addressesDeclaration(ref))
  )
    return;
  readPackage(ref, inputs, "afresh");
}

/** Read the package's four answers. The README is one of them, read here
 *  rather than by the pane that draws it: an update or a version switch
 *  rewrites the installed files without moving the address, so a read
 *  keyed on the name alone would go on showing the replaced copy's words.
 *
 *  `kept` leaves the last answers on screen while the read runs — the
 *  page's own Try again and the read-back behind a version switch, where a
 *  failure not yet disproved is still the truth. `afresh` starts from
 *  nothing, so an answer that stopped being current never stands under the
 *  controls it would enable. */
export function readPackage(
  ref: PackageRef,
  inputs: PackageInputs,
  from: "afresh" | "kept",
): void {
  const key = packageReadKey(ref);
  const order = orderOf(key);
  const ticket = order.begin();
  const at = retainedReads.since();
  // A page about an installation nothing recorded has no declaration to
  // read. Its address — this scope, kind and name — may belong to a
  // package that IS recorded, and asking these four for it would put that
  // package's record, files and version history under this one's name.
  // The reads are not merely hidden: they are never issued, so there is
  // nothing on hand for a later surface to draw from.
  if (!addressesDeclaration(ref)) {
    order.lands(ticket);
    usePackageReads.setState((state) => ({
      answers: {
        ...state.answers,
        [key]: {
          at,
          ticket,
          inputs,
          meta: null,
          files: [],
          readme: null,
          versions: [],
          reads: {
            record: READ_LANDED,
            timeline: SOURCE_READ_LANDED,
            files: SOURCE_READ_LANDED,
            readme: SOURCE_READ_PENDING,
            reading: false,
          },
          opened: {},
        },
      },
    }));
    return;
  }
  usePackageReads.setState((state) => {
    const held = state.answers[key];
    const start =
      from === "kept" && held
        ? { ...held, reads: { ...held.reads, reading: true } }
        : {
            meta: null,
            files: [],
            readme: null,
            versions: [],
            reads: PACKAGE_UNREAD,
          };
    return {
      answers: {
        ...state.answers,
        [key]: { ...start, at, ticket, inputs, opened: {} },
      },
    };
  });
  let left = 4;
  // Whether this answer is the newest read's to write, and the last of its
  // four when it is. A superseded read never reaches its own count, so the
  // read on screen is the only one that can say it has finished.
  const lands = (write: (held: PackageAnswer) => PackageAnswer) => {
    if (!order.lands(ticket)) return;
    left -= 1;
    put(key, (held) => {
      const next = write(held);
      return left === 0
        ? { ...next, reads: { ...next.reads, reading: false } }
        : next;
    });
  };
  // `settled` on all four: it normalizes a refusal that says nothing, and
  // a landing that never ran would leave the read pending for the life of
  // the page, with the rejection going out unhandled.
  const { scope, kind, name } = ref;
  void settled(commands.packageMeta(scope, kind, name)).then((response) =>
    lands((held) => ({
      ...held,
      meta: response.status === "ok" ? response.data : null,
      reads: { ...held.reads, record: readOf(response) },
    })),
  );
  void settled(commands.packageFiles(scope, kind, name)).then((response) =>
    lands((held) => ({
      ...held,
      files: response.status === "ok" ? response.data : [],
      reads: { ...held.reads, files: sourceReadOf(response) },
    })),
  );
  void settled(commands.packageReadme(scope, kind, name)).then((response) =>
    lands((held) => ({
      ...held,
      readme: response.status === "ok" ? response.data : null,
      reads: { ...held.reads, readme: sourceReadOf(response) },
    })),
  );
  void settled(commands.packageVersions(scope, kind, name)).then((response) =>
    lands((held) => ({
      ...held,
      versions: response.status === "ok" ? response.data : [],
      reads: { ...held.reads, timeline: sourceReadOf(response) },
    })),
  );
}

/** Read one of the package's files unless it is held from a read that
 *  landed and is still current. A failed read is asked again here: this
 *  runs when the pane opens on the file, and a failure is the last
 *  attempt's answer, not the file's. */
export function ensureFile(ref: PackageRef, path: string): void {
  const key = packageReadKey(ref);
  const held = usePackageReads.getState().answers[key];
  if (!held) return;
  const slot = held.opened[path];
  if (slot && !retainedReads.stale(slot.at) && slot.answer?.status !== "error")
    return;
  const placed: OpenedFile = { at: retainedReads.since(), answer: null };
  const { ticket } = held;
  put(key, (now) => ({ ...now, opened: { ...now.opened, [path]: placed } }));
  void settled(commands.packageFile(ref.scope, ref.kind, ref.name, path)).then(
    (answer) =>
      // Only into the slot this read was placed in: a re-read of the package
      // since then empties `opened`, and a newer read of the file replaces it.
      put(key, (now) =>
        now.ticket === ticket && now.opened[path] === placed
          ? { ...now, opened: { ...now.opened, [path]: { ...placed, answer } } }
          : null,
      ),
  );
}
