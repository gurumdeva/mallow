// ChromeBar — the SwiftUI custom titlebar overlay. Mallow hides/clears the native titlebar (transparent
// titlebar) and draws its own 52pt bar on top: a centered filename + ● modified dot, and the style /
// export / info corner buttons trailing-right. It is a PURE VISUAL component — it reads doc.title /
// doc.isDirty for display, and every action + popover-toggle is injected (bindings + closures) so the
// lead owns window access and anchors the `.popover`s to the buttons via `showStyle` / `showInfo`.

import SwiftUI

/// The 52pt titlebar overlay: centered filename + ● dot, and the style / export / info corner buttons on
/// the right. Stateless beyond the injected bindings — see the file header for the wiring contract.
struct ChromeBar: View {
    let doc: EditorDocument
    @Binding var showStyle: Bool      // toggled by the style (textformat) button
    @Binding var showInfo: Bool       // toggled by the info (info.circle) button
    var onExport: () -> Void          // export (arrow.down.doc) button
    var onRename: () -> Void          // tapping the filename

    /// Total bar height; matches the AppKit titlebar inset the window reserves. `static` so the editor's
    /// scroll view can inset its scroller by the same amount (the bar overlays the editor's top).
    static let barHeight: CGFloat = 52

    var body: some View {
        // GeometryReader gives us the bar's own width, so the centered name can be capped to a fraction
        // of it (matching the AppKit `widthAnchor … multiplier: 0.55`) and truncate before it reaches the
        // corner buttons — robust even in a narrow window on a wide display.
        GeometryReader { geo in
            ZStack {
                // Opaque backdrop — the dynamic Theme.bg token tracks light/dark with the editor.
                Theme.bg

                // CENTER: ● dot (only when dirty) + the filename button, centered in the bar.
                filenameCluster
                    .frame(maxWidth: geo.size.width * 0.55)
                    .frame(maxWidth: .infinity, alignment: .center)

                // RIGHT: the three corner buttons, trailing-inset, vertically centered. Its own
                // full-width row so it stays pinned to the trailing edge regardless of the centered name.
                HStack {
                    Spacer(minLength: 0)
                    cornerButtons
                }
                .padding(.trailing, 16)
            }
        }
        .frame(height: Self.barHeight)
        .frame(maxWidth: .infinity)
    }

    // MARK: - Center (dirty dot + filename)

    private var filenameCluster: some View {
        HStack(spacing: 4) {
            if doc.isDirty {
                Text("●")
                    .font(.system(size: 9))
                    .foregroundStyle(Theme.dim)
            }
            FilenameButton(title: doc.title, onRename: onRename)
        }
    }

    // MARK: - Right (corner buttons)

    private var cornerButtons: some View {
        HStack(spacing: 6) {
            // 1. Style menu — the Text-Style popover, anchored to this button.
            Button { showStyle.toggle() } label: {
                Image(systemName: "textformat")
                    .font(.system(size: 14, weight: .medium))
            }
            .buttonStyle(SquareButtonStyle.corner)
            .popover(isPresented: $showStyle, arrowEdge: .bottom) {
                StylePopover(doc: doc)
            }

            // 2. Export to PDF — injected action (window/save panel lives on the lead).
            Button { onExport() } label: {
                Image(systemName: "arrow.down.doc")
                    .font(.system(size: 14, weight: .medium))
            }
            .buttonStyle(SquareButtonStyle.corner)

            // 3. Document info — the Statistics / Contents popover, anchored to this button.
            Button { showInfo.toggle() } label: {
                Image(systemName: "info.circle")
                    .font(.system(size: 14, weight: .medium))
            }
            .buttonStyle(SquareButtonStyle.corner)
            .popover(isPresented: $showInfo, arrowEdge: .bottom) {
                DocumentInfoPopover(doc: doc)
            }
        }
    }
}

/// The centered filename as a plain button (CSS `.titlebar-center`): 13pt medium, Theme.dim at rest →
/// Theme.text on hover, with a subtle radius-7 Theme.elevated background on hover. `.plain` style + an
/// `.onHover` flag drive the hover look; tapping calls `onRename`. Truncates a long name with a tail
/// ellipsis so the bar stays robust at small widths.
private struct FilenameButton: View {
    let title: String
    let onRename: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: onRename) {
            Text(title)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(hovering ? Theme.text : Theme.dim)
                .lineLimit(1)
                .truncationMode(.tail)
                .padding(.vertical, 4)
                .padding(.horizontal, 8)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(hovering ? Theme.elevated : Color.clear)
                )
                .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
    }
}
