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

        /// Suppress every future resolution. Runs on the main actor before
        /// `ghostty_surface_free` on both free paths, so a callback that fires
        /// during the free cannot reach a dying view.
        func invalidate() {
            state.withLock { $0.isValid = false }
        }
    }
}
