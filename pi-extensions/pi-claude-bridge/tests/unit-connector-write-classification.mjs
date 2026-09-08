import { test } from "node:test";
import assert from "node:assert/strict";
import { isConnectorWriteTool, CONNECTOR_WRITE_TOOLS } from "../bundle/index.js";

// Tool names include the Slack and Atlassian forms emitted by ToolSearch.
test("connector write classification permits reads and denies mutations or unclassifiable names", () => {
	const rows = [
		...CONNECTOR_WRITE_TOOLS.map((name) => [name, true]),
		// not-yet-known future writes must still classify as writes
		["mcp__claude_ai_Gmail__send_message", true],
		["mcp__claude_ai_Gmail__update_draft", true],
		["mcp__claude_ai_Gmail__create_filter", true],
		["mcp__claude_ai_Google_Drive__update_file", true],
		["mcp__claude_ai_Google_Drive__delete_file", true],
		["mcp__claude_ai_Google_Drive__move_file", true],
		["mcp__claude_ai_Google_Calendar__add_attendee", true],
		["mcp__claude_ai_Gmail__search_threads", false],
		["mcp__claude_ai_Gmail__get_message", false],
		["mcp__claude_ai_Gmail__list_labels", false],
		["mcp__claude_ai_Google_Calendar__list_events", false],
		["mcp__claude_ai_Google_Calendar__get_event", false],
		["mcp__claude_ai_Google_Drive__search_files", false],
		["mcp__claude_ai_Google_Drive__fetch_file", false],
		["mcp__claude_ai_Google_Drive__download_file", false],
		// discovery + Pi custom tools are never connector writes
		["ToolSearch", false],
		["ListMcpResources", false],
		["mcp__custom-tools__anything", false],
		["mcp__claude_ai_Slack__send_message", true],
		["mcp__claude_ai_Atlassian__create_issue", true],
		["mcp__claude_ai_Figma__update_file", true],
		["mcp__claude_ai_Notion__delete_page", true],
		["mcp__claude_ai_Slack__search_messages", false],
		["mcp__claude_ai_Atlassian__get_issue", false],
		["mcp__claude_ai_Linear__list_issues", false],
		// Slack: server-prefixed snake_case
		["mcp__claude_ai_Slack__slack_read_channel", false],
		["mcp__claude_ai_Slack__slack_read_thread", false],
		["mcp__claude_ai_Slack__slack_read_canvas", false],
		["mcp__claude_ai_Slack__slack_read_user_profile", false],
		["mcp__claude_ai_Slack__slack_search_channels", false],
		["mcp__claude_ai_Slack__slack_search_public", false],
		["mcp__claude_ai_Slack__slack_search_public_and_private", false],
		["mcp__claude_ai_Slack__slack_search_users", false],
		// Atlassian: camelCase
		["mcp__claude_ai_Atlassian__getJiraIssue", false],
		["mcp__claude_ai_Atlassian__getJiraIssueRemoteIssueLinks", false],
		["mcp__claude_ai_Atlassian__getJiraIssueTypeMetaWithFields", false],
		["mcp__claude_ai_Atlassian__getJiraProjectIssueTypesMetadata", false],
		["mcp__claude_ai_Atlassian__getTransitionsForJiraIssue", false],
		["mcp__claude_ai_Atlassian__getVisibleJiraProjects", false],
		["mcp__claude_ai_Atlassian__searchJiraIssuesUsingJql", false],
		["mcp__claude_ai_Atlassian__lookupJiraAccountId", false],
		["mcp__claude_ai_Atlassian__getConfluencePage", false],
		["mcp__claude_ai_Atlassian__getConfluencePageDescendants", false],
		["mcp__claude_ai_Atlassian__getConfluencePageFooterComments", false],
		["mcp__claude_ai_Atlassian__getConfluencePageInlineComments", false],
		["mcp__claude_ai_Atlassian__getConfluenceSpaces", false],
		["mcp__claude_ai_Atlassian__getPagesInConfluenceSpace", false],
		["mcp__claude_ai_Atlassian__searchConfluenceUsingCql", false],
		["mcp__claude_ai_Atlassian__getAccessibleAtlassianResources", false],
		["mcp__claude_ai_Atlassian__getIssueLinkTypes", false],
		["mcp__claude_ai_Atlassian__getTeamworkGraphContext", false],
		["mcp__claude_ai_Atlassian__getCompassComponents", false],
		// bare single-word tools
		["mcp__claude_ai_Atlassian__search", false],
		["mcp__claude_ai_Atlassian__fetch", false],
		// other connectors on the same account
		["mcp__claude_ai_Figma__get_metadata", false],
		["mcp__claude_ai_Figma__get_libraries", false],
		["mcp__claude_ai_Figma__whoami", false],
		["mcp__claude_ai_Google_Drive__list_recent_files", false],
		["mcp__claude_ai_Gmail__get_thread", false],
		["mcp__claude_ai_Slack__slack_send_message", true],
		["mcp__claude_ai_Slack__slack_send_message_draft", true],
		["mcp__claude_ai_Slack__slack_schedule_message", true],
		["mcp__claude_ai_Slack__slack_create_canvas", true],
		["mcp__claude_ai_Slack__slack_update_canvas", true],
		["mcp__claude_ai_Atlassian__createJiraIssue", true],
		["mcp__claude_ai_Atlassian__editJiraIssue", true],
		["mcp__claude_ai_Atlassian__transitionJiraIssue", true],
		["mcp__claude_ai_Atlassian__addCommentToJiraIssue", true],
		["mcp__claude_ai_Atlassian__addWorklogToJiraIssue", true],
		["mcp__claude_ai_Atlassian__createIssueLink", true],
		["mcp__claude_ai_Atlassian__createConfluencePage", true],
		["mcp__claude_ai_Atlassian__updateConfluencePage", true],
		["mcp__claude_ai_Atlassian__createConfluenceFooterComment", true],
		["mcp__claude_ai_Atlassian__createConfluenceInlineComment", true],
		["mcp__claude_ai_Atlassian__createCompassComponent", true],
		["mcp__claude_ai_Atlassian__addTeamworkGraphContext", true],
		["mcp__claude_ai_Figma__upload_assets", true],
		["mcp__claude_ai_Figma__export_video", true],
		["mcp__claude_ai_Slack__getOrCreateChannel", true],
		["mcp__claude_ai_Atlassian__findAndDeleteIssue", true],
		["mcp__claude_ai_Gmail__get_and_send_draft", true],
		["mcp__claude_ai_Camunda__fetchAndLock", true],
		["mcp__claude_ai_Github__getMergePullRequest", true],
		["mcp__claude_ai_Jira__getResolveIssue", true],
		["mcp__claude_ai_PagerDuty__get_incident_and_acknowledge", true],
		["mcp__claude_ai_AWS__describe_instance_and_terminate", true],
		["mcp__claude_ai_AWS__describe_instance_and_stop", true],
		["mcp__claude_ai_Calendly__get_next_slot_and_book", true],
		["mcp__claude_ai_Slack__slack_search_and_join_channel", true],
		["mcp__claude_ai_Slack__slack_get_channel_and_leave", true],
		["mcp__claude_ai_Slack__slack_search_and_star_message", true],
		["mcp__claude_ai_Slack__slack_get_message_and_forward", true],
		["mcp__claude_ai_Sync__sync_get_status", true],
		["mcp__claude_ai_Archive__archive_list_items", true],
		["mcp__claude_ai_Delete__delete_get_thing", true],
		["mcp__claude_ai_Merge__merge_read_branch", true],
		["mcp__claude_ai_Slack__slack_read_channel", false],
		["mcp__claude_ai_Google_Drive__google_send_file", true],
		["mcp__claude_ai_Google_Drive__google_drive_list_files", false],
		["mcp__claude_ai_Slack__slack", true],
		["ToolSearch", false],
		["ListMcpResources", false],
		["ReadMcpResource", false],
		["mcp__some_other_server__do_thing", false],
		["mcp__some_other_server__create_thing", false],
		["memory_write", false], // bare Pi custom tool
		["mcp__claude_ai_", true], // prefix only, no server, no tool
		["mcp__claude_ai_Slack", true], // server, no tool segment
		["mcp__claude_ai_Slack__", true], // empty tool segment
		["mcp__claude_ai___search_messages", true], // EMPTY server segment: read verb must not exempt it
		["mcp__claude_ai_____get_thing", true], // empty server + leading-underscore tool segment
		["mcp__claude_ai_Weird__Server__list_things", true], // extra segment → first word isn't a read verb
		["mcp__claude_ai_Slack__Send_Message", true], // `send` is not a read verb, in any casing
	];
	for (const [name, expected] of rows) {
		assert.equal(isConnectorWriteTool(name), expected, name);
	}
});
