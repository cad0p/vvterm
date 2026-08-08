//
//  Ghostty.LayerTeardown.swift
//  VVTerm
//
//  Ordered teardown steps for ghostty-hosted terminal views (issue #116).
//
//  `ghostty_surface_free` joins the surface's renderer thread. At thread
//  exit CA commits whatever transaction the renderer left pending, and
//  because the renderer's IOSurfaceLayer is a sublayer of the host view's
//  layer, geometry mutations during the final pass mark the host layer for
//  layout. The layout phase of that commit then runs `layoutSubviews` on
//  the renderer thread; when the host view participates in Auto Layout the
//  NSIS engine aborts the process (_AssertAutoLayoutOnAllowedThreadsOnly).
//
//  Detaching the renderer layer orphans it: its final commit can no longer
//  reach the host view's layer or its constraints. Settling pending layout
//  on the main thread clears any layout the host view still owes.
//

import QuartzCore

extension Ghostty {
    enum LayerTeardown {
        /// Detaches renderer-owned sublayers from `hostLayer` and settles
        /// pending layout on the caller's (main) thread. Must run before
        /// `ghostty_surface_free` so the renderer thread's exit-time CA
        /// transaction cannot reach the host view's Auto Layout constraints.
        @MainActor
        static func prepare(
            hostLayer: CALayer,
            isRendererLayer: (CALayer) -> Bool
        ) {
            for sublayer in hostLayer.sublayers ?? [] where isRendererLayer(sublayer) {
                sublayer.removeFromSuperlayer()
            }
            hostLayer.layoutIfNeeded()
        }
    }
}
