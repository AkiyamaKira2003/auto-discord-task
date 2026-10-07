/*
 * Audisk - Kiraa floating dashboard
 * SPDX-License-Identifier: MIT
 *
 * Vencord-native port of the standalone userscript's floating dashboard.
 * It never starts a second Audisk engine: every control delegates to the plugin lifecycle.
 */

import { openUserProfileModal, SelectedChannelStore, SelectedGuildStore, UserUtils } from "@webpack/common";

import {
    type DashboardEntry,
    isEngineRunning,
    readDashboard,
    subscribeDashboard,
} from "./audisk";
import { type CompanionEventLevel,subscribeCompanionEvents } from "./companionEvents";

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
            position: fixed; top: 32px; right: 20px; width: 380px; max-height: 53vh;
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
            position: absolute; right: 0; top: 28px; width: 170px; z-index: 4;
            display: none; padding: 8px; border-radius: var(--radius-sm);
            background: var(--background-base-low); border: 1px solid var(--border-muted);
            box-shadow: var(--shadow-button-overlay);
        }
        #${ROOT_ID} .ok-options.open { display: flex; flex-direction: column; gap: 6px; }
        #${ROOT_ID} .ok-options button {
            width: 100%; padding: 7px 8px; border-radius: var(--radius-sm);
            border: 1px solid var(--border-muted); background: var(--control-secondary-background-default);
            color: var(--text-default); cursor: pointer; font-size: 10px; font-weight: 700;
            font-family: inherit; text-align: left;
        }
        #${ROOT_ID} .ok-options .danger { color: var(--text-feedback-critical); }
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
            flex: 0 0 auto; display: flex; justify-content: flex-end; align-items: center;
            padding: 8px 12px; border-top: 1px solid var(--border-subtle);
            background: var(--background-base-low);
        }
        #${ROOT_ID} .ok-discord-profile {
            display: inline-flex; align-items: center; gap: 7px; cursor: pointer;
            border: 1px solid #5865F2; border-radius: 8px; padding: 6px 9px;
            color: #c9ceff; background: color-mix(in srgb, #5865F2 14%, transparent);
            font-family: inherit; font-size: 11px; font-weight: 700;
            transition: background .16s ease, color .16s ease, box-shadow .16s ease;
        }
        #${ROOT_ID} .ok-discord-profile:hover {
            color: #fff; background: color-mix(in srgb, #5865F2 28%, transparent);
            box-shadow: 0 0 0 2px color-mix(in srgb, #5865F2 18%, transparent);
        }
        #${ROOT_ID} .ok-discord-profile svg { flex: 0 0 auto; }
        #${ROOT_ID} ::-webkit-scrollbar { width: 4px; }
        #${ROOT_ID} ::-webkit-scrollbar-thumb {
            background: var(--scrollbar-auto-scrollbar-color-thumb); border-radius: 4px;
        }
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
    options.append(refreshStatusButton, stopEngineButton);

    controlsBox.append(statusDot, startStopButton, pauseResumeButton, hideButton, gearButton, options);
    head.append(title, controlsBox);

    const body = el("div", "ok-body");
    const logs = el("div", "ok-logs");
    const footer = el("div", "ok-footer");
    const discordProfileButton = el("button", "ok-discord-profile");
    discordProfileButton.type = "button";
    discordProfileButton.title = "Open Kiraa's Discord profile";
    discordProfileButton.append(discordIcon(), el("span", "", OWNER_USERNAME));
    footer.appendChild(discordProfileButton);
    root.append(head, body, logs, footer);
    document.body.appendChild(root);

    let disposed = false;
    let busy = false;
    let hidden = false;
    let health: "good" | "warn" | "bad" = "good";

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

    refreshStatusButton.onclick = () => void runControl("Status", controls.status);
    stopEngineButton.onclick = () => void runControl("Stop", controls.stop);
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

    const onDocumentClick = (event: MouseEvent) => {
        if (!options.contains(event.target as Node)) options.classList.remove("open");
    };
    document.addEventListener("click", onDocumentClick);

    const toggle = () => {
        hidden = !hidden;
        root.style.display = hidden ? "none" : "flex";
    };
    hideButton.onclick = toggle;
    const onKeyDown = (event: KeyboardEvent) => {
        if (event.repeat) return;

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
        dragCleanup?.();
        document.removeEventListener("click", onDocumentClick);
        window.removeEventListener("keydown", onKeyDown, true);
        head.removeEventListener("mousedown", onMouseDown);
        root.remove();
        style.remove();
    };
}
