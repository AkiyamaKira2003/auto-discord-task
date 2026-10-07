/*
 * Audisk - Kiraa floating dashboard
 * SPDX-License-Identifier: MIT
 *
 * Vencord-native port of the standalone userscript's floating dashboard.
 * It never starts a second Audisk engine: every control delegates to the plugin lifecycle.
 */

import { SettingsStore } from "@api/Settings";
import type { PluginNative } from "@utils/types";
import { openUserProfileModal, SelectedChannelStore, SelectedGuildStore, UserUtils } from "@webpack/common";

import {
    type DashboardEntry,
    isEngineRunning,
    readDashboard,
    subscribeDashboard,
} from "./audisk";
import { type CompanionEventLevel,subscribeCompanionEvents } from "./companionEvents";
import { settings } from "./settings";

export interface FloatingDashboardControls {
    version: string;
    start: () => Promise<string>;
    stop: () => Promise<string>;
    pauseAll: () => Promise<string>;
    resumeAll: () => Promise<string>;
    status: () => Promise<string>;
}

const ROOT_ID = "audisk-kiraa-ui";
const STYLE_ID = "audisk-kiraa-styles";
const MAX_LOGS = 50;
const OWNER_USER_ID = "581419585249607710";
const OWNER_USERNAME = "akiyamakira2003";
const NATIVE_QUEST_STATUS_ID = "audisk-native-quest-status";
const Native = VencordNative.pluginHelpers.Audisk as PluginNative<typeof import("./native")>;

type BooleanSettingKey =
    | "autoStart"
    | "autoEnroll"
    | "orbQuestsOnly"
    | "watchForEnrollments"
    | "achievementBypass"
    | "tryToClaimReward"
    | "hideActivity"
    | "playSound"
    | "verboseLogging";

type NumberSettingKey = "playSessionTail" | "gameConcurrency" | "videoConcurrency";

const BOOLEAN_SETTINGS: Array<{ key: BooleanSettingKey; label: string; hint: string; }> = [
    { key: "autoStart", label: "Auto start", hint: "Start Audisk when the plugin loads." },
    { key: "autoEnroll", label: "Auto enroll", hint: "Accept eligible quests automatically." },
    { key: "orbQuestsOnly", label: "Orb quests only", hint: "Leave non-Orb quests untouched." },
    { key: "watchForEnrollments", label: "Watch enrollments", hint: "Wake Audisk when you accept a quest." },
    { key: "achievementBypass", label: "Achievement bypass", hint: "Allow the OAuth activity bypass." },
    { key: "tryToClaimReward", label: "Auto claim", hint: "Try to claim rewards after completion." },
    { key: "hideActivity", label: "Hide activity", hint: "Hide the temporary Playing status." },
    { key: "playSound", label: "Completion sound", hint: "Play a tone when work completes." },
    { key: "verboseLogging", label: "Verbose logging", hint: "Promote Audisk debug logs." },
];

const NUMBER_SETTINGS: Array<{ key: NumberSettingKey; label: string; hint: string; values: number[]; suffix?: string; }> = [
    { key: "playSessionTail", label: "Game tail", hint: "Maximum randomized post-completion presence.", values: [0, 1, 2, 3, 5, 8], suffix: " min" },
    { key: "gameConcurrency", label: "Game concurrency", hint: "Parallel game quests.", values: [1, 2, 3] },
    { key: "videoConcurrency", label: "Video concurrency", hint: "Parallel video quests.", values: [1, 2, 3, 4] },
];

function el<K extends keyof HTMLElementTagNameMap>(
    tag: K,
    className?: string,
    text?: string,
): HTMLElementTagNameMap[K] {
    const node = document.createElement(tag);
    if (className) node.className = className;
    if (text != null) node.textContent = text;
    return node;
}

function pct(entry: DashboardEntry): number {
    if (entry.max <= 0) return 0;
    return Math.max(0, Math.min(100, (entry.cur / entry.max) * 100));
}

function stateClass(status: string): string {
    if (status === "COMPLETED" || status === "CLAIMED") return "done";
    if (status === "FAILED") return "failed";
    if (status === "PAUSED") return "paused";
    if (status === "QUEUE" || status === "PENDING") return "pending";
    return "running";
}

function iconFor(entry: DashboardEntry): string {
    if (entry.status === "COMPLETED" || entry.status === "CLAIMED") return "✓";
    if (entry.status === "FAILED") return "■";
    if (entry.status === "PAUSED" || entry.status === "QUEUE" || entry.status === "PENDING") return "◷";
    if (entry.type === "WATCH_VIDEO") return "▶";
    if (String(entry.type).includes("GAME")) return "◆";
    if (String(entry.type).includes("STREAM")) return "▣";
    if (entry.type === "ACHIEVEMENT") return "◎";
    return "ϟ";
}

function sortEntries(entries: DashboardEntry[]): DashboardEntry[] {
    const order: Record<string, number> = {
        RUNNING: 0,
        QUEUE: 1,
        PAUSED: 2,
        PENDING: 3,
        FAILED: 4,
        COMPLETED: 5,
        CLAIMED: 6,
    };
    return [...entries].sort((a, b) => {
        const state = (order[a.status] ?? 20) - (order[b.status] ?? 20);
        if (state !== 0) return state;
        return pct(b) - pct(a);
    });
}

function discordIcon(): SVGSVGElement {
    const svg = document.createElementNS("http://www.w3.org/2000/svg", "svg");
    svg.setAttribute("viewBox", "0 0 24 24");
    svg.setAttribute("width", "15");
    svg.setAttribute("height", "15");
    svg.setAttribute("aria-hidden", "true");
    const path = document.createElementNS("http://www.w3.org/2000/svg", "path");
    path.setAttribute("fill", "currentColor");
    path.setAttribute("d", "M19.54 5.34A16.7 16.7 0 0 0 15.44 4l-.5 1.02a15.3 15.3 0 0 0-5.86 0L8.56 4a16.8 16.8 0 0 0-4.1 1.35C1.86 9.2 1.16 12.95 1.5 16.64a16.5 16.5 0 0 0 5.03 2.54l1.21-1.66a10.7 10.7 0 0 1-1.9-.91l.47-.37c3.66 1.7 7.63 1.7 11.25 0l.48.37c-.62.36-1.25.66-1.9.91l1.2 1.66a16.5 16.5 0 0 0 5.04-2.54c.4-4.27-.7-7.99-2.84-11.3ZM8.85 14.38c-1.1 0-2-1.02-2-2.27 0-1.25.88-2.28 2-2.28s2.02 1.03 2 2.28c0 1.25-.88 2.27-2 2.27Zm6.3 0c-1.1 0-2-1.02-2-2.27 0-1.25.88-2.28 2-2.28s2.02 1.03 2 2.28c0 1.25-.88 2.27-2 2.27Z");
    svg.appendChild(path);
    return svg;
}

function installStyle(): HTMLStyleElement {
    document.getElementById(STYLE_ID)?.remove();
    const style = document.createElement("style");
    style.id = STYLE_ID;
    style.textContent = `
        @keyframes audiskKiraaSlideIn {
            from { transform: translateY(-16px); opacity: 0; }
            to { transform: translateY(0); opacity: 1; }
        }
        #${ROOT_ID} {
            --audisk-panel-height: min(560px, calc(100vh - 96px));
            position: fixed; top: 32px; right: 20px; width: 380px;
            height: var(--audisk-panel-height); max-height: var(--audisk-panel-height);
            display: flex; flex-direction: column; overflow: hidden; box-sizing: border-box;
            z-index: 1002; user-select: none; -webkit-app-region: no-drag;
            color: var(--text-default); background: var(--background-base-low);
            border: 1px solid var(--border-subtle); border-radius: var(--radius-lg, 12px);
            box-shadow: var(--shadow-button-overlay); font-family: var(--font-primary);
            animation: audiskKiraaSlideIn .22s ease;
        }
        #${ROOT_ID} * { box-sizing: border-box; }
        #${ROOT_ID} .ok-head {
            flex: 0 0 auto; display: flex; align-items: center; justify-content: space-between;
            gap: 10px; padding: 12px 16px; cursor: grab;
            background: var(--background-mod-muted); border-bottom: 1px solid var(--border-subtle);
        }
        #${ROOT_ID} .ok-head.dragging { cursor: grabbing; }
        #${ROOT_ID} .ok-title {
            min-width: 0; display: flex; align-items: center; gap: 8px;
            font-weight: 700; font-size: 15px; color: var(--text-strong);
        }
        #${ROOT_ID} .ok-bolt { display: flex; color: var(--text-brand); }
        #${ROOT_ID} .ok-owner {
            font-size: 12px; margin-left: -4px; padding-top: 2px;
            font-weight: 600; color: #61d5ff;
        }
        #${ROOT_ID} .ok-version {
            opacity: .6; font-size: 10px; margin-left: -2px; padding-top: 3px; font-weight: 500;
        }
        #${ROOT_ID} .ok-controls { display: flex; gap: 10px; align-items: center; position: relative; }
        #${ROOT_ID} .ok-status-dot {
            width: 8px; height: 8px; border-radius: 50%; flex: 0 0 auto;
            box-shadow: 0 0 0 2px color-mix(in srgb, currentColor 18%, transparent);
        }
        #${ROOT_ID} .ok-status-dot.good { color: var(--text-feedback-positive); background: currentColor; }
        #${ROOT_ID} .ok-status-dot.warn { color: var(--text-feedback-warning); background: currentColor; }
        #${ROOT_ID} .ok-status-dot.bad { color: var(--text-feedback-critical); background: currentColor; }
        #${ROOT_ID} .ok-action {
            cursor: pointer; transition: .2s; border-radius: var(--radius-sm);
            font-size: 11px; font-weight: 800; padding: 4px 9px;
            background: transparent; border: 1px solid currentColor; font-family: inherit;
        }
        #${ROOT_ID} .ok-action.start { color: var(--text-feedback-positive); }
        #${ROOT_ID} .ok-action.pause { color: var(--text-feedback-warning); }
        #${ROOT_ID} .ok-action.resume { color: #b67cff; }
        #${ROOT_ID} .ok-action.stop { color: var(--text-feedback-critical); }
        #${ROOT_ID} .ok-action:hover:not(:disabled) { background: color-mix(in srgb, currentColor 12%, transparent); }
        #${ROOT_ID} .ok-action:disabled { opacity: .45; cursor: default; }
        #${ROOT_ID} .ok-link-btn {
            cursor: pointer; transition: .2s; display: flex; align-items: center;
            font-size: 11px; font-weight: 600; color: var(--text-muted);
            background: transparent; border: 0; padding: 0; font-family: inherit;
        }
        #${ROOT_ID} .ok-link-btn:hover { color: var(--text-default); }
        #${ROOT_ID} .ok-options {
            position: absolute; right: 0; top: 28px; width: 286px; z-index: 4;
            display: none; padding: 8px; border-radius: var(--radius-sm);
            background: var(--background-base-low); border: 1px solid var(--border-muted);
            box-shadow: var(--shadow-button-overlay);
            max-height: min(365px, calc(var(--audisk-panel-height) - 92px)); overflow-y: auto;
            overscroll-behavior: contain; scrollbar-gutter: stable; scrollbar-width: thin;
            scrollbar-color: var(--scrollbar-auto-scrollbar-color-thumb) transparent;
        }
        #${ROOT_ID} .ok-options.open { display: flex; flex-direction: column; gap: 6px; }
        #${ROOT_ID} .ok-options button {
            width: 100%; padding: 7px 8px; border-radius: var(--radius-sm);
            border: 1px solid var(--border-muted); background: var(--control-secondary-background-default);
            color: var(--text-default); cursor: pointer; font-size: 10px; font-weight: 700;
            font-family: inherit; text-align: left;
        }
        #${ROOT_ID} .ok-options .danger { color: var(--text-feedback-critical); }
        #${ROOT_ID} .ok-options .uninstall {
            color: #ff5d63; background: color-mix(in srgb, #8f1820 42%, var(--background-base-low));
            border-color: color-mix(in srgb, #ff5d63 50%, var(--border-muted)); font-weight: 800;
        }
        #${ROOT_ID} .ok-options .uninstall:hover {
            color: #fff; background: color-mix(in srgb, #a61922 70%, var(--background-base-low));
        }
        #${ROOT_ID} .ok-options-title {
            margin: 3px 2px 1px; color: var(--text-muted); font-size: 9px; font-weight: 800;
            letter-spacing: .7px; text-transform: uppercase;
        }
        #${ROOT_ID} .ok-setting-row {
            display: grid; grid-template-columns: minmax(0, 1fr) auto; align-items: center; gap: 10px;
            padding: 7px 8px; border-radius: var(--radius-sm); border: 1px solid var(--border-muted);
            background: color-mix(in srgb, var(--control-secondary-background-default) 72%, transparent);
        }
        #${ROOT_ID} .ok-setting-copy { min-width: 0; display: flex; flex-direction: column; gap: 2px; }
        #${ROOT_ID} .ok-setting-label { font-size: 10px; font-weight: 750; color: var(--text-default); }
        #${ROOT_ID} .ok-setting-hint { font-size: 9px; line-height: 1.25; color: var(--text-muted); }
        #${ROOT_ID} .ok-setting-check {
            appearance: auto; -webkit-appearance: checkbox;
            width: 16px; height: 16px; margin: 0; flex: 0 0 auto; cursor: pointer;
            accent-color: #5865F2;
        }
        #${ROOT_ID} .ok-setting-check:focus-visible {
            outline: 2px solid color-mix(in srgb, #5865F2 70%, white);
            outline-offset: 2px;
        }
        #${ROOT_ID} .ok-setting-select {
            min-width: 68px; border: 1px solid var(--border-muted); border-radius: 6px;
            background: var(--input-background); color: var(--text-default); padding: 4px 6px;
            font: 700 10px var(--font-primary); outline: none;
        }
        #${ROOT_ID} .ok-body {
            min-height: 0; flex: 1 1 auto; overflow-y: auto; padding: 12px;
            display: flex; flex-direction: column;
        }
        #${ROOT_ID} .ok-empty {
            padding: 24px 16px; text-align: center; color: var(--text-muted);
            font-size: 12px; line-height: 1.5;
        }
        #${ROOT_ID} .ok-card {
            --state: var(--ansi-bright-blue);
            --icon-bg-opacity: 15%;
            --icon-color: var(--state);
            display: flex; gap: 12px; padding: 10px 12px; margin-bottom: 8px; align-items: center;
            border-radius: var(--radius-sm, 7px);
            background: var(--control-secondary-background-default);
            border: 1px solid var(--border-muted); border-left: 4px solid var(--state);
            box-shadow: var(--shadow-low); flex-shrink: 0;
        }
        #${ROOT_ID} .ok-card.done { --state: var(--ansi-green); --icon-bg-opacity: 100%; --icon-color: #fff; }
        #${ROOT_ID} .ok-card.failed { --state: var(--ansi-red); }
        #${ROOT_ID} .ok-card.pending { --state: var(--ansi-bright-yellow); }
        #${ROOT_ID} .ok-card.paused { --state: #b67cff; }
        #${ROOT_ID} .ok-icon {
            --p: 0%; position: relative; width: 40px; height: 40px; border-radius: 50%;
            flex: 0 0 auto;
            background-color: color-mix(in srgb, var(--state) var(--icon-bg-opacity), transparent);
            display: flex; align-items: center; justify-content: center;
        }
        #${ROOT_ID} .ok-card.running .ok-icon::before {
            content: ''; position: absolute; inset: 0; border-radius: 50%; z-index: 1;
            background: conic-gradient(lch(71 59 139) 0% var(--p), var(--border-subtle) var(--p) 100%);
            -webkit-mask-image: radial-gradient(circle at center, transparent 16px, black 17px);
            mask-image: radial-gradient(circle at center, transparent 16px, black 17px);
        }
        #${ROOT_ID} .ok-icon-inner { z-index: 2; color: var(--icon-color); display: flex; }
        #${ROOT_ID} .ok-icon-overlay {
            position: absolute; inset: 0; z-index: 3; display: flex; align-items: center; justify-content: center;
            font-size: 11px; font-weight: 800; color: var(--text-default);
            opacity: 0; transition: opacity .2s; pointer-events: none;
        }
        #${ROOT_ID} .ok-card.running:hover .ok-icon-inner { filter: blur(2px); opacity: .3; }
        #${ROOT_ID} .ok-card.running:hover .ok-icon-overlay { opacity: 1; }
        #${ROOT_ID} .ok-quest { min-width: 0; flex: 1 1 auto; display: flex; flex-direction: column; gap: 2px; }
        #${ROOT_ID} .ok-status {
            color: var(--state); font-size: 10px; font-weight: 800; text-transform: uppercase;
            letter-spacing: .5px;
        }
        #${ROOT_ID} .ok-quest-name {
            white-space: nowrap; overflow: hidden; text-overflow: ellipsis;
            font-size: 13px; font-weight: 700; color: var(--text-strong); letter-spacing: .2px; line-height: 1.2;
        }
        #${ROOT_ID} .ok-meta {
            font-size: 11px; font-weight: 700; color: var(--text-muted);
            display: flex; justify-content: space-between; gap: 8px;
        }
        #${ROOT_ID} .ok-reason { margin-top: 3px; font-size: 10px; color: var(--text-muted); white-space: normal; }
        #${ROOT_ID} .ok-logs {
            padding: 10px 14px; background: var(--background-base-lower); flex: 0 0 auto;
            font-family: Consolas, Monaco, monospace; font-size: 11px; height: 110px;
            overflow-y: auto; border-top: 1px solid var(--border-subtle); scroll-behavior: smooth;
        }
        #${ROOT_ID} .ok-log { margin-bottom: 6px; display: flex; gap: 8px; line-height: 1.4; padding-bottom: 4px; }
        #${ROOT_ID} .ok-time { opacity: .5; min-width: 50px; font-size: 10px; }
        #${ROOT_ID} .ok-log.info { color: var(--text-feedback-info); opacity: .8; }
        #${ROOT_ID} .ok-log.success { color: var(--text-feedback-positive); }
        #${ROOT_ID} .ok-log.warning { color: var(--text-feedback-warning); }
        #${ROOT_ID} .ok-log.error { color: var(--text-feedback-critical); }
        #${ROOT_ID} .ok-log.debug { color: #949ba4; }
        #${ROOT_ID} .ok-footer {
            flex: 0 0 auto; display: flex; justify-content: space-between; align-items: center;
            padding: 8px 12px; border-top: 1px solid var(--border-subtle);
            background: var(--background-base-low); position: relative;
        }
        #${ROOT_ID} .ok-discord-profile {
            display: inline-flex; align-items: center; justify-content: center; gap: 7px; cursor: pointer;
            border: 1px solid #5865F2; border-radius: 8px; min-height: 30px; padding: 0 10px;
            color: #c9ceff; background: color-mix(in srgb, #5865F2 14%, transparent);
            font-family: inherit; font-size: 11px; font-weight: 700; line-height: 1;
            transition: background .16s ease, color .16s ease, box-shadow .16s ease;
        }
        #${ROOT_ID} .ok-discord-profile:hover {
            color: #fff; background: color-mix(in srgb, #5865F2 28%, transparent);
            box-shadow: 0 0 0 2px color-mix(in srgb, #5865F2 18%, transparent);
        }
        #${ROOT_ID} .ok-discord-profile svg { flex: 0 0 auto; display: block; }
        #${ROOT_ID} .ok-discord-profile span { display: inline-flex; align-items: center; line-height: 1; }
        #${ROOT_ID} .ok-help-wrap { position: relative; display: flex; align-items: center; }
        #${ROOT_ID} .ok-help {
            width: 24px; height: 24px; display: inline-flex; align-items: center; justify-content: center;
            border: 1px solid var(--border-muted); border-radius: 50%; color: var(--text-muted);
            background: transparent; cursor: pointer; font: 800 12px var(--font-primary);
            transition: color .15s ease, background .15s ease, border-color .15s ease;
        }
        #${ROOT_ID} .ok-help:hover, #${ROOT_ID} .ok-help.active {
            color: #fff; border-color: #61d5ff; background: color-mix(in srgb, #61d5ff 16%, transparent);
        }
        #${ROOT_ID} .ok-help-popover {
            position: absolute; right: 0; bottom: 32px; width: 224px; display: none;
            padding: 10px; border-radius: var(--radius-sm); border: 1px solid var(--border-muted);
            background: var(--background-base-low); box-shadow: var(--shadow-button-overlay);
            color: var(--text-default); font-size: 10px; line-height: 1.45; z-index: 5;
        }
        #${ROOT_ID} .ok-help-wrap:hover .ok-help-popover,
        #${ROOT_ID} .ok-help-wrap.open .ok-help-popover { display: block; }
        #${ROOT_ID} .ok-help-title { font-size: 11px; font-weight: 800; color: #61d5ff; margin-bottom: 5px; }
        #${ROOT_ID} .ok-help-line { display: flex; justify-content: space-between; gap: 10px; margin: 3px 0; }
        #${ROOT_ID} .ok-help-key {
            white-space: nowrap; border: 1px solid var(--border-muted); border-radius: 4px;
            padding: 1px 5px; background: var(--background-mod-muted); font: 700 9px Consolas, monospace;
        }
        #${ROOT_ID} .ok-confirm-backdrop {
            position: absolute; inset: 0; z-index: 20; display: flex; align-items: center; justify-content: center;
            padding: 18px; background: rgb(0 0 0 / 58%); backdrop-filter: blur(2px);
        }
        #${ROOT_ID} .ok-confirm {
            width: 100%; max-width: 330px; padding: 14px; border-radius: 10px;
            background: var(--background-base-low); border: 1px solid var(--border-muted);
            box-shadow: var(--shadow-button-overlay);
        }
        #${ROOT_ID} .ok-confirm-title { color: #ff6b70; font-size: 14px; font-weight: 850; margin-bottom: 7px; }
        #${ROOT_ID} .ok-confirm-text { color: var(--text-muted); font-size: 10px; line-height: 1.45; margin-bottom: 10px; }
        #${ROOT_ID} .ok-confirm-check {
            display: flex; align-items: center; gap: 8px; padding: 8px; border-radius: 7px;
            background: var(--background-mod-muted); color: var(--text-default); font-size: 10px;
        }
        #${ROOT_ID} .ok-confirm-check input { accent-color: #5865F2; }
        #${ROOT_ID} .ok-confirm-note { margin-top: 7px; color: var(--text-muted); font-size: 9px; line-height: 1.35; }
        #${ROOT_ID} .ok-confirm-actions { display: flex; gap: 8px; margin-top: 12px; }
        #${ROOT_ID} .ok-confirm-actions button {
            flex: 1; padding: 7px 8px; border-radius: 7px; cursor: pointer;
            border: 1px solid var(--border-muted); background: var(--control-secondary-background-default);
            color: var(--text-default); font: 750 10px var(--font-primary);
        }
        #${ROOT_ID} .ok-confirm-actions .confirm-uninstall {
            color: #fff; border-color: #b7252f; background: #8f1820;
        }
        #${ROOT_ID} .ok-confirm-actions .confirm-uninstall:hover { background: #a61922; }
        #${ROOT_ID} ::-webkit-scrollbar { width: 5px; }
        #${ROOT_ID} .ok-options::-webkit-scrollbar { width: 6px; }
        #${ROOT_ID} .ok-options::-webkit-scrollbar-track { background: transparent; }
        #${ROOT_ID} ::-webkit-scrollbar-thumb {
            background: var(--scrollbar-auto-scrollbar-color-thumb); border-radius: 4px;
        }
        #${NATIVE_QUEST_STATUS_ID} {
            display: inline-flex; align-items: center; justify-content: center; gap: 3px;
            margin-left: 7px; min-width: 9px; height: 12px; vertical-align: middle;
            pointer-events: none;
        }
        #${NATIVE_QUEST_STATUS_ID} .audisk-idle-dot {
            width: 7px; height: 7px; border-radius: 50%; background: #43b581;
            box-shadow: 0 0 0 2px color-mix(in srgb, #43b581 18%, transparent);
        }
        @keyframes audiskQuestDotPulse {
            0%   { opacity: .30; transform: scale(.94); }
            18%  { opacity: .48; transform: scale(.97); }
            36%  { opacity: 1;   transform: scale(1.02); }
            56%  { opacity: .76; transform: scale(1); }
            76%  { opacity: .46; transform: scale(.97); }
            100% { opacity: .30; transform: scale(.94); }
        }
        #${NATIVE_QUEST_STATUS_ID} .audisk-run-dot {
            width: 5px; height: 5px; border-radius: 50%; background: #61d5ff;
            opacity: .30;
            animation: audiskQuestDotPulse 2.10s cubic-bezier(.45, 0, .55, 1) infinite;
            box-shadow: 0 0 5px color-mix(in srgb, #61d5ff 42%, transparent);
            will-change: opacity, transform;
        }
        #${NATIVE_QUEST_STATUS_ID} .audisk-run-dot:nth-child(2) { animation-delay: .48s; }
        #${NATIVE_QUEST_STATUS_ID} .audisk-run-dot:nth-child(3) { animation-delay: .96s; }
    `;
    document.head.appendChild(style);
    return style;
}

export function mountFloatingDashboard(controls: FloatingDashboardControls): () => void {
    document.getElementById(ROOT_ID)?.remove();
    const style = installStyle();
    const root = el("div");
    root.id = ROOT_ID;

    const head = el("div", "ok-head");
    const title = el("div", "ok-title");
    title.append(
        el("span", "ok-bolt", "ϟ"),
        el("span", "", "Audisk"),
        el("span", "ok-owner", "by Kiraa"),
        el("span", "ok-version", controls.version),
    );

    const controlsBox = el("div", "ok-controls");
    const statusDot = el("span", "ok-status-dot good");
    statusDot.title = "Audisk status: normal";
    const startStopButton = el("button", "ok-action start", "START");
    const pauseResumeButton = el("button", "ok-action pause", "PAUSE");
    const hideButton = el("button", "ok-link-btn", "HIDE");
    const gearButton = el("button", "ok-link-btn", "⚙");
    gearButton.title = "Options";

    const options = el("div", "ok-options");
    const refreshStatusButton = el("button", "", "Refresh status");
    const stopEngineButton = el("button", "danger", "Stop engine");
    const uninstallButton = el("button", "uninstall", "Uninstall");
    const settingsTitle = el("div", "ok-options-title", "Audisk settings");
    const settingNodes = new Map<string, HTMLInputElement | HTMLSelectElement>();

    const makeSettingCopy = (label: string, hint: string) => {
        const copy = el("div", "ok-setting-copy");
        copy.append(el("div", "ok-setting-label", label), el("div", "ok-setting-hint", hint));
        return copy;
    };

    for (const def of BOOLEAN_SETTINGS) {
        const row = el("div", "ok-setting-row");
        const checkbox = el("input", "ok-setting-check") as HTMLInputElement;
        checkbox.type = "checkbox";
        checkbox.title = def.hint;
        checkbox.onchange = event => {
            event.stopPropagation();
            (settings.store as any)[def.key] = checkbox.checked;
        };
        checkbox.onclick = event => event.stopPropagation();
        settingNodes.set(def.key, checkbox);
        row.append(makeSettingCopy(def.label, def.hint), checkbox);
        options.append(row);
    }

    for (const def of NUMBER_SETTINGS) {
        const row = el("div", "ok-setting-row");
        const select = el("select", "ok-setting-select") as HTMLSelectElement;
        for (const value of def.values) {
            const option = document.createElement("option");
            option.value = String(value);
            option.textContent = `${value}${def.suffix ?? ""}`;
            select.appendChild(option);
        }
        select.title = def.hint;
        select.onchange = event => {
            event.stopPropagation();
            (settings.store as any)[def.key] = Number(select.value);
        };
        select.onclick = event => event.stopPropagation();
        settingNodes.set(def.key, select);
        row.append(makeSettingCopy(def.label, def.hint), select);
        options.append(row);
    }

    options.prepend(refreshStatusButton, settingsTitle);
    options.append(stopEngineButton, uninstallButton);

    controlsBox.append(statusDot, startStopButton, pauseResumeButton, hideButton, gearButton, options);
    head.append(title, controlsBox);

    const body = el("div", "ok-body");
    const logs = el("div", "ok-logs");
    const footer = el("div", "ok-footer");
    const discordProfileButton = el("button", "ok-discord-profile");
    discordProfileButton.type = "button";
    discordProfileButton.title = "Open Kiraa's Discord profile";
    discordProfileButton.append(discordIcon(), el("span", "", OWNER_USERNAME));
    const helpWrap = el("div", "ok-help-wrap");
    const helpButton = el("button", "ok-help", "?");
    helpButton.type = "button";
    helpButton.title = "Audisk hotkeys";
    const helpPopover = el("div", "ok-help-popover");
    helpPopover.append(
        el("div", "ok-help-title", "Audisk hotkeys"),
        (() => { const row = el("div", "ok-help-line"); row.append(el("span", "", "Show / hide"), el("span", "ok-help-key", "Shift + .")); return row; })(),
        (() => { const row = el("div", "ok-help-line"); row.append(el("span", "", "Start / stop"), el("span", "ok-help-key", "Ctrl + Shift + S")); return row; })(),
        (() => { const row = el("div", "ok-help-line"); row.append(el("span", "", "Pause / resume"), el("span", "ok-help-key", "Ctrl + Shift + P")); return row; })(),
        el("div", "ok-setting-hint", "Click ? to pin this help. Click again to close."),
    );
    helpWrap.append(helpButton, helpPopover);
    footer.append(discordProfileButton, helpWrap);
    root.append(head, body, logs, footer);
    document.body.appendChild(root);

    let disposed = false;
    let busy = false;
    let hidden = false;
    let health: "good" | "warn" | "bad" = "good";
    let questStatusFrame = 0;

    const syncSettingControls = () => {
        for (const def of BOOLEAN_SETTINGS) {
            const node = settingNodes.get(def.key) as HTMLInputElement | undefined;
            if (!node) continue;
            const on = Boolean((settings.store as any)[def.key]);
            node.checked = on;
        }
        for (const def of NUMBER_SETTINGS) {
            const node = settingNodes.get(def.key) as HTMLSelectElement | undefined;
            if (!node) continue;
            node.value = String((settings.store as any)[def.key]);
        }
    };

    const findQuestNavHost = (): HTMLElement | null => {
        const selectors = [
            'a[href="/quest-home"]',
            'a[href^="/quest-home?"]',
            'a[href="/quests"]',
            'a[href^="/quests?"]',
            '[data-list-item-id*="quest" i]',
        ];
        for (const selector of selectors) {
            const found = document.querySelector<HTMLElement>(selector);
            if (found && !found.closest(`#${ROOT_ID}`)) return found;
        }

        const labels = new Set(["quests", "nhiệm vụ", "nhiem vu"]);
        for (const node of document.querySelectorAll<HTMLElement>('a, button, [role="listitem"], [role="link"]')) {
            if (node.closest(`#${ROOT_ID}`)) continue;
            const text = node.textContent?.trim().toLocaleLowerCase() ?? "";
            if (labels.has(text)) return node;
        }
        return null;
    };

    const updateNativeQuestStatus = () => {
        if (disposed) return;
        let badge = document.getElementById(NATIVE_QUEST_STATUS_ID);
        if (!badge) {
            const host = findQuestNavHost();
            if (!host) return;
            badge = el("span");
            badge.id = NATIVE_QUEST_STATUS_ID;
            host.appendChild(badge);
        }

        const activelyRunning = isEngineRunning() && readDashboard().some(entry => entry.status === "RUNNING");
        const nextState = activelyRunning ? "running" : "idle";
        badge.setAttribute("aria-label", activelyRunning ? "Audisk is running a quest" : "Audisk is idle");
        badge.title = activelyRunning ? "Audisk: running" : "Audisk: idle";

        // Do not rebuild these children on every Discord DOM mutation. Recreating them
        // restarts their CSS animation every frame and makes the three-dot pulse look frozen.
        if (badge.dataset.audiskState === nextState) return;
        badge.dataset.audiskState = nextState;
        badge.replaceChildren();
        if (activelyRunning) {
            badge.append(el("span", "audisk-run-dot"), el("span", "audisk-run-dot"), el("span", "audisk-run-dot"));
        } else {
            badge.append(el("span", "audisk-idle-dot"));
        }
    };

    const scheduleQuestStatusUpdate = () => {
        if (questStatusFrame || disposed) return;
        questStatusFrame = requestAnimationFrame(() => {
            questStatusFrame = 0;
            updateNativeQuestStatus();
        });
    };

    const questNavObserver = new MutationObserver(scheduleQuestStatusUpdate);
    questNavObserver.observe(document.body, { childList: true, subtree: true });

    const onSettingsChanged = () => syncSettingControls();
    SettingsStore.addPrefixChangeListener("plugins.Audisk", onSettingsChanged);
    syncSettingControls();

    const setHealth = (next: "good" | "warn" | "bad", message: string) => {
        health = next;
        statusDot.className = `ok-status-dot ${next}`;
        statusDot.title = message;
    };

    const log = (message: string, level: CompanionEventLevel | "info" = "info") => {
        if (disposed) return;
        const row = el("div", `ok-log ${level}`);
        const time = el("span", "ok-time", new Date().toLocaleTimeString());
        const messageNode = el("span", "", message);
        row.append(time, messageNode);
        logs.appendChild(row);
        while (logs.childElementCount > MAX_LOGS) logs.firstElementChild?.remove();
        logs.scrollTop = logs.scrollHeight;
    };

    const render = () => {
        if (disposed) return;
        const running = isEngineRunning();
        const entries = sortEntries(readDashboard());
        scheduleQuestStatusUpdate();
        body.replaceChildren();

        if (entries.length === 0) {
            body.appendChild(el(
                "div",
                "ok-empty",
                running
                    ? "Waiting for tasks..."
                    : "Ready. Press START or use /audisk start.",
            ));
        } else {
            for (const entry of entries) {
                const value = pct(entry);
                const card = el("div", `ok-card ${stateClass(entry.status)}`);

                const icon = el("div", "ok-icon");
                icon.style.setProperty("--p", `${value}%`);
                icon.append(el("div", "ok-icon-inner", iconFor(entry)));
                if (entry.status === "RUNNING") {
                    icon.append(el("div", "ok-icon-overlay", `${Math.floor(value)}%`));
                }

                const quest = el("div", "ok-quest");
                quest.append(
                    el("div", "ok-status", entry.status),
                    el("div", "ok-quest-name", entry.name),
                );

                const unit = entry.type === "ACHIEVEMENT" ? "" : "s";
                const metaLabel =
                    entry.status === "QUEUE" || entry.status === "PENDING" ? "In Queue" :
                    entry.status === "PAUSED" ? "Paused" :
                    entry.status === "FAILED" ? "Aborted" :
                    "Progress";
                const progress = entry.max > 0
                    ? `${Math.min(Math.floor(entry.cur), entry.max)} / ${entry.max}${unit}`
                    : String(entry.type);
                const meta = el("div", "ok-meta");
                meta.append(el("span", "", metaLabel), el("span", "", progress));
                quest.append(meta);

                if (entry.reason) {
                    quest.append(el("div", "ok-reason", entry.reason));
                }
                card.append(icon, quest);
                body.appendChild(card);
            }
        }

        const hasActive = entries.some(e => e.status === "RUNNING" || e.status === "QUEUE");
        const hasPaused = entries.some(e => e.status === "PAUSED");

        const startStopLabel = running ? "STOP" : "START";
        const startStopAction = running ? controls.stop : controls.start;
        startStopButton.textContent = startStopLabel;
        startStopButton.className = `ok-action ${running ? "stop" : "start"}`;
        startStopButton.disabled = busy;
        startStopButton.onclick = () => void runControl(startStopLabel, startStopAction);

        const resumeMode = running && hasPaused && !hasActive;
        const pauseResumeLabel = resumeMode ? "RESUME" : "PAUSE";
        const pauseResumeAction = resumeMode ? controls.resumeAll : controls.pauseAll;
        pauseResumeButton.textContent = pauseResumeLabel;
        pauseResumeButton.className = `ok-action ${resumeMode ? "resume" : "pause"}`;
        pauseResumeButton.disabled = busy || !running || (!hasActive && !hasPaused);
        pauseResumeButton.onclick = () => void runControl(pauseResumeLabel, pauseResumeAction);

        if (entries.some(e => e.status === "FAILED")) {
            setHealth("bad", "Audisk status: one or more tasks failed");
        }
    };

    const runControl = async (label: string, fn: () => Promise<string>) => {
        if (busy || disposed) return;
        busy = true;
        render();
        log(`${label} requested...`);
        try {
            const result = await fn();
            log(result, "success");
            if (!readDashboard().some(e => e.status === "FAILED")) {
                setHealth("good", "Audisk status: normal");
            }
        } catch (error) {
            const message = error instanceof Error ? error.message : String(error);
            setHealth("bad", `Audisk error: ${message}`);
            log(message, "error");
        } finally {
            busy = false;
            render();
        }
    };

    const showUninstallConfirm = async () => {
        if (busy || disposed || root.querySelector(".ok-confirm-backdrop")) return;
        options.classList.remove("open");

        let info: Awaited<ReturnType<typeof Native.getInstallInfo>>;
        try {
            info = await Native.getInstallInfo();
        } catch (error) {
            log(`Could not read install state: ${error instanceof Error ? error.message : String(error)}`, "error");
            return;
        }
        if (!info.available) {
            log("Audisk uninstall helper is not installed. Re-run INSTALL.cmd once to install it.", "error");
            return;
        }

        const backdrop = el("div", "ok-confirm-backdrop");
        const modal = el("div", "ok-confirm");
        const checkbox = document.createElement("input");
        checkbox.type = "checkbox";
        checkbox.checked = info.defaultRemoveVencord;
        const checkLabel = el("label", "ok-confirm-check");
        checkLabel.append(checkbox, el("span", "", "Uninstall Vencord too"));

        const stateNote = info.hadVencordBefore === true
            ? "Vencord existed before Audisk, so this is off by default. Leaving it off restores the previous Vencord setup."
            : info.hadVencordBefore === false
                ? "Audisk installed Vencord for this setup, so this is on by default. Turn it off to keep plain Vencord after removing Audisk."
                : "Original Vencord state is unknown, so this stays off by default to avoid removing more than requested.";

        const actions = el("div", "ok-confirm-actions");
        const cancel = el("button", "", "Cancel");
        const confirm = el("button", "confirm-uninstall", "Uninstall");
        actions.append(cancel, confirm);
        modal.append(
            el("div", "ok-confirm-title", "Uninstall Audisk?"),
            el("div", "ok-confirm-text", "Audisk will stop Discord, remove the plugin, and restore the client according to the option below."),
            checkLabel,
            el("div", "ok-confirm-note", stateNote),
            actions,
        );
        backdrop.appendChild(modal);
        root.appendChild(backdrop);

        const close = () => backdrop.remove();
        cancel.onclick = close;
        backdrop.onclick = event => { if (event.target === backdrop) close(); };
        confirm.onclick = () => void (async () => {
            confirm.disabled = true;
            cancel.disabled = true;
            try {
                const result = await Native.uninstallAudisk(checkbox.checked);
                if (!result.started) {
                    log(`Uninstall could not start: ${result.error ?? "unknown error"}`, "error");
                    confirm.disabled = false;
                    cancel.disabled = false;
                    return;
                }
                log("Uninstall started. Discord will close while the installed state is restored.", "warning");
                confirm.textContent = "Starting...";
            } catch (error) {
                log(`Uninstall failed to start: ${error instanceof Error ? error.message : String(error)}`, "error");
                confirm.disabled = false;
                cancel.disabled = false;
            }
        })();
    };

    refreshStatusButton.onclick = () => void runControl("Status", controls.status);
    stopEngineButton.onclick = () => void runControl("Stop", controls.stop);
    uninstallButton.onclick = () => void showUninstallConfirm();
    discordProfileButton.onclick = () => {
        void (async () => {
            try {
                await UserUtils.getUser(OWNER_USER_ID);
                openUserProfileModal({
                    userId: OWNER_USER_ID,
                    guildId: SelectedGuildStore.getGuildId(),
                    channelId: SelectedChannelStore.getChannelId(),
                    sourceAnalyticsLocations: ["username", "user profile popout"],
                });
            } catch (error) {
                const message = error instanceof Error ? error.message : String(error);
                log(`Could not open ${OWNER_USERNAME}'s Discord profile: ${message}`, "error");
            }
        })();
    };
    gearButton.onclick = event => {
        event.stopPropagation();
        options.classList.toggle("open");
    };
    helpButton.onclick = event => {
        event.stopPropagation();
        const open = helpWrap.classList.toggle("open");
        helpButton.classList.toggle("active", open);
    };

    const onDocumentClick = (event: MouseEvent) => {
        if (!options.contains(event.target as Node)) options.classList.remove("open");
        if (!helpWrap.contains(event.target as Node)) {
            helpWrap.classList.remove("open");
            helpButton.classList.remove("active");
        }
    };
    document.addEventListener("click", onDocumentClick);

    const toggle = () => {
        hidden = !hidden;
        root.style.display = hidden ? "none" : "flex";
    };
    hideButton.onclick = toggle;
    const onKeyDown = (event: KeyboardEvent) => {
        if (event.repeat) return;

        const exactControlHotkey = event.ctrlKey && event.shiftKey && !event.altKey && !event.metaKey;
        if (exactControlHotkey && event.code === "KeyS") {
            event.preventDefault();
            event.stopPropagation();
            const running = isEngineRunning();
            void runControl(running ? "STOP" : "START", running ? controls.stop : controls.start);
            return;
        }
        if (exactControlHotkey && event.code === "KeyP") {
            event.preventDefault();
            event.stopPropagation();
            const entries = readDashboard();
            const hasActive = entries.some(e => e.status === "RUNNING" || e.status === "QUEUE");
            const hasPaused = entries.some(e => e.status === "PAUSED");
            const resume = isEngineRunning() && hasPaused && !hasActive;
            if (isEngineRunning() && (hasActive || hasPaused)) {
                void runControl(resume ? "RESUME" : "PAUSE", resume ? controls.resumeAll : controls.pauseAll);
            }
            return;
        }

        const isShiftPeriod =
            event.key === ">" ||
            (
                event.shiftKey &&
                (
                    event.code === "Period" ||
                    event.key === "."
                )
            );

        if (isShiftPeriod) toggle();
    };
    // Capture phase makes the hotkey reliable even when Discord's chat/editor
    // intercepts keydown during normal bubbling.
    window.addEventListener("keydown", onKeyDown, true);

    let dragCleanup: (() => void) | null = null;
    const onMouseDown = (event: MouseEvent) => {
        if ((event.target as HTMLElement | null)?.closest("button, .ok-status-dot")) return;
        head.classList.add("dragging");
        const rect = root.getBoundingClientRect();
        const startX = event.clientX;
        const startY = event.clientY;
        root.style.left = `${rect.left}px`;
        root.style.top = `${rect.top}px`;
        root.style.right = "auto";

        const move = (next: MouseEvent) => {
            const left = Math.max(0, Math.min(rect.left + next.clientX - startX, window.innerWidth - root.offsetWidth));
            const top = Math.max(0, Math.min(rect.top + next.clientY - startY, window.innerHeight - 48));
            root.style.left = `${left}px`;
            root.style.top = `${top}px`;
        };
        const up = () => {
            head.classList.remove("dragging");
            document.removeEventListener("mousemove", move);
            document.removeEventListener("mouseup", up);
            dragCleanup = null;
        };
        dragCleanup = up;
        document.addEventListener("mousemove", move);
        document.addEventListener("mouseup", up);
        event.preventDefault();
    };
    head.addEventListener("mousedown", onMouseDown);

    const unsubscribeDashboard = subscribeDashboard(render);
    const unsubscribeEvents = subscribeCompanionEvents(event => {
        if (event.level === "error") {
            setHealth("bad", event.message);
        } else if (event.level === "warning" && health !== "bad") {
            setHealth("warn", event.message);
        } else if ((event.level === "success" || event.level === "info") && health !== "bad") {
            setHealth("good", event.message);
        }
        log(event.message, event.level);
        render();
    });

    log("Audisk dashboard loaded.", "success");
    setHealth("good", "Audisk status: normal");
    render();

    return () => {
        if (disposed) return;
        disposed = true;
        unsubscribeDashboard();
        unsubscribeEvents();
        questNavObserver.disconnect();
        if (questStatusFrame) cancelAnimationFrame(questStatusFrame);
        document.getElementById(NATIVE_QUEST_STATUS_ID)?.remove();
        SettingsStore.removePrefixChangeListener("plugins.Audisk", onSettingsChanged);
        dragCleanup?.();
        document.removeEventListener("click", onDocumentClick);
        window.removeEventListener("keydown", onKeyDown, true);
        head.removeEventListener("mousedown", onMouseDown);
        root.remove();
        style.remove();
    };
}
