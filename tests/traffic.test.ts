/*
 * Audisk per-request cancellation regression tests.
 * Run from a Vencord checkout:
 * pnpm exec tsx --test src/userplugins/audisk/tests/traffic.test.ts
 */

import assert from "node:assert/strict";
import test from "node:test";

import {
    clearCompanionEventListeners,
    COMPANION_EVENT_CODES,
    subscribeCompanionEvents,
    type CompanionEvent,
} from "../companionEvents";
import { Traffic } from "../traffic";

function deferred<T = void>() {
    let resolve!: (value: T | PromiseLike<T>) => void;
    let reject!: (reason?: unknown) => void;
    const promise = new Promise<T>((res, rej) => { resolve = res; reject = rej; });
    return { promise, resolve, reject };
}

const silentLogger = {
    warn() { },
    error() { },
    debug() { },
};

test.afterEach(() => clearCompanionEventListeners());

test("a queued task request aborts synchronously and never reaches API.post", async () => {
    const first = deferred<void>();
    const calls: string[] = [];
    const API = {
        post: async ({ url }: { url: string; }) => {
            calls.push(url);
            if (url === "/first") await first.promise;
            return { body: {} };
        },
    };
    const traffic = new Traffic(API, () => true, silentLogger);
    const secondController = new AbortController();

    const firstRequest = traffic.enqueue("/first", {});
    const secondRequest = traffic.enqueue("/second", {}, () => true, secondController.signal);
    secondController.abort();

    await assert.rejects(secondRequest, (error: any) => error?.name === "AbortError");
    assert.deepEqual(calls, ["/first"]);

    first.resolve();
    await firstRequest;
    assert.deepEqual(calls, ["/first"]);
});

test("an in-flight request stays reserved until the real POST settles", async () => {
    const response = deferred<void>();
    let attempts = 0;
    const controller = new AbortController();
    const API = {
        post: async () => {
            attempts++;
            await response.promise;
            return { body: { progress: 123 } };
        },
    };
    const traffic = new Traffic(API, () => true, silentLogger);

    const request = traffic.enqueue("/in-flight", {}, () => true, controller.signal);
    while (attempts === 0) await Promise.resolve();

    let settled = false;
    void request.catch(() => { settled = true; });
    controller.abort();
    await Promise.resolve();
    await Promise.resolve();

    // RestAPI.post cannot be unsent. Cancellation blocks its continuation but does not pretend
    // the generation has settled before the real network promise returns.
    assert.equal(settled, false);

    response.resolve();
    await assert.rejects(request, (error: any) => error?.name === "AbortError");
    assert.equal(attempts, 1);
});

test("an endpoint retry cannot be revived by pause then resume", async () => {
    const retryScheduled = deferred<void>();
    let attempts = 0;
    const controller = new AbortController();
    const API = {
        post: async () => {
            attempts++;
            if (attempts === 1) throw { status: 429, body: { retry_after: 60, global: false } };
            return { body: {} };
        },
    };
    const log = {
        ...silentLogger,
        warn() { retryScheduled.resolve(); },
    };
    const traffic = new Traffic(API, () => true, log);

    const request = traffic.enqueue("/retry", {}, () => true, controller.signal);
    await retryScheduled.promise;
    controller.abort();

    await assert.rejects(request, (error: any) => error?.name === "AbortError");
    assert.equal(attempts, 1);
});

test("endpoint retry timer is cleared when its task is cancelled", async () => {
    const retryScheduled = deferred<void>();
    let attempts = 0;
    const controller = new AbortController();
    const API = {
        post: async () => {
            attempts++;
            throw { status: 429, body: { retry_after: 60, global: false } };
        },
    };
    const traffic = new Traffic(API, () => true, {
        ...silentLogger,
        warn() { retryScheduled.resolve(); },
    });

    const request = traffic.enqueue("/long-retry", {}, () => true, controller.signal);
    await retryScheduled.promise;
    controller.abort();

    await assert.rejects(request, (error: any) => error?.name === "AbortError");
    await Promise.resolve();
    assert.equal(attempts, 1);
});

test("global 429 keeps shared pacing but cancels the owning request immediately", async () => {
    const retryScheduled = deferred<void>();
    let attempts = 0;
    const controller = new AbortController();
    const API = {
        post: async () => {
            attempts++;
            if (attempts === 1) throw { status: 429, body: { retry_after: 0, global: true } };
            return { body: {} };
        },
    };
    const traffic = new Traffic(API, () => true, {
        ...silentLogger,
        warn() { retryScheduled.resolve(); },
    });

    const request = traffic.enqueue("/global-retry", {}, () => true, controller.signal);
    await retryScheduled.promise;
    controller.abort();

    await assert.rejects(request, (error: any) => error?.name === "AbortError");
    assert.equal(attempts, 1);
});

test("a stale liveness predicate still blocks a queued request without an AbortSignal", async () => {
    const first = deferred<void>();
    const calls: string[] = [];
    let active = true;
    const API = {
        post: async ({ url }: { url: string; }) => {
            calls.push(url);
            if (url === "/first") await first.promise;
            return { body: {} };
        },
    };
    const traffic = new Traffic(API, () => true, silentLogger);

    const firstRequest = traffic.enqueue("/first", {});
    const secondRequest = traffic.enqueue("/predicate", {}, () => active);
    active = false;
    first.resolve();

    await firstRequest;
    await assert.rejects(secondRequest, (error: any) => error?.name === "AbortError");
    assert.deepEqual(calls, ["/first"]);
});

test("a retry event reports the actual 1-based request attempt and total attempt budget", async () => {
    const controller = new AbortController();
    const seen = deferred<CompanionEvent>();
    subscribeCompanionEvents(event => {
        if (event.code === COMPANION_EVENT_CODES.NETWORK_RETRY) seen.resolve(event);
    });

    const API = {
        post: async () => {
            throw {
                status: 429,
                body: {
                    retry_after: 60,
                    global: false,
                    code: 130000,
                    message: "You are being rate limited.",
                },
            };
        },
    };
    const traffic = new Traffic(API, () => true, silentLogger);
    const request = traffic.enqueue("/quests/123456789/retry", {}, () => true, controller.signal);

    const event = await seen.promise;
    assert.equal(event.questId, "123456789");
    assert.equal(event.failure?.terminal, false);
    assert.equal(event.failure?.retryable, true);
    assert.equal(event.failure?.attempt, 1);
    assert.equal(event.failure?.maxAttempts, 4);
    assert.equal(event.failure?.httpStatus, 429);
    assert.equal(event.failure?.upstreamCode, 130000);

    controller.abort();
    await assert.rejects(request, (error: any) => error?.name === "AbortError");
});

test("a non-retryable request failure keeps upstream status/code separate from prose", async () => {
    const events: CompanionEvent[] = [];
    subscribeCompanionEvents(event => events.push(event));
    const error = {
        status: 403,
        body: { code: 50165, message: "Application unavailable" },
    };
    const API = { post: async () => { throw error; } };
    const traffic = new Traffic(API, () => true, silentLogger);

    await assert.rejects(traffic.enqueue("/quests/987654321/enroll", {}), candidate => candidate === error);

    assert.equal(events.length, 1);
    const event = events[0];
    assert.equal(event.code, COMPANION_EVENT_CODES.NETWORK_FAILED);
    assert.equal(event.questId, "987654321");
    assert.equal(event.failure?.terminal, true);
    assert.equal(event.failure?.retryable, false);
    assert.equal(event.failure?.attempt, 1);
    assert.equal(event.failure?.maxAttempts, 1);
    assert.equal(event.failure?.httpStatus, 403);
    assert.equal(event.failure?.upstreamCode, 50165);
    assert.equal(event.failure?.reason, "Application unavailable");
});

test("a later non-retryable response terminates on its real attempt without an impossible budget", async () => {
    const events: CompanionEvent[] = [];
    subscribeCompanionEvents(event => events.push(event));
    let attempts = 0;
    const terminal = { status: 400, body: { code: 40001, message: "Bad request" } };
    const API = {
        post: async () => {
            attempts++;
            if (attempts === 1) {
                throw { status: 429, body: { retry_after: 0, global: true, code: 130000, message: "Retry once" } };
            }
            throw terminal;
        },
    };
    const traffic = new Traffic(API, () => true, silentLogger);

    await assert.rejects(traffic.enqueue("/quests/24681012/enroll", {}), candidate => candidate === terminal);

    const failed = events.find(event => event.code === COMPANION_EVENT_CODES.NETWORK_FAILED);
    assert.ok(failed);
    assert.equal(attempts, 2);
    assert.equal(failed.failure?.terminal, true);
    assert.equal(failed.failure?.retryable, false);
    assert.equal(failed.failure?.attempt, 2);
    assert.equal(failed.failure?.maxAttempts, 2);
    assert.equal(failed.failure?.httpStatus, 400);
    assert.equal(failed.failure?.upstreamCode, 40001);
});

test("task cancellation does not masquerade as a network failure event", async () => {
    const first = deferred<void>();
    const events: CompanionEvent[] = [];
    subscribeCompanionEvents(event => events.push(event));
    const controller = new AbortController();
    const API = {
        post: async ({ url }: { url: string; }) => {
            if (url === "/hold") await first.promise;
            return { body: {} };
        },
    };
    const traffic = new Traffic(API, () => true, silentLogger);

    const holding = traffic.enqueue("/hold", {});
    const cancelled = traffic.enqueue("/quests/111222333/progress", {}, () => true, controller.signal);
    controller.abort();
    await assert.rejects(cancelled, (error: any) => error?.name === "AbortError");
    assert.equal(events.length, 0);

    first.resolve();
    await holding;
    assert.equal(events.length, 0);
});
