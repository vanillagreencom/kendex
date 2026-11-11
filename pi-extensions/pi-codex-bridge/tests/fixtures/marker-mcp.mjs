// A configured MCP server that records its pid and keeps running after stdin
// closes, as a server holding a listener or a pool would. It exits on its own
// after two minutes so a failed run cannot leave it behind for long.
import { appendFileSync } from "node:fs";

appendFileSync(process.argv[2], `${process.pid}\n`);
process.stdin.resume();
setInterval(() => undefined, 1000);
setTimeout(() => process.exit(0), 120_000);
