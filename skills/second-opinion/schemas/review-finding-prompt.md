Output ONLY valid JSON — no markdown fences, no explanation before or after.

This is a single fresh session with no prior turns and no session history. Output the COMPLETE JSON object in THIS response — do NOT claim the JSON was "already delivered", "above", or "previously", because there is no earlier message. If you have nothing to report, still emit the full JSON object below with an empty `blockers` array and verdict "pass":

{
  "agent": "external-TARGET",
  "timestamp": "ISO_8601",
  "verdict": "pass or action_required",
  "summary": "1-2 sentence summary of findings",
  "blockers": [
    {
      "id": 1,
      "title": "Concise issue title (5-10 words)",
      "location": "src/file.rs (`function_name`)",
      "description": "What the issue is",
      "recommendation": "How to fix it",
      "priority": 1,
      "estimate": 2
    }
  ],
  "suggestions": [
    {
      "id": 1,
      "title": "Concise issue title (5-10 words)",
      "location": "src/file.rs (`function_name`)",
      "description": "What could be improved",
      "recommendation": "How to improve it",
      "priority": 3,
      "estimate": 2,
      "category": "fix"
    }
  ],
  "questions": [],
  "qa_metadata": {}
}

Rules:
- Every key shown above is REQUIRED in every response: verdict, and the blockers, suggestions, and questions arrays (emit [] when empty) plus the qa_metadata object. A response missing any of them is rejected as incomplete.
- verdict: "action_required" if 1+ items in blockers[], "pass" if blockers[] is empty
- Suggestions may exist even when verdict is "pass"
- location: file path with function/struct names in backticks — NO line numbers (they go stale)
- priority: 1=Urgent, 2=High, 3=Normal, 4=Low
- estimate: 1=hours, 2=half-day, 3=day, 4=2-3 days, 5=week+
- category: "fix" (apply in this PR) or "issue" (track separately)
- Only report genuine issues you are confident about. No speculative warnings. If the code is clean, return verdict "pass" with empty arrays.
- qa_metadata: {} when you actually reviewed the changes. If you could NOT review them (the diff command failed, the diff is empty, or the scope is otherwise missing), set qa_metadata to {"review_performed": false, "reason": "<short_snake_case_reason>"} and verdict to "action_required" — NEVER report "pass" for changes you did not review.
