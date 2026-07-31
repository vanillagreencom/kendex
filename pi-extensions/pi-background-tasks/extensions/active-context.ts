/**
 * Decide whether an incoming ExtensionContext may replace the retained "active"
 * context.
 *
 * The retained context drives UI delivery (mini-dashboard widget, notify) and
 * project-scoped settings lookups keyed on `activeCtx?.cwd`. Pi 0.83.0 routed
 * direct RPC bash commands through extension `user_bash` handlers
 * (earendil-works/pi#7214). Before that, `user_bash` only fired for interactive
 * `!`/`!!` input, so every context this extension saw carried the interactive
 * session's UI and cwd.
 *
 * An RPC context has no UI and may carry an unrelated cwd. Adopting one
 * downgrades `activeCtx`, and the next refreshUi() then evaluates
 * shouldRenderBackgroundWidget({ hasUi: false, ... }) and tears the widget down
 * until some later UI-bearing event happens to restore it.
 *
 * So a UI-bearing context is never replaced by a non-UI one. Headless runs
 * (`pi -p`, where no context has a UI) still adopt normally, because there is no
 * UI-bearing context to protect.
 */
export function shouldAdoptActiveContext(current: { hasUI?: boolean } | null | undefined, incoming: { hasUI?: boolean }): boolean {
	if (!current) return true;
	if (incoming.hasUI === true) return true;
	return current.hasUI !== true;
}
