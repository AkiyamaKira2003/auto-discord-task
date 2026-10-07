/*
 * Audisk, a Vencord userplugin
 * Audistask Copyright (c) 2026 Kiraa (AkiyamaKira2003)
 * SPDX-License-Identifier: MIT
 *
 * Which executable a spoofed game claims, and where it says it lives.
 *
 * Every payload below is the real `executables` array Discord returned from
 * /applications/public on 2026-09-21 for a quest that was live that day, copied verbatim.
 */

import assert from "node:assert/strict";
import { test } from "node:test";

import { pickExecutable } from "../questConfig";

const win32 = (...names: string[]) => names.map(name => ({ os: "win32", name, is_launcher: false }));

test("a bare file name goes under the game folder, which is the ordinary case", () => {
    const got = pickExecutable(win32("aces.exe"), "War Thunder");
    assert.deepEqual(got, { exeName: "aces.exe", relPath: "War Thunder/aces.exe" });
});

test("an entry that already names the game folder is not given a second copy of it", () => {
    // This is Dragonheir, and it is what produced
    // c:/program files/dragonheir silent gods/dragonheir silent gods/dragonheir.exe
    const got = pickExecutable(
        win32("dragonheir silent gods/dragonheir.exe", "dragonheir.exe"),
        "Dragonheir Silent Gods",
    );
    assert.equal(got.exeName, "dragonheir.exe");
    assert.equal(got.relPath.toLowerCase().split("dragonheir silent gods").length - 1, 1);
});

test("the executable name never carries a path separator", () => {
    for (const [names, clean] of [
        [win32("dragonheir silent gods/dragonheir.exe"), "Dragonheir Silent Gods"],
        [win32("win64/marvel-win64-shipping.exe"), "Marvel Rivals"],
        [win32("launcher/df_launcher.exe"), "Delta Force"],
    ] as const) {
        const { exeName } = pickExecutable(names, clean);
        assert.ok(!/[\\/]/.test(exeName), `${exeName} carries a separator`);
    }
});

test("a subdirectory that is not the game folder is kept under it", () => {
    const got = pickExecutable(win32("win64/marvel-win64-shipping.exe"), "Marvel Rivals");
    assert.deepEqual(got, {
        exeName: "marvel-win64-shipping.exe",
        relPath: "Marvel Rivals/win64/marvel-win64-shipping.exe",
    });
});

test("an internal test build loses to a shipping one", () => {
    // Marvel Rivals lists the test build first, so taking entry zero claimed a binary that
    // essentially no player runs.
    const got = pickExecutable(
        win32(
            "win64/marvel-win64-test.exe",
            "win64/marvel-win64-shipping.exe",
            "win64/marvel.exe",
            "marvelrivals/marvelrivals_launcher.exe",
        ),
        "Marvel Rivals",
    );
    assert.ok(!/test/i.test(got.exeName), `picked ${got.exeName}`);
});

test("a test build is still used when it is the only thing listed", () => {
    const got = pickExecutable(win32("win64/marvel-win64-test.exe"), "Marvel Rivals");
    assert.equal(got.exeName, "marvel-win64-test.exe");
});

test("the launcher loses to the game when both are listed", () => {
    const got = pickExecutable(
        win32("marvelrivals/marvelrivals_launcher.exe", "win64/marvel-win64-shipping.exe"),
        "Marvel Rivals",
    );
    assert.equal(got.exeName, "marvel-win64-shipping.exe");
});

test("the answer does not depend on the order Discord happened to return", () => {
    // Discord really does reorder this. Marvel Rivals came back as [test, shipping, marvel,
    // launcher] and then as [test, launcher, marvel, shipping] minutes apart on 2026-09-21,
    // which under the old "first win32 entry" rule meant a different executable per run.
    const names = [
        "win64/marvel-win64-test.exe",
        "win64/marvel-win64-shipping.exe",
        "win64/marvel.exe",
        "marvelrivals/marvelrivals_launcher.exe",
    ];
    const orders = [
        names,
        [names[0], names[3], names[2], names[1]],
        [names[3], names[2], names[1], names[0]],
        [names[1], names[0], names[3], names[2]],
    ];
    const answers = new Set(orders.map(o => JSON.stringify(pickExecutable(win32(...o), "Marvel Rivals"))));
    assert.equal(answers.size, 1, `orderings disagreed: ${[...answers].join(" vs ")}`);
    assert.equal(JSON.parse([...answers][0]).exeName, "marvel-win64-shipping.exe");
});

test("a name that merely contains the letters test is not treated as a test build", () => {
    const got = pickExecutable(win32("contest.exe"), "Contest");
    assert.equal(got.exeName, "contest.exe");
});

test("a bare name wins over one that needs a directory guessed", () => {
    const got = pickExecutable(win32("where winds meet.exe", "wwm.exe"), "Where Winds Meet");
    assert.equal(got.exeName, "where winds meet.exe");
});

test("backslashes in Discord's own entry are normalised", () => {
    const got = pickExecutable(win32("win64\\game.exe"), "Some Game");
    assert.equal(got.exeName, "game.exe");
    assert.equal(got.relPath, "Some Game/win64/game.exe");
});

test("non-win32 entries are ignored", () => {
    const mixed = [
        { os: "darwin", name: "roblox.app", is_launcher: false },
        { os: "win32", name: "roblox.exe", is_launcher: false },
    ];
    assert.equal(pickExecutable(mixed, "Roblox").exeName, "roblox.exe");
});

test("no win32 entry at all falls back to a name built from the game", () => {
    assert.deepEqual(pickExecutable([], "War Thunder"), {
        exeName: "WarThunder.exe",
        relPath: "War Thunder/WarThunder.exe",
    });
    assert.deepEqual(pickExecutable(undefined, "War Thunder"), {
        exeName: "WarThunder.exe",
        relPath: "War Thunder/WarThunder.exe",
    });
});

test("the nine apps live on 2026-09-21 all produce a usable process name and path", () => {
    const live: Array<[string, string[]]> = [
        ["War Thunder", ["aces.exe"]],
        ["Wizard101", ["wizard101.exe", "wizardgraphicalclient.exe"]],
        ["Roblox", ["roblox.exe", "robloxplayerbeta.exe"]],
        ["Dragonheir Silent Gods", ["dragonheir silent gods/dragonheir.exe", "dragonheir.exe"]],
        ["Marvel Rivals", ["win64/marvel-win64-test.exe", "win64/marvel-win64-shipping.exe", "win64/marvel.exe", "marvelrivals/marvelrivals_launcher.exe"]],
        ["Delta Force", ["deltaforceclient.exe", "launcher/df_launcher.exe", "win64/deltaforceclient-win64-shipping.exe"]],
        ["Where Winds Meet", ["wwm.exe", "where winds meet.exe"]],
        ["Aniimo", ["aniimo.exe"]],
    ];

    for (const [clean, names] of live) {
        const { exeName, relPath } = pickExecutable(win32(...names), clean);
        assert.ok(!/[\\/]/.test(exeName), `${clean}: exeName ${exeName} has a separator`);
        assert.ok(exeName.endsWith(".exe"), `${clean}: exeName ${exeName} is not an exe`);
        assert.ok(relPath.endsWith(exeName), `${clean}: relPath ${relPath} does not end in the exe`);

        // No segment may repeat back to back, which is the doubling this replaced.
        const segs = relPath.toLowerCase().split("/");
        for (let i = 1; i < segs.length; i++) {
            assert.notEqual(segs[i], segs[i - 1], `${clean}: relPath ${relPath} doubles a segment`);
        }
    }
});
