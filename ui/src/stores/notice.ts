import { create } from "zustand";
import { type CommandNotice, commands, type InstallChannel } from "@/bindings";
import { SETTINGS_MOVED_MESSAGE } from "@/lib/copy";
import { settled } from "@/lib/settled";

/** The two versions the card names. Null until a check has found this
 *  build behind a release, and null again once this version is hidden. */
export interface AppUpdateNotice {
  /** What is running now. */
  current: string;
  /** The release it is behind. */
  latest: string;
  releaseNotesUrl: string;
}

/** A channel nothing could resolve offers what an unrecognised one
 *  offers: name the release, replace nothing, invent no command. */
const UNRESOLVED: InstallChannel = { kind: "unknown" };

interface NoticeState {
  notice: AppUpdateNotice | null;
  /** Which action the card may offer. Read once beside the check. */
  channel: InstallChannel;
  /** What the card owes a person about the `kendex` command beside this
   *  app: who owns it where kendex does not, or the one command that moves
   *  a command kendex owns but cannot write. Null when there is no command
   *  here or when Update now will carry it across. */
  commandChannel: CommandNotice | null;
  /** A replacement is running. There are no progress events, so this is
   *  the whole of what the card can say about it. */
  installing: boolean;
  /** Why the last action on the card did not happen, shown on the card
   *  with the app still usable. */
  error: string | null;
  /** What an install that went through still owed the person about the
   *  `kendex` command beside the app. Not a failure: the release is
   *  installed and the next launch is what completes it, so the card says
   *  this and stops offering to run the update again. */
  note: string | null;
  load: () => Promise<void>;
  install: () => Promise<void>;
  openNotes: () => Promise<void>;
  dismiss: () => Promise<void>;
}

/** Hide this version's notice and only this version's: the field holds one
 *  version, so a later release notifies again. The file is read on the
 *  spot and written back with the base that read returned, so the copy
 *  written is never older than the file. Returns the reason it did not
 *  happen, or null. */
async function mute(version: string): Promise<string | null> {
  const read = await settled(commands.getSettings());
  if (read.status === "error") return read.error;
  try {
    const written = await commands.updateSettings(
      { ...read.data.settings, "muted-app-notice": version },
      read.data.base,
    );
    if (written.status === "ok") return null;
    return written.error.kind === "failed"
      ? written.error.message
      : SETTINGS_MOVED_MESSAGE;
  } catch (thrown) {
    return thrown instanceof Error ? thrown.message : String(thrown);
  }
}

/**
 * The app's own out-of-date notice: one read at startup, one card in the
 * sidebar, and the one action the running install's channel allows.
 *
 * A check that failed shows nothing. The card states that a named release
 * is out, which a failed read is no evidence of, and the release check
 * keeps its own error for the surface that reports on checking.
 */
export const useNoticeStore = create<NoticeState>((set, get) => ({
  notice: null,
  channel: UNRESOLVED,
  commandChannel: null,
  installing: false,
  error: null,
  note: null,

  load: async () => {
    const [view, channel, commandChannel, current] = await Promise.all([
      settled(commands.appUpdateCheck(false)),
      settled(commands.appUpdateChannel()),
      settled(commands.appUpdateCommandChannel()),
      // The running version is the half of the sentence the release feed
      // cannot supply; without it there is no notice to write.
      commands.appVersion().catch(() => null),
    ]);
    if (view.status === "error" || current === null) return;
    const status = view.data.status;
    if (status.kind !== "updateAvailable" || status.muted) return;
    set({
      notice: {
        current,
        latest: status.version,
        releaseNotesUrl: status.releaseNotesUrl,
      },
      channel: channel.status === "ok" ? channel.data : UNRESOLVED,
      // A read that failed says nothing rather than guessing: the note is
      // about a command this app will not touch, and inventing one would
      // send a person to a package manager that does not own it.
      commandChannel:
        commandChannel.status === "ok" ? commandChannel.data : null,
      // A card being drawn again says nothing about an install before it.
      note: null,
    });
  },

  install: async () => {
    if (get().installing) return;
    set({ installing: true, error: null, note: null });
    // What the card is showing about the command beside the app, handed
    // over so the engine can say when the command it found was not the one
    // this card described. The card is the only place that sentence could
    // be read, and a successful install takes the card away with the
    // restart.
    const response = await settled(
      commands.appUpdateInstall(get().commandChannel),
    );
    // A replacement that restarts does not come back: the app relaunches
    // into the new version. What does come back is an install that failed,
    // or one that went through with something still to say about the
    // command beside the app — told apart here rather than read out of the
    // sentence, because a person whose update worked must not be shown a
    // failure and invited to run it again.
    if (response.status === "ok" && response.data === null) return;
    set(
      response.status === "ok"
        ? { installing: false, note: response.data }
        : { installing: false, error: response.error },
    );
    // Either answer is about a command that may have moved, so what the
    // card says about it is read again — and a read that failed says
    // nothing rather than guessing, the same rule the first read follows.
    // Kept, the description would be the one drawn before the install, and
    // the card would be describing a machine as it no longer is with no
    // action left on it to ask again.
    const fresh = await settled(commands.appUpdateCommandChannel());
    set({ commandChannel: fresh.status === "ok" ? fresh.data : null });
  },

  openNotes: async () => {
    const notice = get().notice;
    if (notice === null) return;
    const response = await settled(commands.openUrl(notice.releaseNotesUrl));
    if (response.status === "error") set({ error: response.error });
  },

  dismiss: async () => {
    const notice = get().notice;
    // Never while a replacement is running. Hiding the card takes away the
    // only thing that would report a failure, and the mute is keyed to
    // this version, so a replacement that then fails leaves the person on
    // the old build with nothing to say so and no second offer.
    if (notice === null || get().installing) return;
    const refused = await mute(notice.latest);
    if (refused === null) set({ notice: null, error: null, note: null });
    else set({ error: refused });
  },
}));
