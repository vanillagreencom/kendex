// diagDump is gated on CLAUDE_BRIDGE_DEBUG, same as debug() (VST-15). Test
// files that assert on diag entries import this module BEFORE any bridge
// module, so the flag is already set when src/debug.ts captures it at module
// load. The debug log itself is routed to a scratch dir so enabling the flag
// never appends to the real user log; the diag path is per-test state and
// stays owned by each test file's own beforeEach.
import { mkdtempSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

process.env.CLAUDE_BRIDGE_DEBUG = "1";
process.env.CLAUDE_BRIDGE_DEBUG_PATH = join(mkdtempSync(join(tmpdir(), "bridge-debug-log-")), "claude-bridge.log");
