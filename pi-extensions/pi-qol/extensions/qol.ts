import type { ExtensionAPI, ExtensionCommandContext, ExtensionContext } from "@earendil-works/pi-coding-agent";
import type { TUI } from "@earendil-works/pi-tui";
import { criticalInfo, lastAssistantTextFromAgentEnd, needsDirection, taskStats } from "./qol/agent-end.js";
import { getQuestionService, readCavemanBridge, type QuestionOpenedEventLike } from "./qol/bridges.js";
import { BudgetGuardDriver } from "./qol/budget-guard-runtime.js";
import {
	budgetGuardTrigger,
	compactionTriggerReason,
	handleQolBranchSummary,
	handleQolCompaction,
} from "./qol/compaction.js";
import {
	CONTEXT_USAGE_MESSAGE_TYPE,
	DEFAULT_IDLE_COMPACTION_SECONDS,
	DEFAULT_INPUT_BOTTOM_PADDING_LINES,
	INSTALL_SYMBOL,
	QOL_NOTIFICATION_SERVICE_SYMBOL,
	QUESTION_OPENED_EVENT,
	SESSION_MANAGER_STATUS_KEY,
	SESSION_SEARCH_CONTEXT_TYPE,
	SESSION_SEARCH_STATUS_KEY,
	SESSION_TITLE_SYNC_INTERVAL_MS,
	STATUS_KEY,
	THINKING_TIMER_STORE_SYMBOL,
	TMUX_SESSION_TITLE_BORDER_FORMAT,
} from "./qol/constants.js";
import { buildQolContextUsageDetails, renderQolContextUsageMessage } from "./qol/context-usage.js";
import {
	getQolArgumentCompletions,
	getSessionSearchArgumentCompletions,
	installAutocompleteHintStyling,
	QolCompactPromptEditor,
	QolEditor,
} from "./qol/editor.js";
import { runHandoff } from "./qol/handoff.js";
import { imageContentForPath, resolveSubmittedImagePaths } from "./qol/images.js";
import {
	clearTmuxWindowMark,
	notifyQuestionOpened,
	sendQolNotification,
	type QolNotificationService,
} from "./qol/notifications.js";
import {
	installPendingQueueThemePatch,
	installStatusTextAlignmentPatch,
	restorePendingQueueThemePatch,
} from "./qol/pending-queue.js";
import { permissionGateMatch, permissionGatePrompt } from "./qol/permission-gate.js";
import {
	autoRenameEnabled,
	autoRenameNotify,
	conversationTranscriptText,
	firstUserMessageText,
	generateAutoRenameName,
	isStaleCtxError,
	withAutoRenamePrefix,
} from "./qol/session-rename.js";
import {
	consumePendingSessionSearchContext,
	openQolSessionSearch,
	qolSessionSearchPendingActions,
	refreshQolSessionSearchCache,
	renderSessionSearchContextMessage,
	runSessionSearchResumeOrFork,
	sessionSearchShortcut,
} from "./qol/session-search/index.js";
import { settingBoolean, settingNumber, settingString } from "./qol/settings.js";
import { statusMessage } from "./qol/status-message.js";
import {
	formatTmuxSessionTitle,
	makeFallbackGitState,
	normalizedSessionName,
	readTmuxPaneTitle,
	readTmuxWindowName,
	readTmuxWindowOption,
	refreshGitState,
	renderStatusLine,
	sessionNameHeader,
	setTmuxPaneTitle,
	setTmuxWindowName,
	setTmuxWindowOption,
	tmuxPaneTarget,
	type GitState,
} from "./qol/statusline.js";
import {
	hiddenThinkingLabel,
	installThinkingTimerPatch,
	thinkingTimerKey,
	thinkingTimerLabel,
	type ThinkingTimerStore,
} from "./qol/thinking-timer.js";
import { stringifyError } from "./qol/util.js";

export default function qol(pi: ExtensionAPI): void {
	const guard = pi as unknown as Record<PropertyKey, unknown>;
	if (guard[INSTALL_SYMBOL]) return;
	guard[INSTALL_SYMBOL] = true;
	if (!settingBoolean("enabled", true)) return;

	installThinkingTimerPatch();
	installStatusTextAlignmentPatch();
	const thinkingTimerStore: ThinkingTimerStore = {
		enabled: false,
		starts: new Map(),
		durations: new Map(),
		labels: new Map(),
	};
	(globalThis as unknown as Record<PropertyKey, unknown>)[THINKING_TIMER_STORE_SYMBOL] = thinkingTimerStore;

	let idleCompactionTimer: ReturnType<typeof setTimeout> | undefined;
	let questionSubscribeTimer: ReturnType<typeof setInterval> | undefined;
	let sessionSearchWarmupTimer: ReturnType<typeof setTimeout> | undefined;
	let thinkingTimerTicker: ReturnType<typeof setInterval> | undefined;
	let questionUnsubscribe: (() => void) | undefined;
	let lastTaskStats: { completed: number; remaining: number; total: number } | undefined;
	let autoRenameAttempted = false;
	let autoRenameInProgress = false;
	let autoRenameGeneration = 0;
	let latestSystemPromptOptions: unknown;

	const resetAutoRename = () => {
		autoRenameAttempted = false;
		autoRenameInProgress = false;
		autoRenameGeneration += 1;
	};

	const attemptAutoRename = async (ctx: ExtensionContext, options: { force?: boolean; fullConversation?: boolean; notify?: boolean } = {}) => {
		// All ctx reads here can throw if the captured context has been replaced
		// by newSession / fork / switchSession / reload. Wrap the whole body so
		// a stale ctx aborts the rename quietly instead of crashing pi (and
		// killing the in-flight tool dispatch that triggered agent_end).
		try {
			const force = options.force === true;
			let cwd: string | undefined;
			try {
				cwd = ctx.cwd;
			} catch (error) {
				if (isStaleCtxError(error)) return;
				throw error;
			}
			if (!force && !autoRenameEnabled(cwd)) return;
			if (autoRenameInProgress) return;
			if (!force && (autoRenameAttempted || pi.getSessionName())) return;
			let branch;
			try {
				branch = ctx.sessionManager.getBranch?.() ?? [];
			} catch (error) {
				if (isStaleCtxError(error)) return;
				throw error;
			}
			const maxInputChars = Math.max(200, Math.floor(settingNumber("sessionAutoRename.maxInputChars", 2000, cwd)));
			const sourceText = options.fullConversation ? conversationTranscriptText(branch, maxInputChars) : firstUserMessageText(branch);
			if (!sourceText) {
				if (force) autoRenameNotify(ctx, "No user message found to name this session.", "warning", true);
				return;
			}
			const generation = autoRenameGeneration;
			if (!force) autoRenameAttempted = true;
			autoRenameInProgress = true;
			try {
				const result = await generateAutoRenameName(sourceText, ctx, options.fullConversation === true);
				if (generation !== autoRenameGeneration) return;
				if (!result.name) {
					autoRenameNotify(ctx, "No session name generated.", "warning", options.notify === true || force);
					return;
				}
				if (!force && pi.getSessionName()) return;
				const name = withAutoRenamePrefix(result.name, cwd);
				if (!name) return;
				pi.setSessionName(name);
				autoRenameNotify(ctx, `Session named: ${name} (${result.source})`, "info", options.notify === true || force);
			} finally {
				if (generation === autoRenameGeneration) autoRenameInProgress = false;
			}
		} catch (error) {
			if (isStaleCtxError(error)) return;
			throw error;
		}
	};

	const stopThinkingTimerTicker = () => {
		if (thinkingTimerTicker) clearInterval(thinkingTimerTicker);
		thinkingTimerTicker = undefined;
	};

	const tickThinkingTimer = () => {
		if (!thinkingTimerStore.enabled || thinkingTimerStore.starts.size === 0) {
			stopThinkingTimerTicker();
			return;
		}
		for (const [key, start] of thinkingTimerStore.starts.entries()) {
			const label = thinkingTimerStore.labels.get(key);
			if (label) label.setText(thinkingTimerLabel(thinkingTimerStore.theme, Date.now() - start, thinkingTimerStore.cwd));
		}
	};

	const startThinkingTimerTicker = () => {
		if (thinkingTimerTicker) return;
		// 250ms cadence (was 100ms): user-visible precision of "thinking 1.2s" still feels live,
		// but render rate drops 2.5x. Every tick mutates an inline chat label, which makes the
		// pi-tui above-viewport diff (firstChanged < prevViewportTop) fire as full-screen redraws.
		thinkingTimerTicker = setInterval(tickThinkingTimer, 250);
		thinkingTimerTicker.unref?.();
	};

	const resetThinkingTimer = (ctx?: ExtensionContext) => {
		stopThinkingTimerTicker();
		thinkingTimerStore.starts.clear();
		thinkingTimerStore.durations.clear();
		thinkingTimerStore.labels.clear();
		thinkingTimerStore.cwd = ctx?.cwd;
		thinkingTimerStore.theme = ctx?.ui.theme;
		thinkingTimerStore.enabled = !!ctx?.hasUI && settingBoolean("thinkingTimer.enabled", true, ctx?.cwd);
	};

	// Working indicator mode.
	// The built-in pi-tui Loader ticks every 80ms during streaming. Each tick
	// mutates a line in statusContainer; once total rendered content exceeds the
	// terminal viewport (overlay content like /tree, or chat overflow), every tick
	// trips pi-tui's firstChanged < prevViewportTop branch and triggers a full
	// screen + scrollback clear (visible flash). This setting lets the user trade
	// the spinner animation away for a stable display in overflow scenarios.
	// Implementation note: Loader.restartAnimation() bails out when frames.length
	// is <= 1, so a single-frame indicator does NOT start the setInterval at all.
	const applyWorkingIndicatorMode = (ctx: ExtensionContext): void => {
		if (!ctx.hasUI) return;
		const mode = settingString("workingIndicator.mode", "animated", ctx.cwd);
		if (mode === "static") {
			ctx.ui.setWorkingVisible(true);
			ctx.ui.setWorkingIndicator({ frames: [ctx.ui.theme.fg("accent", "●")] });
			return;
		}
		ctx.ui.setWorkingVisible(true);
		ctx.ui.setWorkingIndicator(undefined);
	};

	const updateThinkingTimerEnabled = (ctx: ExtensionContext): boolean => {
		thinkingTimerStore.cwd = ctx.cwd;
		thinkingTimerStore.theme = ctx.ui.theme;
		const enabled = ctx.hasUI && settingBoolean("thinkingTimer.enabled", true, ctx.cwd);
		if (thinkingTimerStore.enabled && !enabled) resetThinkingTimer(ctx);
		thinkingTimerStore.enabled = enabled;
		return enabled;
	};

	const finalizeThinkingBlock = (key: string, endTimeMs = Date.now()) => {
		const start = thinkingTimerStore.starts.get(key);
		if (start === undefined) return;
		const duration = Math.max(0, endTimeMs - start);
		thinkingTimerStore.starts.delete(key);
		thinkingTimerStore.durations.set(key, duration);
		const label = thinkingTimerStore.labels.get(key);
		if (label) label.setText(thinkingTimerLabel(thinkingTimerStore.theme, duration, thinkingTimerStore.cwd));
		if (thinkingTimerStore.starts.size === 0) stopThinkingTimerTicker();
	};

	const clearIdleCompactionTimer = () => {
		if (idleCompactionTimer) clearTimeout(idleCompactionTimer);
		idleCompactionTimer = undefined;
	};

	const budgetGuardDriver = new BudgetGuardDriver();

	const resetBudgetGuard = () => {
		budgetGuardDriver.reset();
	};

	const maybeFireBudgetGuard = (ctx: ExtensionContext) => {
		let trigger;
		try {
			trigger = budgetGuardTrigger(ctx);
		} catch (error) {
			if (isStaleCtxError(error)) return;
			throw error;
		}
		const notifySafely = (message: string, level: "info" | "warning" | "error") => {
			try {
				if (ctx.hasUI && settingBoolean("compaction.notify", true, ctx.cwd)) ctx.ui.notify(message, level);
			} catch (error) {
				if (isStaleCtxError(error)) return;
				throw error;
			}
		};
		budgetGuardDriver.dispatch({
			compact: typeof ctx.compact === "function" ? ctx.compact.bind(ctx) : undefined,
			notify: notifySafely,
			trigger,
		});
	};

	const scheduleIdleCompaction = (ctx: ExtensionContext) => {
		clearIdleCompactionTimer();
		if (!settingBoolean("compaction.idleEnabled", false, ctx.cwd)) return;
		const reason = compactionTriggerReason(ctx);
		if (!reason) return;
		const delayMs = Math.max(1, Math.floor(settingNumber("compaction.idleTimeoutSeconds", DEFAULT_IDLE_COMPACTION_SECONDS, ctx.cwd))) * 1000;
		idleCompactionTimer = setTimeout(() => {
			idleCompactionTimer = undefined;
			// Same stale-ctx risk as auto-rename: the captured ctx may be invalidated
			// by newSession/fork/switchSession/reload between schedule and fire.
			// Bail silently if so; the next session_start will reschedule.
			try {
				if (!ctx.isIdle?.()) return;
			} catch (error) {
				if (isStaleCtxError(error)) return;
				throw error;
			}
			const latestReason = compactionTriggerReason(ctx);
			if (!latestReason) return;
			const notifySafely = (message: string, level: "info" | "error") => {
				try {
					if (ctx.hasUI && settingBoolean("compaction.notify", true, ctx.cwd)) ctx.ui.notify(message, level);
				} catch (error) {
					if (isStaleCtxError(error)) return;
					throw error;
				}
			};
			notifySafely(`QOL idle compaction starting: ${latestReason}`, "info");
			try {
				ctx.compact?.({
					customInstructions: `QOL idle compaction triggered after inactivity because ${latestReason}. Preserve current task state, decisions, files, blockers, and next steps.`,
					onComplete: () => notifySafely("QOL idle compaction completed.", "info"),
					onError: (error: Error) => notifySafely(`QOL idle compaction failed: ${stringifyError(error)}`, "error"),
				});
			} catch (error) {
				if (isStaleCtxError(error)) return;
				throw error;
			}
		}, delayMs);
		idleCompactionTimer.unref?.();
	};

	const clearQuestionSubscribeTimer = () => {
		if (questionSubscribeTimer) clearInterval(questionSubscribeTimer);
		questionSubscribeTimer = undefined;
	};

	const subscribeToQuestions = (ctx: ExtensionContext): boolean => {
		if (questionUnsubscribe) return true;
		const service = getQuestionService();
		if (!service) return false;
		questionUnsubscribe = service.subscribe((event: any) => {
			if (event?.action !== "opened") return;
			notifyQuestionOpened(ctx, { requestId: event.requestId, request: event.request, source: event.source }, "question");
		});
		return true;
	};

	const startQuestionSubscription = (ctx: ExtensionContext) => {
		if (subscribeToQuestions(ctx) || questionSubscribeTimer) return;
		let attempts = 0;
		questionSubscribeTimer = setInterval(() => {
			attempts += 1;
			if (subscribeToQuestions(ctx) || attempts >= 40) clearQuestionSubscribeTimer();
		}, 250);
		questionSubscribeTimer.unref?.();
	};

	let pendingTaskCompleteNotification: string | undefined;
	let activeTui: TUI | undefined;
	let gitState: GitState | undefined;
	let refreshInFlight: Promise<void> | undefined;
	let sessionTitleTimer: ReturnType<typeof setInterval> | undefined;
	let tmuxPaneTitleTarget: string | undefined;
	let tmuxOriginalPaneTitle: string | undefined;
	let tmuxOriginalPaneBorderStatus: string | undefined;
	let tmuxOriginalPaneBorderFormat: string | undefined;
	let tmuxChangedPaneBorderStatus = false;
	let tmuxChangedPaneBorderFormat = false;
	let tmuxLastPaneTitle: string | undefined;
	let tmuxOriginalWindowNameTitle: string | undefined;
	let tmuxOriginalAutomaticRename: string | undefined;
	let tmuxChangedAutomaticRename = false;
	let tmuxLastWindowNameTitle: string | undefined;
	let lastSessionTitle: string | undefined;

	const requestRender = () => activeTui?.requestRender();
	const refreshStatusline = (ctx: ExtensionContext) => {
		if (refreshInFlight) return refreshInFlight;
		refreshInFlight = refreshGitState(pi, ctx)
			.then((next) => {
				gitState = next;
				requestRender();
			})
			.finally(() => {
				refreshInFlight = undefined;
			});
		return refreshInFlight;
	};

	const syncSessionTitle = (ctx: ExtensionContext) => {
		const sessionTitle = normalizedSessionName(pi);
		if (sessionTitle !== lastSessionTitle) {
			lastSessionTitle = sessionTitle;
			requestRender();
		}
		ctx.ui.setStatus(SESSION_MANAGER_STATUS_KEY, undefined);
		const target = tmuxPaneTitleTarget;
		if (!target) return;
		const nextTitle = sessionTitle ? formatTmuxSessionTitle(sessionTitle) : tmuxOriginalPaneTitle;
		if (nextTitle !== undefined && nextTitle !== tmuxLastPaneTitle) {
			tmuxLastPaneTitle = nextTitle;
			setTmuxPaneTitle(target, nextTitle);
		}
		if (settingBoolean("showSessionNameWindow", true, ctx.cwd)) {
			const nextWindow = sessionTitle ? formatTmuxSessionTitle(sessionTitle) : tmuxOriginalWindowNameTitle;
			if (nextWindow !== undefined && nextWindow !== tmuxLastWindowNameTitle) {
				tmuxLastWindowNameTitle = nextWindow;
				setTmuxWindowName(target, nextWindow);
			}
		}
	};

	const installSessionTitle = (ctx: ExtensionContext) => {
		if (!settingBoolean("showSessionNameTitle", true, ctx.cwd)) return;
		const tmuxTarget = tmuxPaneTarget();
		if (tmuxTarget) {
			tmuxPaneTitleTarget = tmuxTarget;
			readTmuxPaneTitle(tmuxTarget, (title) => {
				if (tmuxPaneTitleTarget !== tmuxTarget) return;
				tmuxOriginalPaneTitle = title;
				syncSessionTitle(ctx);
			});
			readTmuxWindowOption(tmuxTarget, "pane-border-status", (value) => {
				if (tmuxPaneTitleTarget !== tmuxTarget) return;
				tmuxOriginalPaneBorderStatus = value;
				if (!value || value === "off") {
					tmuxChangedPaneBorderStatus = true;
					setTmuxWindowOption(tmuxTarget, "pane-border-status", "top");
				}
			});
			readTmuxWindowOption(tmuxTarget, "pane-border-format", (value) => {
				if (tmuxPaneTitleTarget !== tmuxTarget) return;
				tmuxOriginalPaneBorderFormat = value;
				if (value !== TMUX_SESSION_TITLE_BORDER_FORMAT) {
					tmuxChangedPaneBorderFormat = true;
					setTmuxWindowOption(tmuxTarget, "pane-border-format", TMUX_SESSION_TITLE_BORDER_FORMAT);
				}
			});
			if (settingBoolean("showSessionNameWindow", true, ctx.cwd)) {
				readTmuxWindowName(tmuxTarget, (name) => {
					if (tmuxPaneTitleTarget !== tmuxTarget) return;
					tmuxOriginalWindowNameTitle = name;
					syncSessionTitle(ctx);
				});
				readTmuxWindowOption(tmuxTarget, "automatic-rename", (value) => {
					if (tmuxPaneTitleTarget !== tmuxTarget) return;
					tmuxOriginalAutomaticRename = value;
					if (value !== "off") {
						tmuxChangedAutomaticRename = true;
						setTmuxWindowOption(tmuxTarget, "automatic-rename", "off");
					}
				});
			}
			return;
		}
		ctx.ui.setHeader((tui, theme) => {
			activeTui = tui;
			return {
				invalidate() {},
				render(width: number): string[] {
					return sessionNameHeader(width, pi, theme);
				},
			};
		});
	};

	const installSessionTitleSync = (ctx: ExtensionContext) => {
		syncSessionTitle(ctx);
		sessionTitleTimer = setInterval(() => syncSessionTitle(ctx), SESSION_TITLE_SYNC_INTERVAL_MS);
		sessionTitleTimer.unref?.();
	};

	const resetStatuslineUi = (ctx: ExtensionContext) => {
		if (sessionTitleTimer) clearInterval(sessionTitleTimer);
		sessionTitleTimer = undefined;
		if (tmuxPaneTitleTarget && tmuxOriginalPaneTitle !== undefined) setTmuxPaneTitle(tmuxPaneTitleTarget, tmuxOriginalPaneTitle);
		if (tmuxPaneTitleTarget && tmuxChangedPaneBorderStatus && tmuxOriginalPaneBorderStatus !== undefined) setTmuxWindowOption(tmuxPaneTitleTarget, "pane-border-status", tmuxOriginalPaneBorderStatus);
		if (tmuxPaneTitleTarget && tmuxChangedPaneBorderFormat && tmuxOriginalPaneBorderFormat !== undefined) setTmuxWindowOption(tmuxPaneTitleTarget, "pane-border-format", tmuxOriginalPaneBorderFormat);
		if (tmuxPaneTitleTarget && tmuxOriginalWindowNameTitle !== undefined && tmuxLastWindowNameTitle !== undefined) setTmuxWindowName(tmuxPaneTitleTarget, tmuxOriginalWindowNameTitle);
		if (tmuxPaneTitleTarget && tmuxChangedAutomaticRename && tmuxOriginalAutomaticRename !== undefined) setTmuxWindowOption(tmuxPaneTitleTarget, "automatic-rename", tmuxOriginalAutomaticRename);
		tmuxPaneTitleTarget = undefined;
		tmuxOriginalPaneTitle = undefined;
		tmuxOriginalPaneBorderStatus = undefined;
		tmuxOriginalPaneBorderFormat = undefined;
		tmuxChangedPaneBorderStatus = false;
		tmuxChangedPaneBorderFormat = false;
		tmuxLastPaneTitle = undefined;
		tmuxOriginalWindowNameTitle = undefined;
		tmuxOriginalAutomaticRename = undefined;
		tmuxChangedAutomaticRename = false;
		tmuxLastWindowNameTitle = undefined;
		lastSessionTitle = undefined;
		ctx.ui.setStatus(SESSION_MANAGER_STATUS_KEY, undefined);
		ctx.ui.setWidget("statusline", undefined);
		ctx.ui.setHeader(undefined);
		ctx.ui.setFooter(undefined);
		activeTui = undefined;
	};

	const maybeNotifyTaskCompletion = (_ctx: ExtensionContext, state: any) => {
		const stats = taskStats(state);
		if (!stats) return;
		const previous = lastTaskStats;
		lastTaskStats = stats;
		if (stats.total === 0 || stats.remaining !== 0 || stats.completed !== stats.total) {
			pendingTaskCompleteNotification = undefined;
			return;
		}
		if (previous && previous.total === stats.total && previous.remaining === 0 && previous.completed === stats.completed) return;
		if (previous && previous.remaining <= 0) return;
		pendingTaskCompleteNotification = `Task list complete: ${stats.completed}/${stats.total} done.`;
	};

	let currentCtx: ExtensionContext | undefined;
	let cavemanUnsubscribe: (() => void) | undefined;
	const subscribeCavemanBridge = () => {
		cavemanUnsubscribe?.();
		cavemanUnsubscribe = undefined;
		const bridge = readCavemanBridge();
		if (!bridge) return;
		cavemanUnsubscribe = bridge.subscribe(() => requestRender());
	};
	const notificationService: QolNotificationService = {
		notifyQuestionOpened(ctx, event) {
			notifyQuestionOpened(ctx ?? currentCtx, event, "question");
			return true;
		},
	};
	(globalThis as unknown as Record<PropertyKey, unknown>)[QOL_NOTIFICATION_SERVICE_SYMBOL] = notificationService;

	pi.events.on(QUESTION_OPENED_EVENT, (data: unknown) => {
		if (!data || typeof data !== "object") return;
		const event = data as QuestionOpenedEventLike;
		notifyQuestionOpened(currentCtx, event, "question");
	});

	pi.on("session_start", (event, ctx) => {
		currentCtx = ctx;
		subscribeCavemanBridge();
		latestSystemPromptOptions = undefined;
		resetAutoRename();
		resetBudgetGuard();
		resetThinkingTimer(ctx);
		void consumePendingSessionSearchContext(pi, ctx, event.reason);
		installAutocompleteHintStyling(ctx);
		installPendingQueueThemePatch(ctx);
		if (ctx.hasUI) {
			ctx.ui.setHiddenThinkingLabel(hiddenThinkingLabel(ctx.ui.theme, ctx.cwd));
			applyWorkingIndicatorMode(ctx);
			gitState = makeFallbackGitState(ctx.cwd);
			void refreshStatusline(ctx);
			installSessionTitle(ctx);
			installSessionTitleSync(ctx);
			ctx.ui.setEditorComponent((tui, theme, keybindings) => {
				activeTui = tui;
				return settingBoolean("compactPrompt", true, ctx.cwd)
					? new QolCompactPromptEditor(tui, theme, keybindings, Math.max(0, Math.floor(settingNumber("inputBottomPaddingLines", DEFAULT_INPUT_BOTTOM_PADDING_LINES, ctx.cwd))), ctx)
					: new QolEditor(tui, theme, keybindings, ctx);
			});
			const statusWidgetTimer = setTimeout(() => {
				ctx.ui.setWidget("statusline", (tui, theme) => {
					activeTui = tui;
					return {
						invalidate() {},
						render(width: number): string[] {
							return [renderStatusLine(width, ctx, gitState ?? makeFallbackGitState(ctx.cwd), pi, theme)];
						},
					};
				});
			}, 0);
			statusWidgetTimer.unref?.();
			if (settingBoolean("replaceFooter", true, ctx.cwd)) {
				ctx.ui.setFooter((tui, _theme, footerData) => {
					activeTui = tui;
					const unsubscribe = footerData.onBranchChange(() => {
						void refreshStatusline(ctx);
						requestRender();
					});
					return { dispose: unsubscribe, invalidate() {}, render: () => [] };
				});
			}
		}
		startQuestionSubscription(ctx);
		void attemptAutoRename(ctx);
		if (settingBoolean("sessionSearch.enabled", true, ctx.cwd)) {
			if (sessionSearchWarmupTimer) clearTimeout(sessionSearchWarmupTimer);
			sessionSearchWarmupTimer = setTimeout(() => {
				sessionSearchWarmupTimer = undefined;
				void refreshQolSessionSearchCache(ctx, { quiet: true }).catch(() => undefined);
			}, 500);
			sessionSearchWarmupTimer.unref?.();
		}
	});

	pi.on("before_agent_start", (event: any) => {
		latestSystemPromptOptions = event?.systemPromptOptions;
	});

	pi.on("session_shutdown", (_event, ctx) => {
		cavemanUnsubscribe?.();
		cavemanUnsubscribe = undefined;
		resetAutoRename();
		resetBudgetGuard();
		clearIdleCompactionTimer();
		clearQuestionSubscribeTimer();
		if (sessionSearchWarmupTimer) clearTimeout(sessionSearchWarmupTimer);
		sessionSearchWarmupTimer = undefined;
		resetThinkingTimer(undefined);
		clearTmuxWindowMark();
		questionUnsubscribe?.();
		questionUnsubscribe = undefined;
		currentCtx = undefined;
		const host = globalThis as unknown as Record<PropertyKey, unknown>;
		if (host[QOL_NOTIFICATION_SERVICE_SYMBOL] === notificationService) delete host[QOL_NOTIFICATION_SERVICE_SYMBOL];
		ctx.ui.setStatus(STATUS_KEY, undefined);
		ctx.ui.setStatus(SESSION_SEARCH_STATUS_KEY, undefined);
		restorePendingQueueThemePatch(ctx);
		resetStatuslineUi(ctx);
		ctx.ui.setEditorComponent(undefined);
	});

	pi.on("model_select", (_event, ctx) => {
		if (!ctx.hasUI) return;
		void refreshStatusline(ctx);
		requestRender();
	});
	pi.on("thinking_level_select", (_event, ctx) => {
		if (ctx.hasUI) requestRender();
	});
	pi.on("agent_start", (_event, ctx) => {
		clearIdleCompactionTimer();
		clearTmuxWindowMark();
		if (ctx.hasUI) {
			void refreshStatusline(ctx);
			requestRender();
		}
	});
	pi.on("message_update", (event, ctx) => {
		if (ctx.hasUI) requestRender();
		if (!updateThinkingTimerEnabled(ctx)) return;
		const streamEvent = event.assistantMessageEvent as any;
		if (!streamEvent || typeof streamEvent.type !== "string") return;
		if (streamEvent.type === "thinking_start" || streamEvent.type === "thinking_delta") {
			const partial = streamEvent.partial;
			if (!partial || typeof partial.timestamp !== "number" || typeof streamEvent.contentIndex !== "number") return;
			const key = thinkingTimerKey(partial.timestamp, streamEvent.contentIndex);
			if (!thinkingTimerStore.starts.has(key) && !thinkingTimerStore.durations.has(key)) thinkingTimerStore.starts.set(key, Date.now());
			startThinkingTimerTicker();
			tickThinkingTimer();
			return;
		}
		if (streamEvent.type === "thinking_end") {
			const partial = streamEvent.partial;
			if (!partial || typeof partial.timestamp !== "number" || typeof streamEvent.contentIndex !== "number") return;
			finalizeThinkingBlock(thinkingTimerKey(partial.timestamp, streamEvent.contentIndex));
		}
	});
	pi.on("message_end", (event, ctx) => {
		if (!updateThinkingTimerEnabled(ctx)) return;
		const message = event.message as any;
		if (!message || message.role !== "assistant" || !Array.isArray(message.content)) return;
		for (let i = 0; i < message.content.length; i++) {
			if (message.content[i]?.type !== "thinking") continue;
			finalizeThinkingBlock(thinkingTimerKey(message.timestamp, i));
		}
	});
	pi.on("agent_end", (event, ctx) => {
		if (ctx.hasUI) {
			void refreshStatusline(ctx);
			requestRender();
		}
		maybeFireBudgetGuard(ctx);
		scheduleIdleCompaction(ctx);
		void attemptAutoRename(ctx);
		const text = lastAssistantTextFromAgentEnd(event, ctx);
		const critical = criticalInfo(text);
		if (critical) {
			pendingTaskCompleteNotification = undefined;
			sendQolNotification(ctx, "critical", `Critical: ${critical}`, "error", `critical:${critical.slice(0, 80)}`);
			return;
		}
		if (pendingTaskCompleteNotification) {
			const body = pendingTaskCompleteNotification;
			pendingTaskCompleteNotification = undefined;
			sendQolNotification(ctx, "task-complete", body, "info", "task-complete");
			return;
		}
		if (ctx.hasPendingMessages?.()) return;
		if (needsDirection(text)) {
			sendQolNotification(ctx, "direction", "Pi is awaiting your direction.", "warning", "direction");
			return;
		}
		sendQolNotification(ctx, "ready", settingString("notification.readyMessage", "Ready for input", ctx.cwd), "info", "ready");
	});
	pi.on("session_compact", (_event, ctx) => {
		// After a successful compaction usage drops below the budget, so reset the
		// crossing key so the next threshold crossing re-fires the guard.
		budgetGuardDriver.noteSessionCompacted();
		if (!ctx.hasUI) return;
		void refreshStatusline(ctx);
		requestRender();
	});
	pi.on("session_before_compact", (event, ctx) => handleQolCompaction(event, ctx));
	pi.on("session_before_tree", (event, ctx) => handleQolBranchSummary(event, ctx));
	pi.on("tool_call", async (event: any, ctx) => {
		if (event?.toolName === "question") {
			notifyQuestionOpened(ctx, { requestId: event.input?.id ?? event.toolCallId, request: event.input, source: "tool_call" }, "question");
			return undefined;
		}
		if (!settingBoolean("permissionGate.enabled", false, ctx.cwd)) return undefined;
		if (event?.toolName !== "bash") return undefined;
		const command = typeof event.input?.command === "string" ? event.input.command : "";
		if (!command) return undefined;
		const matched = permissionGateMatch(command, ctx.cwd);
		if (!matched) return undefined;
		if (!ctx.hasUI) return { block: true, reason: `Command matched permission gate (${matched}) and no UI is available for confirmation` };
		const choice = await ctx.ui.select(permissionGatePrompt(matched, command, ctx.cwd), ["Allow once", "Block"]);
		if (choice !== "Allow once") return { block: true, reason: `Blocked by QOL permission gate (${matched})` };
		return undefined;
	});
	pi.on("tool_result", (event: any, ctx) => {
		if (event?.toolName === "tasks_write") maybeNotifyTaskCompletion(ctx, event.details?.state);
	});

	pi.on("input", async (event) => {
		clearTmuxWindowMark();
		if (event.source === "extension") return { action: "continue" };
		const text = event.text ?? "";
		const paths = currentCtx?.cwd ? resolveSubmittedImagePaths(text, currentCtx.cwd) : [];
		if (paths.length === 0) return { action: "continue" };
		const images = paths.map(imageContentForPath).filter(Boolean);
		if (images.length === 0) return { action: "continue" };
		return { action: "transform", images: [...(event.images ?? []), ...images], text: event.text };
	});

	if (settingBoolean("enableSessionNameCommand", true)) {
		pi.registerCommand("rename", {
			description: "Current session friendly-name editor.",
			handler: async (args, ctx) => {
				const name = args.trim();
				if (name) {
					pi.setSessionName(name);
					ctx.ui.notify(`Session named: ${name}`, "info");
					return;
				}

				const current = pi.getSessionName();
				ctx.ui.notify(current ? `Session: ${current}` : "No session name set", "info");
			},
		});
	}

	if (settingBoolean("enableHandoffCommand", true)) {
		pi.registerCommand("handoff", {
			description: "Focused context handoff to a new session.",
			handler: async (args, ctx) => runHandoff(args, ctx),
		});
	}

	if (settingBoolean("enableContextCommand", true)) {
		pi.registerMessageRenderer(CONTEXT_USAGE_MESSAGE_TYPE, renderQolContextUsageMessage);
		pi.registerCommand("context", {
			description: "Show context-window usage and estimated category breakdowns inline.",
			handler: async (_args, ctx) => {
				const details = buildQolContextUsageDetails(pi, ctx, latestSystemPromptOptions);
				if (!details) {
					ctx.ui.notify("Context usage info is not available yet.", "warning");
					return;
				}
				pi.sendMessage({ customType: CONTEXT_USAGE_MESSAGE_TYPE, content: "Context usage snapshot", details, display: true }, { deliverAs: "followUp", triggerTurn: false });
			},
		});
	}

	if (settingBoolean("sessionSearch.enabled", true)) {
		pi.registerMessageRenderer(SESSION_SEARCH_CONTEXT_TYPE, renderSessionSearchContextMessage);

		const handleSearchCommand = async (args: string, ctx: ExtensionCommandContext) => {
			const trimmed = args.trim();
			if (trimmed === "refresh") {
				try {
					const sessions = await refreshQolSessionSearchCache(ctx, { force: true });
					ctx.ui.notify(`Session search refreshed: ${sessions.length} session(s)`, "info");
				} catch (error) {
					ctx.ui.notify(`Session search refresh failed: ${stringifyError(error)}`, "error");
				}
				return;
			}
			await openQolSessionSearch(pi, ctx, trimmed);
		};

		pi.registerCommand("search", {
			description: "Previous-session search and context import.",
			getArgumentCompletions: getSessionSearchArgumentCompletions,
			handler: handleSearchCommand,
		});
		pi.registerCommand("search:refresh", {
			description: "Refresh the session search index",
			handler: async (_args, ctx) => handleSearchCommand("refresh", ctx),
		});
		pi.registerCommand("search:resume-pending", {
			description: "Run a pending session-search resume or fork action",
			handler: async (args, ctx) => {
				const id = args.trim();
				const action = qolSessionSearchPendingActions.get(id);
				if (!action) {
					ctx.ui.notify("No pending session-search resume/fork action found.", "warning");
					return;
				}
				qolSessionSearchPendingActions.delete(id);
				if (!(await runSessionSearchResumeOrFork(pi, ctx, action))) ctx.ui.notify("Session resume/fork is unavailable in this context.", "error");
			},
		});
		const shortcut = sessionSearchShortcut();
		if (shortcut) {
			pi.registerShortcut(shortcut, {
				description: "Search previous sessions",
				handler: async (ctx) => openQolSessionSearch(pi, ctx as ExtensionContext),
			});
		}
	}

	const tryOpenExtensionManagerSettings = async (ctx: ExtensionCommandContext): Promise<boolean> => {
		const host = globalThis as unknown as Record<PropertyKey, unknown>;
		const openQuickSettings = host[Symbol.for("vstack.pi.extension-manager.open-quick-settings")];
		if (typeof openQuickSettings !== "function") return false;
		try {
			await (openQuickSettings as (ctx: ExtensionCommandContext, hint?: string) => Promise<void>)(ctx, "pi-qol");
			return true;
		} catch {
			return false;
		}
	};

	const dispatchQol = async (sub: string, rest: string, ctx: ExtensionCommandContext) => {
		const restLower = rest.toLowerCase();
		if (sub === "status") {
			if (await tryOpenExtensionManagerSettings(ctx)) return;
			ctx.ui.notify(statusMessage(ctx), "info");
			return;
		}
		if (sub === "rename") {
			if (!restLower) {
				await attemptAutoRename(ctx, { force: true, notify: true });
				return;
			}
			if (restLower === "full") {
				await attemptAutoRename(ctx, { force: true, fullConversation: true, notify: true });
				return;
			}
			ctx.ui.notify("Unknown /qol rename mode. Try /qol:rename or /qol:rename:full.", "warning");
			return;
		}
		if (sub === "notify-test") {
			sendQolNotification(ctx, "test", "QOL notification test", "info", `test:${Date.now()}`);
			ctx.ui.notify("Sent QOL notification test.", "info");
			return;
		}
		ctx.ui.notify("Unknown /qol action. Try /qol, /qol:rename, /qol:rename:full, or /qol notify-test.", "warning");
	};

	pi.registerCommand("qol", {
		description: "QOL helpers and settings.",
		getArgumentCompletions: getQolArgumentCompletions,
		handler: async (args, ctx) => {
			const trimmed = args.trim();
			const firstSpace = trimmed.search(/\s/);
			const sub = (firstSpace < 0 ? trimmed : trimmed.slice(0, firstSpace)).toLowerCase() || "status";
			const rest = firstSpace < 0 ? "" : trimmed.slice(firstSpace + 1).trim();
			await dispatchQol(sub, rest, ctx);
		},
	});
	pi.registerCommand("qol:rename", {
		description: "Generate a session name from the first user message",
		handler: async (_args, ctx) => dispatchQol("rename", "", ctx),
	});
	pi.registerCommand("qol:rename:full", {
		description: "Generate a session name from the full conversation",
		handler: async (_args, ctx) => dispatchQol("rename", "full", ctx),
	});
}
