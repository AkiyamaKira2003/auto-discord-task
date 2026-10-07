/*
 * Audisk, a Vencord userplugin
 * Audistask Copyright (c) 2026 Kiraa (AkiyamaKira2003)
 * SPDX-License-Identifier: MIT
 */

/**
 * A missing identity is an observation gap, not evidence that Discord switched accounts.
 * Only a different confirmed non-null id proves that account-owned runtime state is stale.
 */
export function isConfirmedDifferentAccount(currentUserId: string | null, expectedUserId: string): boolean {
    return currentUserId != null && currentUserId !== expectedUserId;
}
