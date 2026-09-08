import assert from "node:assert/strict";
import test from "node:test";
import { isLocalVideoPath, videoMimeForPath } from "../src/extract/video.js";

for (const { path, video } of [
	{ path: "/x/sample.mp4", video: true },
	{ path: "/x/foo.mov", video: true },
	{ path: "/x/foo.webm", video: true },
	{ path: "/x/foo.txt", video: false },
]) {
	test(`local video path: ${path}`, () => assert.equal(isLocalVideoPath(path), video));
}
for (const { path, mime } of [
	{ path: "/x/foo.mp4", mime: "video/mp4" },
	{ path: "/x/foo.mov", mime: "video/quicktime" },
]) {
	test(`video MIME: ${path}`, () => assert.equal(videoMimeForPath(path), mime));
}
