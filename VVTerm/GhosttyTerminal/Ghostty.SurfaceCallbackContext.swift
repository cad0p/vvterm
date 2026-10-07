// SPDX-License-Identifier: MIT
//
//  Ghostty.SurfaceCallbackContext.swift
//  VVTerm
//
//  Retained, lock-protected userdata for one ghostty surface (#310).
//
//  WHY THIS EXISTS. The surface's C callbacks receive the surface userdata:
//  `action`, `read_clipboard`, `close_surface` and the custom-IO write callback
//  can run on threads other than the main actor, and they can run after the
//  owning `GhosttyTerminalView` has been deallocated. A release path that never
//  calls `cleanup()` (closing a non-selected tab; application termination)
//  leaves the surface alive until `Ghostty.Surface.deinit`'s deferred
//  `ghostty_surface_free` drains on the main queue. When the userdata was the
//  view's own address, a callback in that window resolved the freed view with
//  `takeUnretainedValue()` and retained freed memory — the #310 CI crash
//  (`objc_retain ← closure #1 in static Ghostty.App.action(_:target:action:)`).
//
//  WHAT THIS IS. The userdata now points at this context instead of at the
//  view. The context is:
//
//    - created before `ghostty_surface_new` (the core emits `cell_size`,
//      `size_limit` and `set_title` from inside `Surface.init` — `Surface.zig`
//      :694,700,753-787 — so the context must already be installed as the
//      userdata when those callbacks arrive);
//    - retained by the view and by `Ghostty.Surface`, so it outlives every
//      callback the surface can invoke;
//    - invalidated under its lock before every `ghostty_surface_free` (the
//      synchronous `free()` path and the deferred `deinit` path), so a callback
//      that fires during the free resolves to nil instead of a dying view;
//    - captured by the deferred free block, so the raw userdata pointer stays
//      valid until the free has run;
//    - the owner of the #329 pending-clipboard-request registry: an in-flight
//      confirmation is registered under the lock, the completion claims
//      (removes) its own entry before completing, and every
//      `ghostty_surface_free` path drains what remains as the deny completion.
//      `invalidate()` never clears the registry: the deferred `deinit` drain
//      still owes each entry's release;
//    - thread-safe: the write callback runs on the termio IO thread,
//      `Ghostty.App.action` may run off the main actor, and the main actor
//      invalidates it, so every access goes through `OSAllocatedUnfairLock`.
//
//  The custom-IO `WriteFn` contract in `scripts/patches/ghostty/custom-io.patch`
//  states exactly this requirement: the userdata "must remain valid for the
//  lifetime of the surface … not freed while the callback may still be
//  invoked". This type is the implementation of that contract.
//
//  The registry (`Ghostty.App.activeSurfaces`) stays the preferred route for
//  resolving a live view; this context is the safe fallback that covers
//  pre-registration actions, wrapper-less surfaces and the dead-view window.

import Foundation
import os

extension Ghostty {
    /// Retained userdata for one ghostty surface (#310).
    ///
    /// Cross-thread by construction, so it must not be actor-isolated: the
    /// custom-IO write callback runs on the termio IO thread, `Ghostty.App.action`
    /// may run off the main actor, and the main actor invalidates the context
    /// before freeing the surface.
    nonisolated final class SurfaceCallbackContext: @unchecked Sendable {
        private struct State: @unchecked Sendable {
            /// The owning view, weak so the context can never keep it alive and
            /// `resolve()` turns into nil once the view deallocates.
            weak var view: GhosttyTerminalView?
            /// Set under the lock before `ghostty_surface_free`. Once false,
            /// `resolve()` returns nil for good (invalidation is one-way).
            var isValid = true
            /// #329: request states whose confirm callback has not completed
            /// yet, keyed by the core's request pointer, valued by the request
            /// kind. The teardown drain releases every remaining entry as a
            /// deny completion; the completion path claims its own entry so a
            /// later drain cannot re-complete an already-destroyed state.
            var pendingClipboardRequests: [UnsafeMutableRawPointer: ghostty_clipboard_request_e] = [:]
        }

        private let state = OSAllocatedUnfairLock(initialState: State())

        init(view: GhosttyTerminalView) {
            state.withLock { $0.view = view }
        }

        /// The opaque pointer stored in `surfaceConfig.userdata` and passed to
        /// the custom-IO write callback.
        ///
        /// The pointer is unretained: the context must be kept alive by its
        /// owners for as long as the surface can invoke a callback. That is the
        /// view's `callbackContext` property, `Ghostty.Surface.callbackContext`,
        /// and the deferred free block's capture.
        var userdata: UnsafeMutableRawPointer {
            Unmanaged.passUnretained(self).toOpaque()
        }

        /// Recover the context from a callback's userdata pointer.
        ///
        /// The caller must guarantee the context is alive for the call: the
        /// pointer is only ever stored where the surface (and therefore its
        /// owners) keeps the context alive.
        static func fromOpaque(_ userdata: UnsafeMutableRawPointer?) -> SurfaceCallbackContext? {
            guard let userdata else { return nil }
            return Unmanaged<SurfaceCallbackContext>.fromOpaque(userdata).takeUnretainedValue()
        }

        /// The live view, or nil when the view deallocated or the context was
        /// invalidated before the surface free.
        ///
        /// Callers must treat nil as "no view to deliver to" and return without
        /// side effects — never as an error to recover from.
        func resolve() -> GhosttyTerminalView? {
            state.withLock { state in
                guard state.isValid else { return nil }
                return state.view
            }
        }

        /// Suppress every future resolution. The synchronous `free()` path runs
        /// this on the main actor; the `deinit` path runs it on the deinit
        /// thread and defers only the drain + `ghostty_surface_free` to the
        /// main queue. Either way, a callback that fires during the free cannot
        /// reach a dying view.
        ///
        /// #329: this flips only `isValid` — the pending clipboard requests
        /// stay registered so `drainPendingClipboardRequests()` can still
        /// release them from the deferred `deinit` drain.
        func invalidate() {
            state.withLock { $0.isValid = false }
        }

        /// Registers one in-flight clipboard-confirmation request (#329).
        ///
        /// Returns false without registering when the context was already
        /// invalidated: a late registrant must not add an entry that no free
        /// path can drain. A false return therefore means "context invalidated;
        /// the request cannot be drained" — it is left to the window-(a)
        /// residual (#329). The validity check and the insertion share the
        /// lock's critical section.
        @discardableResult
        func registerPendingClipboardRequest(
            state requestState: UnsafeMutableRawPointer,
            kind: ghostty_clipboard_request_e
        ) -> Bool {
            self.state.withLock { state in
                guard state.isValid else { return false }
                state.pendingClipboardRequests[requestState] = kind
                return true
            }
        }

        /// Removes the entry and returns true iff it was still pending — the
        /// exactly-once claim the completion path performs before it hands the
        /// request state back to the core (#329).
        func claimPendingClipboardRequest(_ requestState: UnsafeMutableRawPointer) -> Bool {
            state.withLock { state in
                state.pendingClipboardRequests.removeValue(forKey: requestState) != nil
            }
        }

        /// Removes and returns every pending clipboard-confirmation request
        /// (#329). The surface teardown drain calls this immediately before
        /// `ghostty_surface_free` and releases each entry as a deny completion.
        ///
        /// MUST ignore `isValid`: the `deinit` path invalidates the context
        /// before its deferred drain runs, and the drain is exactly what makes
        /// that invalidated window safe. It is also why `invalidate()` must not
        /// clear the registry.
        func drainPendingClipboardRequests() -> [(state: UnsafeMutableRawPointer, kind: ghostty_clipboard_request_e)] {
            state.withLock { state in
                let pending = state.pendingClipboardRequests
                state.pendingClipboardRequests.removeAll()
                return pending.map { (state: $0.key, kind: $0.value) }
            }
        }
    }
}
