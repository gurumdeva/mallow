// KeepOnTop — the View ▸ Keep on Top toggle (Controller wiring). Pins THIS window above other apps
// by raising its window.level to .floating, and drops it back to .normal when turned off. Per-window
// and transient: the state lives on the view-model and resets to off each launch (no persistence),
// mirroring the Tauri reference's `win.setAlwaysOnTop(on)` (main.ts → applyKeepOnTop).
//
// MVVM: the on/off flag is owned by EditorViewModel (see sharedChanges); this file only forwards the
// menu action and reflects the checkmark — the same split as toggleFocusMode(_:).

import AppKit

extension EditorController {
    /// View ▸ Keep on Top — flip the flag, float/unfloat this window, and tick the menu item. Because
    /// the menu bar is app-global (one bar for every window), the sender's checkmark is set from THIS
    /// window's flag here, and corrected in validateMenuItem(_:) when the menu reopens on another.
    @objc func toggleKeepOnTop(_ sender: Any?) {
        vm.keepOnTop.toggle()
        window?.level = vm.keepOnTop ? .floating : .normal
        (sender as? NSMenuItem)?.state = vm.keepOnTop ? .on : .off
    }
    // NOTE: the Keep-on-Top checkmark is kept honest for the key window in EditorController's merged
    // `validateMenuItem(_:)` (one validator per type — see EditorController.swift). KeepOnTop's branch
    // there sets `item.state = vm.keepOnTop ? .on : .off`.
}
