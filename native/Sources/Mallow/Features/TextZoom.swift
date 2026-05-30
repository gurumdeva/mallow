// TextZoom — the View ▸ Zoom commands (⌘+ / ⌘− / ⌘0), Controller wiring. Scales THIS window's
// rendered text (body, inline marks, and heading sizes) by a per-window zoom factor, leaving the
// markdown source byte-for-byte untouched — zoom is pure presentation. Per-window and transient: the
// factor lives on the view-model and resets to 100% each launch (no persistence), mirroring the
// Tauri reference's `zoomHotkeysEnabled: true` (main.ts → WebKit ⌘+/⌘−/⌘0 page zoom).
//
// MVVM: the zoom factor + the size math are owned by EditorViewModel (see sharedChanges — restyle()
// and font(for:) multiply baseSize/heading sizes by vm.zoomFactor). This file only forwards the menu
// actions and re-renders, the same split as toggleFocusMode(_:) / toggleKeepOnTop(_:).

import AppKit

extension EditorController {
    /// Zoom bounds (matches the task spec: ~half … triple). Steps are multiplicative so each press
    /// feels even, like a browser's; the body's 16pt thus ranges 8 … 48pt.
    private static let zoomMin: CGFloat = 0.5
    private static let zoomMax: CGFloat = 3.0
    private static let zoomStep: CGFloat = 1.1   // +10% / −10% per keystroke

    /// View ▸ Zoom In (⌘+). Grow the text one step, clamped, then re-render this window.
    @objc func zoomIn(_ sender: Any?) {
        setZoom(vm.zoomFactor * Self.zoomStep)
    }

    /// View ▸ Zoom Out (⌘−). Shrink the text one step, clamped, then re-render this window.
    @objc func zoomOut(_ sender: Any?) {
        setZoom(vm.zoomFactor / Self.zoomStep)
    }

    /// View ▸ Actual Size (⌘0). Snap back to 100% and re-render this window.
    @objc func zoomReset(_ sender: Any?) {
        setZoom(1)
    }

    /// Clamp the factor into [zoomMin, zoomMax], store it on the view-model, and rebuild the styled
    /// text. refresh() re-runs the full parse → restyle → hide-syntax → focus pipeline, which now reads
    /// the new factor, so the whole document rescales at once. updateChrome() keeps the dirty dot honest
    /// (zoom never edits the buffer, so isDirty is unchanged — but we mirror the other action wiring).
    private func setZoom(_ factor: CGFloat) {
        let clamped = min(max(factor, Self.zoomMin), Self.zoomMax)
        guard clamped != vm.zoomFactor else { return }   // already at the rail — nothing to redraw
        vm.zoomFactor = clamped
        vm.refresh()
        updateChrome()
    }
}
