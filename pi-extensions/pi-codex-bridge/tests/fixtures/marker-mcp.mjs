// A configured MCP server that only records that it was started.
import { appendFileSync } from "node:fs";

appendFileSync(process.argv[2], `${process.pid}\n`);
