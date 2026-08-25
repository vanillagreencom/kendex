// The words for one state: kendex.toml asks for something, and files are
// already where it goes. "Adopt" and "take over" are the engine's words for
// keeping them; what a person needs is what happens to the files in front
// of them.
export const keepFilesConfirmTitle = (name: string): string =>
  `Keep ${name}'s files?`;
export const KEEP_FILES_CONFIRM_LABEL = "Keep them";
// Keeping a folder several tools read through shortcuts they set up is a
// bigger move than keeping a plain folder, so the words for it say what
// happens to the folder itself. The last sentence is the one honest
// warning — shortcuts kendex cannot see will break, and there is no way to
// list them.
export const keepSharedBody = (target: string, tools: string[]): string =>
  `${tools.join(" and ")} read this skill from ${target}. kendex moves the folder's content into its own keeping — the folder goes to the trash, where you can get it back — and points them at kendex's copy, so they stay in sync. Anything else pointing at the old folder stops working.`;
