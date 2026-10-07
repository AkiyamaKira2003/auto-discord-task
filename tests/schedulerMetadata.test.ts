/*
 * Audisk scheduler metadata regression tests.
 * Run from a Vencord checkout:
 * pnpm exec tsx --test src/userplugins/audisk/tests/schedulerMetadata.test.ts
 */

import assert from "node:assert/strict";
import test from "node:test";

import { schedulerLaneForTaskType, SchedulerMetadata, type SchedulerLane, type SchedulerTaskView } from "../schedulerMetadata";
import { TaskControlRegistry } from "../taskControl";
import type { TaskType } from "../types";

function task(
    questId: string,
    lane: "game" | "video",
    started: boolean,
    active = true,
): SchedulerTaskView {
    return { questId, lane, started, active };
}

const flushMicrotasks = async () => {
    await Promise.resolve();
    await Promise.resolve();
};

test("task type lane mapping is shared by scheduler placement and companion metadata", () => {
    const expected: Record<TaskType, SchedulerLane> = {
        GAME: "game",
        STREAM: "game",
        WATCH_VIDEO: "video",
        ACTIVITY: "game",
        ACHIEVEMENT: "game",
    };

    for (const [taskType, lane] of Object.entries(expected) as Array<[TaskType, SchedulerLane]>) {
        assert.equal(schedulerLaneForTaskType(taskType), lane);
    }
});

test("snapshot reports the active lane limit and running/waiting membership", () => {
    const metadata = new SchedulerMetadata();
    metadata.beginLane("game", 3);
    metadata.beginLane("video", 2);

    const snapshot = metadata.snapshot([
        task("game-running", "game", true),
        task("game-waiting", "game", false),
        task("video-running", "video", true),
    ]);

    assert.deepEqual(snapshot.lanes, {
        game: { limit: 3, running: 1, waiting: 1 },
        video: { limit: 2, running: 1, waiting: 0 },
    });
    assert.deepEqual(snapshot.quests, {
        "game-running": { lane: "game", state: "running" },
        "game-waiting": { lane: "game", state: "waiting" },
        "video-running": { lane: "video", state: "running" },
    });
});

test("TaskControlRegistry transitions are reflected without a second scheduler ownership mirror", () => {
    const metadata = new SchedulerMetadata();
    const controls = new TaskControlRegistry();
    metadata.beginLane("game", 2);

    const first = controls.create("first");
    const second = controls.create("second");
    const views = (): SchedulerTaskView[] => ["first", "second"].flatMap(questId => {
        const control = controls.get(questId);
        return control
            ? [{ questId, lane: "game" as const, active: control.active, started: control.started }]
            : [];
    });

    assert.deepEqual(metadata.snapshot(views()).lanes.game, { limit: 2, running: 0, waiting: 2 });

    assert.equal(controls.markStarted("first", first.generation), true);
    assert.deepEqual(metadata.snapshot(views()).lanes.game, { limit: 2, running: 1, waiting: 1 });
    assert.deepEqual(metadata.snapshot(views()).quests.first, { lane: "game", state: "running" });

    controls.pause("second");
    assert.equal(controls.get("second"), undefined);
    assert.deepEqual(metadata.snapshot(views()).lanes.game, { limit: 2, running: 1, waiting: 0 });

    controls.pause("first");
    assert.equal(controls.get("first"), first);
    assert.equal(first.active, false);
    assert.deepEqual(metadata.snapshot(views()).lanes.game, { limit: 2, running: 0, waiting: 0 });
    assert.deepEqual(metadata.snapshot(views()).quests, {});

    // The started generation remains reserved until its async worker actually settles.
    controls.release("first", first.generation);
    assert.equal(controls.get("first"), undefined);
    assert.equal(second.started, false);
});

test("inactive controls and tasks outside a live lane are not scheduler members", () => {
    const metadata = new SchedulerMetadata();
    metadata.beginLane("game", 1);

    const snapshot = metadata.snapshot([
        task("active-game", "game", false),
        task("cancelled-game", "game", true, false),
        task("not-yet-video", "video", false),
    ]);

    assert.deepEqual(snapshot.lanes, {
        game: { limit: 1, running: 0, waiting: 1 },
        video: { limit: null, running: 0, waiting: 0 },
    });
    assert.deepEqual(snapshot.quests, {
        "active-game": { lane: "game", state: "waiting" },
    });
    assert.equal("position" in snapshot.quests["active-game"], false);
});

test("a stale lane completion cannot clear a replacement batch", () => {
    const metadata = new SchedulerMetadata();
    const first = metadata.beginLane("game", 1);
    const replacement = metadata.beginLane("game", 3);

    metadata.endLane("game", first);
    assert.equal(metadata.snapshot([]).lanes.game.limit, 3);

    metadata.endLane("game", replacement);
    assert.equal(metadata.snapshot([]).lanes.game.limit, null);
});

test("clear invalidates old lane tokens", () => {
    const metadata = new SchedulerMetadata();
    const old = metadata.beginLane("video", 2);
    metadata.clear();
    const replacement = metadata.beginLane("video", 4);

    metadata.endLane("video", old);
    assert.equal(metadata.snapshot([]).lanes.video.limit, 4);

    metadata.endLane("video", replacement);
    assert.equal(metadata.snapshot([]).lanes.video.limit, null);
});

test("snapshots are frozen and do not expose queue ordering", () => {
    const metadata = new SchedulerMetadata();
    metadata.beginLane("game", 2);
    const snapshot = metadata.snapshot([task("q1", "game", false)]);

    assert.equal(Object.isFrozen(snapshot), true);
    assert.equal(Object.isFrozen(snapshot.lanes), true);
    assert.equal(Object.isFrozen(snapshot.lanes.game), true);
    assert.equal(Object.isFrozen(snapshot.quests), true);
    assert.equal(Object.isFrozen(snapshot.quests.q1), true);
    assert.deepEqual(Object.keys(snapshot.quests.q1).sort(), ["lane", "state"]);
});

test("state notifications are asynchronous, coalesced and isolate listener errors", async () => {
    const metadata = new SchedulerMetadata();
    let calls = 0;
    let siblingCalls = 0;
    const originalError = console.error;
    console.error = () => {};

    try {
        metadata.subscribe(() => {
            calls++;
            throw new Error("listener failure");
        });
        const unsubscribe = metadata.subscribe(() => { siblingCalls++; });

        metadata.beginLane("game", 1);
        metadata.notify();
        metadata.notify();
        assert.equal(calls, 0);
        assert.equal(siblingCalls, 0);

        await flushMicrotasks();
        assert.equal(calls, 1);
        assert.equal(siblingCalls, 1);

        unsubscribe();
        unsubscribe();
        metadata.endLane("game", 1);
        await flushMicrotasks();
        assert.equal(calls, 2);
        assert.equal(siblingCalls, 1);
    } finally {
        console.error = originalError;
    }
});

test("notify while no lane is active does not publish fake scheduler activity", async () => {
    const metadata = new SchedulerMetadata();
    let calls = 0;
    metadata.subscribe(() => { calls++; });

    metadata.notify();
    await flushMicrotasks();
    assert.equal(calls, 0);
});
