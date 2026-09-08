export function stateWithTasks(count: number, taskText = "Task") {
	return {
		autoShownThisSession: true,
		hiddenByUser: false,
		lastVisiblePanel: "compact",
		panel: "compact",
		phases: [{ id: "phase-1", order: 0, title: "Phase" }],
		tasks: Array.from({ length: count }, (_value, index) => ({
			content: `${taskText} ${index}`,
			id: `task-${index}`,
			notes: [`note ${index}`],
			order: index,
			phaseId: "phase-1",
			status: index === 0 ? "in_progress" : "pending",
		})),
		updatedAt: "2026-05-20T00:00:00.000Z",
		version: 1,
	};
}

