export const PI_PROJECT_MARKERS: readonly string[];
export function piGlobalRoot(value?: string, home?: string, platform?: "posix" | "win32"): string;
export function piProjectRoot(cwd: string, markers?: readonly string[], home?: string): string | undefined;
