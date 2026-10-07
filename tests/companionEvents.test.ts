import assert from "node:assert/strict";
import test from "node:test";

import {
    clearCompanionEventListeners,
    companionFailure,
    COMPANION_EVENT_CODES,
    COMPANION_EVENT_CODE_STABILITY,
    emitCompanionEvent,
    sanitizeCompanionText,
    subscribeCompanionEvents,
    type CompanionEvent,
} from "../companionEvents";

const flushCompanionEvents = (): Promise<void> => new Promise(resolve => queueMicrotask(resolve));

test.afterEach(() => clearCompanionEventListeners());

test("companion events deliver immutable structured data in subscription order", async () => {
    const seen: Array<{ listener: string; event: CompanionEvent; }> = [];
    subscribeCompanionEvents(event => seen.push({ listener: "first", event }));
    subscribeCompanionEvents(event => seen.push({ listener: "second", event }));

    emitCompanionEvent({
        timestamp: 1234,
        code: COMPANION_EVENT_CODES.TASK_FAILED,
        category: "task",
        level: "error",
        message: "Task failed",
        questId: "quest-1",
        questName: "Example Quest",
        taskType: "GAME",
        failure: companionFailure({
            terminal: true,
            retryable: true,
            attempt: 5,
            maxAttempts: 5,
            httpStatus: 503,
            upstreamCode: 12345,
            reason: "Too many network failures",
        }),
    });
    await flushCompanionEvents();

    assert.deepEqual(seen.map(row => row.listener), ["first", "second"]);
    assert.equal(seen[0].event.timestamp, 1234);
    assert.equal(seen[0].event.failure?.terminal, true);
    assert.equal(seen[0].event.failure?.retryable, true);
    assert.equal(seen[0].event.failure?.httpStatus, 503);
    assert.equal(seen[0].event.failure?.upstreamCode, 12345);
    assert.equal(Object.isFrozen(seen[0].event), true);
    assert.equal(Object.isFrozen(seen[0].event.failure), true);
    assert.equal(seen[0].event, seen[1].event);
});

test("event observers cannot synchronously re-enter the producer stack", async () => {
    let delivered = false;
    subscribeCompanionEvents(() => { delivered = true; });

    emitCompanionEvent({
        code: COMPANION_EVENT_CODES.ENGINE_STARTED,
        category: "system",
        level: "info",
        message: "started",
    });

    assert.equal(delivered, false, "Delivery must be deferred until the producer transition returns.");
    await flushCompanionEvents();
    assert.equal(delivered, true);
});

test("task.failed always carries terminal failure metadata even without transport details", async () => {
    const seen: CompanionEvent[] = [];
    subscribeCompanionEvents(event => seen.push(event));

    emitCompanionEvent({
        code: COMPANION_EVENT_CODES.TASK_FAILED,
        category: "task",
        level: "error",
        message: "Task timed out",
        questId: "quest-timeout",
        reason: "Timeout exceeded",
    });
    await flushCompanionEvents();

    assert.equal(seen.length, 1);
    const event = seen[0]!;
    assert.equal(event.failure?.terminal, true);
    assert.equal(event.failure?.retryable, false);
    assert.equal(event.failure?.attempt, null);
    assert.equal(event.failure?.maxAttempts, null);
    assert.equal(event.failure?.httpStatus, null);
    assert.equal(event.failure?.upstreamCode, null);
    assert.equal(event.failure?.reason, "Timeout exceeded");
});

test("one throwing listener cannot block later listeners", async () => {
    const originalError = console.error;
    const logged: unknown[][] = [];
    console.error = (...args: unknown[]) => { logged.push(args); };

    try {
        let delivered = 0;
        subscribeCompanionEvents(() => { throw new Error("listener exploded"); });
        subscribeCompanionEvents(() => { delivered++; });

        emitCompanionEvent({
            code: COMPANION_EVENT_CODES.ENGINE_STARTED,
            category: "system",
            level: "info",
            message: "Engine started",
        });
        await flushCompanionEvents();

        assert.equal(delivered, 1);
        assert.equal(logged.length, 1);
    } finally {
        console.error = originalError;
    }
});

test("unsubscribe is idempotent and only affects later emissions", async () => {
    let calls = 0;
    const unsubscribe = subscribeCompanionEvents(() => { calls++; });

    emitCompanionEvent({
        code: COMPANION_EVENT_CODES.ENGINE_STARTED,
        category: "system",
        level: "info",
        message: "started",
    });
    unsubscribe();
    unsubscribe();
    emitCompanionEvent({
        code: COMPANION_EVENT_CODES.ENGINE_STOPPED,
        category: "system",
        level: "info",
        message: "stopped",
    });
    await flushCompanionEvents();

    assert.equal(calls, 1, "A listener receives the event whose emission already captured it, but no later emissions.");
});

test("failure normalization rejects invalid counters/status without inventing values", () => {
    const failure = companionFailure({
        terminal: false,
        retryable: true,
        attempt: 0,
        maxAttempts: Number.NaN,
        httpStatus: 999,
        upstreamCode: null,
        reason: "",
    });

    assert.deepEqual(failure, {
        terminal: false,
        retryable: true,
        attempt: null,
        maxAttempts: null,
        httpStatus: null,
        upstreamCode: null,
        reason: null,
    });

    const inconsistent = companionFailure({
        terminal: true,
        retryable: false,
        attempt: 3,
        maxAttempts: 1,
    });
    assert.equal(inconsistent.attempt, 3);
    assert.equal(inconsistent.maxAttempts, null, "An impossible maxAttempts < attempt pair must not be published.");
});

test("known credential shapes are redacted before companion delivery", async () => {
    const seen: CompanionEvent[] = [];
    subscribeCompanionEvents(event => seen.push(event));

    const failure = companionFailure({
        terminal: true,
        retryable: false,
        upstreamCode: "access_token=code-secret",
        reason: "Authorization: Bearer secret-token proxy_ticket=proxy-secret",
    });
    emitCompanionEvent({
        code: COMPANION_EVENT_CODES.BYPASS_FAILED,
        category: "bypass",
        level: "error",
        message: "request failed https://example.invalid/?code=oauth-secret&ticket=ticket-secret",
        reason: "cookie=session-secret access_token=access-secret",
        failure,
    });
    await flushCompanionEvents();

    assert.equal(seen.length, 1);
    const serialized = JSON.stringify(seen[0]);
    for (const secret of ["secret-token", "proxy-secret", "oauth-secret", "ticket-secret", "session-secret", "access-secret", "code-secret"]) {
        assert.doesNotMatch(serialized, new RegExp(secret));
    }
    assert.match(serialized, /\[REDACTED\]/);
    assert.equal(sanitizeCompanionText("auth code=my-code"), "auth code=[REDACTED]");
    assert.equal(sanitizeCompanionText("token=plain-token ticket=plain-ticket"), "token=[REDACTED] ticket=[REDACTED]");

    const json = sanitizeCompanionText(JSON.stringify({
        access_token: "json-access-secret",
        authCode: "json-auth-secret",
        proxyTicket: "json-ticket-secret",
        cookie: "json-cookie-secret",
    }));
    for (const secret of ["json-access-secret", "json-auth-secret", "json-ticket-secret", "json-cookie-secret"]) {
        assert.doesNotMatch(json, new RegExp(secret));
    }
});

test("every published code declares whether its contract is stable or provisional", () => {
    const codes = Object.values(COMPANION_EVENT_CODES).sort();
    const declared = Object.keys(COMPANION_EVENT_CODE_STABILITY).sort();
    assert.deepEqual(declared, codes);
    assert.notEqual(COMPANION_EVENT_CODES.ENGINE_START_FAILED, COMPANION_EVENT_CODES.ENGINE_FAILED,
        "A failed start and a fatal failure after engine.started are distinct lifecycle facts.");
    assert.equal(COMPANION_EVENT_CODE_STABILITY[COMPANION_EVENT_CODES.ENGINE_START_FAILED], "stable");
    assert.equal(COMPANION_EVENT_CODE_STABILITY[COMPANION_EVENT_CODES.ENGINE_FAILED], "stable");
    assert.equal(COMPANION_EVENT_CODE_STABILITY[COMPANION_EVENT_CODES.TASK_FAILED], "stable");
    assert.equal(COMPANION_EVENT_CODE_STABILITY[COMPANION_EVENT_CODES.CYCLE_STARTED], "provisional");
});
