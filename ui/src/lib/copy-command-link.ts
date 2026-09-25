// The kendex command the macOS app carries: what the first-launch question
// and the Settings row say in every state they can reach. The paths are
// arguments, read off the backend's answer, never spelled here.

import type { CommandLink } from "@/bindings";

export const COMMAND_LINK_TITLE = "Install the kendex command?";
export const COMMAND_LINK_DONE_TITLE = "The kendex command is installed";
export const COMMAND_LINK_NOT_INSTALLED_TITLE =
  "The kendex command was not installed";

export const COMMAND_LINK_SECTION = "Command line";
export const COMMAND_LINK_ROW_LABEL = "kendex command";

export const INSTALL_LABEL = "Install";
export const INSTALLING_LABEL = "Installing…";
export const REPOINT_LABEL = "Link to this app";
export const DECLINE_LABEL = "Don't install";
export const TRY_AGAIN_LABEL = "Try again";
export const DONE_LABEL = "Done";
export const CLOSE_LABEL = "Close";

/** What an install does, stated as the file it creates. */
export const createsLink = (link: string, target: string) =>
  `Creates a link at ${link} to the command inside this app, ${target}, so kendex runs in any terminal window. macOS asks for an administrator password once.`;

/** The link leads to another copy of kendex, which the install replaces. */
export const repointsLink = (link: string, replaces: string) =>
  `${link} runs an older copy of kendex at ${replaces}. Installing points it at this app instead; macOS asks for an administrator password once.`;

export const LATER_IN_SETTINGS =
  "If you don't install it now, Settings has it later.";

export const WAITING_FOR_PASSWORD = "Waiting for the administrator password…";

export const CANCELLED_LINE =
  "The administrator prompt was closed, so nothing was installed.";

export const installedLine = (link: string) =>
  `${link} now runs the command inside this app. Open a new terminal window and run kendex --version.`;

export const failedLine = (message: string) =>
  `Nothing was installed: ${message}`;

/** What the Settings row says the command's standing is, and — after an
 *  install that was refused — why. One sentence per kind, so the dialog
 *  and the row cannot describe one state two ways. */
export function standing(command: CommandLink): string {
  switch (command.kind) {
    case "notCarried":
      return "This build of kendex carries no command to install.";
    case "translocated":
      return "macOS is running kendex from a temporary copy. Move kendex to your Applications folder and open it from there to install the command.";
    case "linked":
      return `${command.link} runs the command inside this app.`;
    case "offered":
      return command.replaces === null
        ? createsLink(command.link, command.target)
        : repointsLink(command.link, command.replaces);
    case "elsewhere":
      return `A kendex command is already installed at ${command.path}.`;
    case "taken":
      return `${command.link} is a file kendex did not create, so kendex leaves it alone. Move it aside to install the command here.`;
    default: {
      const unreachable: never = command;
      return unreachable;
    }
  }
}

/** The one-word status beside the row's label. */
export function standingWord(command: CommandLink): string {
  switch (command.kind) {
    case "notCarried":
    case "translocated":
    case "taken":
      return "not installed";
    case "offered":
      return command.replaces === null ? "not installed" : "older copy";
    case "linked":
    case "elsewhere":
      return "installed";
    default: {
      const unreachable: never = command;
      return unreachable;
    }
  }
}

export const answerNotRecorded = (message: string) =>
  `kendex could not record your answer, so it will ask again next launch: ${message}`;
