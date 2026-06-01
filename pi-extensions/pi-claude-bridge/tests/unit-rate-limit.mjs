/**
 * Tests for Claude SDK rate-limit event rendering.
 */
import { describe, it } from "node:test";
import assert from "node:assert/strict";
import {
	formatAllowedRateLimitWarning,
	normalizeRateLimitUtilization,
} from "../src/index.ts";

describe("rate_limit_event allowed_warning", () => {
	it("suppresses low fractional utilization for seven_day warnings", () => {
		const warning = formatAllowedRateLimitWarning({
			status: "allowed_warning",
			rateLimitType: "seven_day",
			utilization: 0.01,
		});

		assert.equal(warning, undefined);
	});

	it("suppresses exact 1 because SDK unit is ambiguous", () => {
		const warning = formatAllowedRateLimitWarning({
			status: "allowed_warning",
			rateLimitType: "seven_day",
			utilization: 1,
		});

		assert.equal(warning, undefined);
	});

	it("normalizes fractional and percent values before thresholding", () => {
		assert.equal(normalizeRateLimitUtilization(0.91), 91);
		assert.equal(normalizeRateLimitUtilization(91), 91);
		assert.equal(
			formatAllowedRateLimitWarning({
				status: "allowed_warning",
				rateLimitType: "seven_day",
				utilization: 0.91,
			}),
			"Claude rate limit warning: nearing seven_day limit; check Claude Code /usage for exact utilization.",
		);
	});
});
