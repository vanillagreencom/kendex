/**
 * Build the provider input Pi hands `streamSimple` on 0.86 and newer.
 *
 * Pi normalizes every provider call through its own `normalizeContext`, which
 * folds the system prompt and the tool declarations into a leading `system`
 * entry of `messages` and carries no `systemPrompt` or `tools` field. Tests call
 * that function rather than hand-shaping the entry, so a later transcript-format
 * change reaches the suite instead of passing against a shape only this
 * repository believes in.
 */
import { normalizeContext } from "@earendil-works/pi-ai";

export function piContext({ messages = [], tools, systemPrompt } = {}) {
	return normalizeContext({ messages, tools, systemPrompt });
}
