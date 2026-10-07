/*
 * Audisk, a Vencord userplugin
 * Audistask Copyright (c) 2026 Kiraa (AkiyamaKira2003)
 * SPDX-License-Identifier: MIT
 *
 * Native (main-process) IPC handlers. Discord's renderer CSP blocks
 * connect-src to *.discordsays.com, so the ACHIEVEMENT bypass has to
 * round-trip those POSTs through the main process where Node fetch
 * runs without CSP restrictions.
 */

import { existsSync, readFileSync, writeFileSync } from "node:fs";
import { join } from "node:path";

import { IpcMainInvokeEvent, shell } from "electron";

// This is the real trust boundary: the renderer could be compromised and these handlers run
// in the privileged, CSP-free main process. Validate every renderer-supplied value that shapes
// the request, not just appId: appId and questId must be numeric, and the referrer must be
// https pointing exactly at this app's discordsays host.
const NUMERIC_ID = /^\d+$/;

function validParams(appId: string, questId: string, referrer: string): boolean {
    if (!NUMERIC_ID.test(String(appId)) || !NUMERIC_ID.test(String(questId))) return false;
    try {
        const u = new URL(referrer);
        return u.protocol === "https:" && u.hostname === `${appId}.discordsays.com`;
    } catch {
        return false;
    }
}

const rejected = (): DiscordSaysResponse => ({ ok: false, status: 0, body: JSON.stringify({ error: "invalid request params" }) });

export interface DiscordSaysResponse {
    ok: boolean;
    status: number;
    body: string;
}

export interface AudiskInstallInfo {
    available: boolean;
    hadVencordBefore: boolean | null;
    defaultRemoveVencord: boolean;
    branch: string;
}

function audiskInstallDir(): string | null {
    const base = process.env.LOCALAPPDATA;
    return base ? join(base, "AudiskVencord") : null;
}

export async function getInstallInfo(_: IpcMainInvokeEvent): Promise<AudiskInstallInfo> {
    const installDir = audiskInstallDir();
    if (!installDir) return { available: false, hadVencordBefore: null, defaultRemoveVencord: false, branch: "canary" };

    const launcher = join(installDir, ".audisk-uninstall.cmd");
    const statePath = join(installDir, ".audisk-install-state.json");
    let hadVencordBefore: boolean | null = null;
    let branch = "canary";
    try {
        const state = JSON.parse(readFileSync(statePath, "utf8"));
        if (typeof state?.hadVencordBefore === "boolean") hadVencordBefore = state.hadVencordBefore;
        if (typeof state?.branch === "string" && /^(stable|canary|ptb)$/.test(state.branch)) branch = state.branch;
    } catch {}

    return {
        available: existsSync(launcher),
        hadVencordBefore,
        defaultRemoveVencord: hadVencordBefore === false,
        branch,
    };
}

export async function uninstallAudisk(_: IpcMainInvokeEvent, removeVencord: boolean): Promise<{ started: boolean; error?: string; }> {
    if (typeof removeVencord !== "boolean") return { started: false, error: "invalid option" };
    const installDir = audiskInstallDir();
    if (!installDir) return { started: false, error: "LOCALAPPDATA is unavailable" };

    const launcher = join(installDir, ".audisk-uninstall.cmd");
    const requestPath = join(installDir, ".audisk-uninstall-request.json");
    if (!existsSync(launcher)) return { started: false, error: "uninstall helper is not installed" };

    try {
        writeFileSync(requestPath, JSON.stringify({ removeVencord }), { encoding: "utf8" });
        const error = await shell.openPath(launcher);
        return error ? { started: false, error } : { started: true };
    } catch (error) {
        return { started: false, error: error instanceof Error ? error.message : String(error) };
    }
}

async function discordsaysFetch(url: string, headers: Record<string, string>, body: string): Promise<DiscordSaysResponse> {
    try {
        // redirect:"error" so a 3xx can't bounce the X-Auth-Token / proxy-ticket Referer to
        // another host from the CSP-free main process. The acf endpoints answer 200/4xx directly.
        const res = await fetch(url, { method: "POST", headers, body, redirect: "error" });
        return { ok: res.ok, status: res.status, body: await res.text() };
    } catch (e: any) {
        return { ok: false, status: 0, body: JSON.stringify({ error: e?.message ?? String(e) }) };
    }
}

export async function discordsaysAuthorize(_: IpcMainInvokeEvent, opts: { appId: string; questId: string; authCode: string; referrer: string; }): Promise<DiscordSaysResponse> {
    if (!validParams(opts.appId, opts.questId, opts.referrer)) return rejected();
    return discordsaysFetch(
        `https://${opts.appId}.discordsays.com/.proxy/acf/authorize`,
        { "Content-Type": "application/json", "X-Auth-Token": "", "X-Discord-Quest-ID": opts.questId, Referer: opts.referrer },
        JSON.stringify({ code: opts.authCode })
    );
}

export async function discordsaysProgress(_: IpcMainInvokeEvent, opts: { appId: string; questId: string; token: string; target: number; referrer: string; }): Promise<DiscordSaysResponse> {
    if (!validParams(opts.appId, opts.questId, opts.referrer)) return rejected();
    return discordsaysFetch(
        `https://${opts.appId}.discordsays.com/.proxy/acf/quest/progress`,
        { "Content-Type": "application/json", "X-Auth-Token": opts.token, "X-Discord-Quest-ID": opts.questId, Referer: opts.referrer },
        JSON.stringify({ progress: opts.target })
    );
}
