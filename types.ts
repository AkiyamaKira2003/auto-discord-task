/*
 * Audisk, a Vencord userplugin
 * Audistask Copyright (c) 2026 Kiraa (AkiyamaKira2003)
 * SPDX-License-Identifier: MIT
 *
 * Shared types. Discord's internal Flux store shapes are loose by
 * nature, so we describe only the fields we touch.
 */

export interface Quest {
    id: string;
    config?: {
        expiresAt?: string;
        application?: { id?: string; };
        messages?: { questName?: string; };
        taskConfig?: TaskConfig;
        taskConfigV2?: TaskConfig;
        rewardsConfig?: {
            rewards?: Array<{
                type?: number;
                messages?: { name?: string; };
                /** Orb payout. Discord sends orb_quantity; the store hands it over camel-cased. */
                orbQuantity?: number | null;
                /** The same payout for Nitro subscribers, absent on quests that pay the same. */
                premiumOrbQuantity?: number | null;
            }>;
        };
    };
    userStatus?: {
        completedAt?: string;
        dismissedAt?: string;
        enrolledAt?: string;
        progress?: Record<string, { value?: number; }>;
        streamProgressSeconds?: number;
    };
}

export interface TaskConfig {
    // taskConfigV2 moved the application off the quest config and onto each task
    tasks: Record<string, { target?: number; applications?: Array<{ id?: string; }>; }>;
}

export type TaskType = "GAME" | "STREAM" | "WATCH_VIDEO" | "ACTIVITY" | "ACHIEVEMENT";

export interface DetectedTask {
    type: TaskType;
    keyName: string;
    target: number;
    /** From tasks[key].applications[0].id (taskConfigV2) or the legacy config.application.id. */
    appId: string | null;
}

export interface TaskInfo {
    id: string;
    appId: string | number;
    name: string;
    target: number;
    type: TaskType;
    keyName: string;
}

export interface Stores {
    QuestStore: any;
    RunStore: any;
    StreamStore: any;
    ChanStore: any;
    GuildChanStore: any;
    /** Needed for the owner component of a stream key, which is the current user's id. */
    UserStore: any;
    Dispatcher: any;
    API: any;
}

export interface FakeGame {
    id: string | number;
    name: string;
    icon?: string;
    pid: number;
    pidPath: number[];
    processName: string;
    start: number;
    exeName: string;
    exePath: string;
    cmdLine: string;
    executables: Array<{ os: string; name: string; is_launcher: boolean; }>;
    windowHandle: number;
    fullscreenType: number;
    overlay: boolean;
    sandboxed: boolean;
    hidden: boolean;
    isLauncher: boolean;
}

/** Terminal outcome of one quest in one run. */
export type QuestOutcome = "completed" | "blocked" | "failed" | "left_out";

/** Counts and wrap-up wording for a run with nothing left to do. */
export interface RunSummary {
    finished: number;
    blocked: number;
    failed: number;
    leftOut: number;
    line: string;
    playDone: boolean;
}

export interface AudiskRuntime {
    running: boolean;
    cleanups: Set<() => void>;
    skipped: Set<string>;
    /**
     * What actually happened to each quest this run, written where the run decides it.
     * The wrap-up used to reconstruct this from completedAt, which cannot tell Audisk's
     * work from the user finishing the same quest by hand.
     */
    outcomes: Map<string, QuestOutcome>;
}
