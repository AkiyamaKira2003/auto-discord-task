/*
 * Audisk, a Vencord userplugin
 * Audistask Copyright (c) 2026 Kiraa (AkiyamaKira2003)
 * SPDX-License-Identifier: MIT
 */

import assert from "node:assert/strict";
import { test } from "node:test";

import { HeartbeatWatchdog, type WatchdogVerdict } from "../heartbeatWatchdog";

/** Discord's own cadence for PLAY_ON_DESKTOP, measured at ~60.1s on a live quest. */
const BEAT = 60_000;
const GRACE = 90 * 1000;
const MAX_FAILURES = 5;

/** A clock the test drives by hand, so the timing is asserted rather than waited out. */
function clock() {
    let now = 0;
    let nextId = 1;
    const timers = new Map<number, { at: number; fn: () => void; }>();

    return {
        get now() { return now; },
        get pending() { return timers.size; },
        setTimer(fn: () => void, ms: number): number {
            const id = nextId++;
            timers.set(id, { at: now + ms, fn });
            return id;
        },
        clearTimer(id: number): void {
            timers.delete(id);
        },
        /** Run every timer due within `ms`, in order, advancing the clock as it goes. */
        advance(ms: number): void {
            const until = now + ms;
            for (;;) {
                let dueId: number | null = null;
                let dueAt = Infinity;
                for (const [id, timer] of timers) {
                    if (timer.at <= until && timer.at < dueAt) { dueId = id; dueAt = timer.at; }
                }
                if (dueId == null) break;
                const timer = timers.get(dueId)!;
                timers.delete(dueId);
                now = timer.at;
                timer.fn();
            }
            now = until;
        },
    };
}

function harness(questName = "Version Update: Typhoeus") {
    const c = clock();
    const verdicts: WatchdogVerdict[] = [];
    const notes: string[] = [];
    const watchdog = new HeartbeatWatchdog({
        questName,
        graceMs: GRACE,
        maxConsecutiveFailures: MAX_FAILURES,
        setTimer: c.setTimer,
        clearTimer: c.clearTimer,
        onFailureNoted: message => notes.push(message),
        onGiveUp: verdict => verdicts.push(verdict),
    });
    watchdog.start();
    return { c, watchdog, verdicts, notes };
}

test("silence for the whole grace period gives up, and says the process was never accepted", () => {
    const { c, verdicts } = harness();
    c.advance(GRACE - 1);
    assert.equal(verdicts.length, 0);
    c.advance(1);
    assert.equal(verdicts.length, 1);
    assert.match(verdicts[0].message, /never reported progress/);
    assert.match(verdicts[0].message, /not accepting the injected process/);
    assert.equal(verdicts[0].reason, "No heartbeat from Discord");
});

test("a single failed beat no longer kills a task that was progressing", () => {
    // Discord beats every 60s and does not retry a failed one, so the recovery beat is at
    // t=120. A 90s watchdog that only a success could rearm fired at t=90 and ended the run
    // 30s before Discord tried again. That is issue #74.
    const { c, watchdog, verdicts } = harness();
    c.advance(BEAT);
    watchdog.beat();
    c.advance(BEAT);
    watchdog.fail("HTTP 500");
    c.advance(BEAT);
    watchdog.beat();
    c.advance(BEAT);
    watchdog.beat();
    assert.equal(verdicts.length, 0);
});

test("failures before the first beat keep the original urgency", () => {
    // The beats === 0 message is the #43 answer, that Discord is not accepting the injected
    // process. It has to arrive in a beat and a half, not after five failures, so a failure
    // with nothing credited yet must not push the deadline out.
    const { c, watchdog, verdicts } = harness();
    c.advance(BEAT);
    watchdog.fail("HTTP 429");
    c.advance(GRACE - BEAT);
    assert.equal(verdicts.length, 1);
    assert.match(verdicts[0].message, /never reported progress/);
    assert.match(verdicts[0].message, /HTTP 429/);
    assert.equal(verdicts[0].reason, "No heartbeat from Discord (1 failed beat(s))");
});

test("consecutive failures are what give up now, and the limit is reachable", () => {
    // Before this, `failures` could never pass 1 on a game quest: reaching 2 needs 120s and
    // the watchdog fired at 90, so MAX_TASK_FAILURES and the error text behind it were dead.
    const { c, watchdog, verdicts, notes } = harness();
    c.advance(BEAT);
    watchdog.beat();
    for (let i = 0; i < MAX_FAILURES; i++) {
        c.advance(BEAT);
        watchdog.fail("HTTP 429, code 130000, You are being rate limited.");
    }
    assert.equal(notes.length, MAX_FAILURES - 1, "each non-fatal failure is noted once");
    assert.match(notes[0], /failed \(1\/5\)/);
    assert.equal(verdicts.length, 1);
    assert.match(verdicts[0].message, /failed 5 times in a row/);
    assert.match(verdicts[0].message, /rate limited/);
    assert.equal(verdicts[0].reason, "Discord could not report progress (HTTP 429, code 130000, You are being rate limited.)");
});

test("a successful beat clears the consecutive failure count", () => {
    const { c, watchdog, verdicts } = harness();
    c.advance(BEAT);
    watchdog.beat();
    for (let i = 0; i < MAX_FAILURES - 1; i++) {
        c.advance(BEAT);
        watchdog.fail("HTTP 500");
    }
    c.advance(BEAT);
    watchdog.beat();
    for (let i = 0; i < MAX_FAILURES - 1; i++) {
        c.advance(BEAT);
        watchdog.fail("HTTP 500");
    }
    assert.equal(verdicts.length, 0);
});

test("the give-up line carries the failed beats, so silence and errors read differently", () => {
    const { c, watchdog, verdicts } = harness();
    c.advance(BEAT);
    watchdog.beat();
    c.advance(BEAT);
    watchdog.beat();
    c.advance(BEAT);
    watchdog.fail("HTTP 502");
    c.advance(GRACE);
    assert.equal(verdicts.length, 1);
    assert.match(verdicts[0].message, /after 2 update\(s\)/);
    assert.match(verdicts[0].message, /1 failed beat\(s\)/);
    assert.match(verdicts[0].message, /HTTP 502/);
    assert.equal(verdicts[0].reason, "No heartbeat from Discord (1 failed beat(s))");
});

test("a clean run of beats reads as silence when Discord stops, with no failures mentioned", () => {
    const { c, watchdog, verdicts } = harness();
    for (let i = 0; i < 3; i++) {
        c.advance(BEAT);
        watchdog.beat();
    }
    c.advance(GRACE);
    assert.equal(verdicts.length, 1);
    assert.match(verdicts[0].message, /after 3 update\(s\)/);
    assert.doesNotMatch(verdicts[0].message, /failed beat/);
    assert.equal(verdicts[0].reason, "No heartbeat from Discord");
});

test("stopping leaves no timer behind and no verdict can follow", () => {
    const { c, watchdog, verdicts } = harness();
    c.advance(BEAT);
    watchdog.beat();
    watchdog.stop();
    assert.equal(c.pending, 0);
    c.advance(GRACE * 2);
    watchdog.fail("HTTP 500");
    watchdog.beat();
    assert.equal(verdicts.length, 0);
});

test("only one verdict is ever delivered", () => {
    const { c, watchdog, verdicts } = harness();
    c.advance(GRACE);
    for (let i = 0; i < MAX_FAILURES; i++) watchdog.fail("HTTP 500");
    c.advance(GRACE * 3);
    assert.equal(verdicts.length, 1);
});
