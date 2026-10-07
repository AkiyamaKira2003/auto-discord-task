/*
 * Audisk, a Vencord userplugin
 * Audistask Copyright (c) 2026 Kiraa (AkiyamaKira2003)
 * SPDX-License-Identifier: MIT
 */

import assert from "node:assert/strict";
import { test } from "node:test";

import { CONSOLE_ONLY_KEYS, isConsoleOnly, selectTaskFamily, selectTaskKey, TASK_FAMILY_ORDER } from "../questConfig";

const PLAY = { match: (k: string) => k.startsWith("PLAY"), prefer: ["PLAY_ON_DESKTOP"] };
const VIDEO = { match: (k: string) => k.includes("VIDEO"), prefer: ["WATCH_VIDEO"] };
const STREAM = { match: (k: string) => k.startsWith("STREAM"), prefer: ["STREAM_ON_DESKTOP"] };
const ACTIVITY = { match: (k: string) => k === "PLAY_ACTIVITY" };

test("the desktop key wins whatever order the server listed the tasks in", () => {
    // The real shapes seen on a live account, and the same shapes reversed. Server key order is
    // not a contract, and relying on it is what this rule exists to stop.
    for (const keys of [
        ["PLAY_ON_DESKTOP", "PLAY_ON_XBOX", "PLAY_ON_PLAYSTATION"],
        ["PLAY_ON_PLAYSTATION", "PLAY_ON_XBOX", "PLAY_ON_DESKTOP"],
        ["PLAY_ON_XBOX", "PLAY_ON_DESKTOP"],
    ]) {
        assert.equal(selectTaskKey(keys, PLAY), "PLAY_ON_DESKTOP", keys.join(","));
    }
});

test("the desktop video key wins over the mobile one in either order", () => {
    assert.equal(selectTaskKey(["WATCH_VIDEO", "WATCH_VIDEO_ON_MOBILE"], VIDEO), "WATCH_VIDEO");
    assert.equal(selectTaskKey(["WATCH_VIDEO_ON_MOBILE", "WATCH_VIDEO"], VIDEO), "WATCH_VIDEO");
});

test("a mobile-only video quest still resolves, because the endpoint is the same either way", () => {
    assert.equal(selectTaskKey(["WATCH_VIDEO_ON_MOBILE"], VIDEO), "WATCH_VIDEO_ON_MOBILE");
});

test("a console key is never selected, even when it is the only thing the rule matches", () => {
    assert.equal(selectTaskKey(["PLAY_ON_XBOX", "PLAY_ON_PLAYSTATION"], PLAY), undefined);
    assert.equal(selectTaskKey(["PLAY_ON_PLAYSTATION"], PLAY), undefined);
});

test("PLAY_ACTIVITY is not swallowed by the console exclusion", () => {
    assert.equal(selectTaskKey(["PLAY_ACTIVITY"], ACTIVITY), "PLAY_ACTIVITY");
    // and the PLAY rule would take it too, since it is a desktop-capable PLAY key
    assert.equal(selectTaskKey(["PLAY_ACTIVITY"], PLAY), "PLAY_ACTIVITY");
});

test("stream prefers the desktop key and ignores anything console-shaped", () => {
    assert.equal(selectTaskKey(["STREAM_ON_DESKTOP"], STREAM), "STREAM_ON_DESKTOP");
    assert.equal(selectTaskKey([], STREAM), undefined);
});

test("a rule with no prefer list still refuses console keys", () => {
    const bare = { match: (k: string) => k.startsWith("PLAY") };
    assert.equal(selectTaskKey(["PLAY_ON_XBOX", "PLAY_ON_DESKTOP"], bare), "PLAY_ON_DESKTOP");
    assert.equal(selectTaskKey(["PLAY_ON_XBOX"], bare), undefined);
});

test("console-only quests are identified so they can be skipped honestly", () => {
    assert.equal(isConsoleOnly(["PLAY_ON_XBOX", "PLAY_ON_PLAYSTATION"]), true);
    assert.equal(isConsoleOnly(["PLAY_ON_DESKTOP", "PLAY_ON_XBOX"]), false);
    assert.equal(isConsoleOnly(["WATCH_VIDEO"]), false);
    // an empty task list is a malformed quest, not a console one, and has its own handling
    assert.equal(isConsoleOnly([]), false);
});

test("the console set holds exactly the keys Discord groups as CONSOLE", () => {
    assert.deepEqual([...CONSOLE_ONLY_KEYS].sort(), ["PLAY_ON_PLAYSTATION", "PLAY_ON_XBOX"]);
});

test("a quest offering both stream and play is driven as a game, not a stream", () => {
    // STREAM_ON_DESKTOP cannot complete: Discord wants a real Go Live plus a second person in the
    // channel before it reads the metadata we fake. Routing it ahead of PLAY_ON_DESKTOP sent a
    // quest that had a working path down the one that only times out.
    assert.deepEqual(selectTaskFamily(["STREAM_ON_DESKTOP", "PLAY_ON_DESKTOP"]), { type: "GAME", keyName: "PLAY_ON_DESKTOP" });
    assert.deepEqual(selectTaskFamily(["PLAY_ON_DESKTOP", "STREAM_ON_DESKTOP"]), { type: "GAME", keyName: "PLAY_ON_DESKTOP" });
    assert.deepEqual(selectTaskFamily(["STREAM_ON_DESKTOP", "WATCH_VIDEO"]), { type: "WATCH_VIDEO", keyName: "WATCH_VIDEO" });
});

test("a stream-only quest is still detected as a stream rather than skipped", () => {
    // It will fail, but it has to fail as a STREAM task so the watchdog reports the real reason.
    assert.deepEqual(selectTaskFamily(["STREAM_ON_DESKTOP"]), { type: "STREAM", keyName: "STREAM_ON_DESKTOP" });
});

test("the exact-match families stay ahead of the PLAY prefix", () => {
    assert.deepEqual(selectTaskFamily(["PLAY_ACTIVITY"]), { type: "ACTIVITY", keyName: "PLAY_ACTIVITY" });
    assert.deepEqual(selectTaskFamily(["ACHIEVEMENT_IN_ACTIVITY", "PLAY_ACTIVITY"]), { type: "ACHIEVEMENT", keyName: "ACHIEVEMENT_IN_ACTIVITY" });
});

test("a console-only quest matches no family, so detectType can say so", () => {
    assert.equal(selectTaskFamily(["PLAY_ON_XBOX", "PLAY_ON_PLAYSTATION"]), undefined);
    assert.equal(selectTaskFamily([]), undefined);
});

test("stream is the last desktop family in the order", () => {
    const types = TASK_FAMILY_ORDER.map(rule => rule.type);
    assert.ok(types.indexOf("STREAM") > types.indexOf("GAME"), "STREAM must not outrank GAME");
    assert.ok(types.indexOf("STREAM") > types.indexOf("WATCH_VIDEO"), "STREAM must not outrank WATCH_VIDEO");
});
