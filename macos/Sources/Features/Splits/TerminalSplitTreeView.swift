import SwiftUI

/// A single operation within the split tree.
///
/// Rather than binding the split tree (which is immutable), any mutable operations are
/// exposed via this enum to the embedder to handle.
enum TerminalSplitOperation {
    case resize(Resize)
    case drop(Drop)

    struct Resize {
        let node: SplitTree<Ghostty.SurfaceView>.Node
        let ratio: Double
    }

    struct Drop {
        /// The surface being dragged.
        let payload: Ghostty.SurfaceView

        /// The surface it was dragged onto
        let destination: Ghostty.SurfaceView

        /// The zone it was dropped to determine how to split the destination.
        let zone: TerminalSplitDropZone
    }
}

struct TerminalSplitTreeView: View {
    let tree: SplitTree<Ghostty.SurfaceView>
    let action: (TerminalSplitOperation) -> Void

    var body: some View {
        if let node = tree.zoomed ?? tree.root {
            TerminalSplitSubtreeView(
                node: node,
                isRoot: node == tree.root,
                action: action)
            // This is necessary because we can't rely on SwiftUI's implicit
            // structural identity to detect changes to this view. Due to
            // the tree structure of splits it could result in bad behaviors.
            // See: https://github.com/ghostty-org/ghostty/issues/7546
            .id(node.structuralIdentity)
        }
    }
}

private struct TerminalSplitSubtreeView: View {
    @EnvironmentObject var ghostty: Ghostty.App

    let node: SplitTree<Ghostty.SurfaceView>.Node
    var isRoot: Bool = false
    let action: (TerminalSplitOperation) -> Void

    var body: some View {
        switch node {
        case .leaf(let leafView):
            TerminalSplitLeaf(surfaceView: leafView, isSplit: !isRoot, action: action)

        case .split(let split):
            let splitViewDirection: SplitViewDirection = switch split.direction {
            case .horizontal: .horizontal
            case .vertical: .vertical
            }

            SplitView(
                splitViewDirection,
                .init(get: {
                    CGFloat(split.ratio)
                }, set: {
                    action(.resize(.init(node: node, ratio: $0)))
                }),
                dividerColor: ghostty.config.splitDividerColor,
                resizeIncrements: .init(width: 1, height: 1),
                left: {
                    TerminalSplitSubtreeView(node: split.left, action: action)
                },
                right: {
                    TerminalSplitSubtreeView(node: split.right, action: action)
                },
                onEqualize: {
                    guard let surface = node.leftmostLeaf().surface else { return }
                    ghostty.splitEqualize(surface: surface)
                }
            )
        }
    }
}

private struct TerminalSplitLeaf: View {
    let surfaceView: Ghostty.SurfaceView
    let isSplit: Bool
    let action: (TerminalSplitOperation) -> Void

    @State private var dropState: DropState = .idle
    @State private var isSelfDragging: Bool = false
    @State private var subtitleTruncated: Bool = false

    private var showsPaneTitlebar: Bool {
        isSplit && !UserDefaults.standard.bool(forKey: "SplitTitlebarDisabled")
    }

    var body: some View {
        GeometryReader { geometry in
            VStack(spacing: 0) {
                // Fork feature: an always-visible titlebar on each pane when the
                // window is split. Disable with:
                //   defaults write com.mitchellh.ghostty SplitTitlebarDisabled -bool true
                if showsPaneTitlebar {
                    SplitPaneTitlebar(surfaceView: surfaceView)
                }
                Ghostty.InspectableSurface(
                    surfaceView: surfaceView,
                    isSplit: isSplit)
            }
            .onPreferenceChange(SplitPaneSubtitleTruncatedKey.self) { value in
                subtitleTruncated = value
            }
            // The multi-line subtitle expansion is an overlay on the whole leaf
            // (not part of the titlebar's layout) so a long subtitle floats over
            // the terminal content instead of resizing the surface: the split
            // grid and the terminal's rows/cols never move because of it.
            .overlay(alignment: .top) {
                if showsPaneTitlebar {
                    SplitPaneSubtitleExpansion(
                        surfaceView: surfaceView,
                        truncated: subtitleTruncated)
                        .padding(.top, SplitPaneTitlebar.barHeight)
                }
            }
            .background {
                // If we're dragging ourself, we hide the entire drop zone. This makes
                // it so that a released drop animates back to its source properly
                // so it is a proper invalid drop zone.
                if !isSelfDragging {
                    Color.clear
                        .onDrop(of: [.ghosttySurfaceId], delegate: SplitDropDelegate(
                            dropState: $dropState,
                            viewSize: geometry.size,
                            destinationSurface: surfaceView,
                            action: action
                        ))
                }
            }
            .overlay {
                if !isSelfDragging, case .dropping(let zone) = dropState {
                    zone.overlay(in: geometry)
                        .allowsHitTesting(false)
                }
            }
            .onPreferenceChange(Ghostty.DraggingSurfaceKey.self) { value in
                isSelfDragging = value == surfaceView.id
                if isSelfDragging {
                    dropState = .idle
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Terminal pane")
        }
    }

    private enum DropState: Equatable {
        case idle
        case dropping(TerminalSplitDropZone)
    }

    private struct SplitDropDelegate: DropDelegate {
        @Binding var dropState: DropState
        let viewSize: CGSize
        let destinationSurface: Ghostty.SurfaceView
        let action: (TerminalSplitOperation) -> Void

        func validateDrop(info: DropInfo) -> Bool {
            info.hasItemsConforming(to: [.ghosttySurfaceId])
        }

        func dropEntered(info: DropInfo) {
            dropState = .dropping(.calculate(at: info.location, in: viewSize))
        }

        func dropUpdated(info: DropInfo) -> DropProposal? {
            // For some reason dropUpdated is sent after performDrop is called
            // and we don't want to reset our drop zone to show it so we have
            // to guard on the state here.
            guard case .dropping = dropState else { return DropProposal(operation: .forbidden) }
            dropState = .dropping(.calculate(at: info.location, in: viewSize))
            return DropProposal(operation: .move)
        }

        func dropExited(info: DropInfo) {
            dropState = .idle
        }

        func performDrop(info: DropInfo) -> Bool {
            let zone = TerminalSplitDropZone.calculate(at: info.location, in: viewSize)
            dropState = .idle

            // Load the dropped surface asynchronously using Transferable
            let providers = info.itemProviders(for: [.ghosttySurfaceId])
            guard let provider = providers.first else { return false }

            // Capture action before the async closure
            _ = provider.loadTransferable(type: Ghostty.SurfaceView.self) { [weak destinationSurface] result in
                switch result {
                case .success(let sourceSurface):
                    DispatchQueue.main.async {
                        // Don't allow dropping on self
                        guard let destinationSurface else { return }
                        guard sourceSurface !== destinationSurface else { return }
                        action(.drop(.init(payload: sourceSurface, destination: destinationSurface, zone: zone)))
                    }

                case .failure:
                    break
                }
            }

            return true
        }
    }
}

/// An always-visible compact titlebar shown above each pane in a split,
/// with the pane's title and a subtitle summarizing what the pane is doing.
///
/// The title is the surface title: a manually pinned name if one was set
/// (via prompt_surface_title or the AppleScript `name` property), otherwise
/// the terminal-reported title. The subtitle prefers the live
/// terminal-reported title masked by a manual name (the running command, or
/// the cwd via shell integration), falling back to the working directory.
private struct SplitPaneTitlebar: View {
    @ObservedObject var surfaceView: Ghostty.SurfaceView

    static let barHeight: CGFloat = 22
    static let textFont = Font.system(size: 11)

    var body: some View {
        HStack(spacing: 8) {
            Text(surfaceView.title)
                .font(Self.textFont.weight(.semibold))
                .lineLimit(1)
            if let subtitle = surfaceView.paneSubtitle {
                let firstLine = subtitle.paneSubtitleFirstLine
                Text(firstLine)
                    .font(Self.textFont)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.head)
                    // Measure whether the single inline line is truncated: the
                    // hidden copy takes its intrinsic width, the outer reader
                    // the width the HStack actually allocated. The result flows
                    // up (SplitPaneSubtitleTruncatedKey) to the leaf, which
                    // shows the floating multi-line expansion.
                    .background(
                        GeometryReader { allocated in
                            Text(firstLine)
                                .font(Self.textFont)
                                .lineLimit(1)
                                .fixedSize()
                                .hidden()
                                .background(
                                    GeometryReader { intrinsic in
                                        Color.clear.preference(
                                            key: SplitPaneSubtitleTruncatedKey.self,
                                            value: intrinsic.size.width > allocated.size.width + 0.5)
                                    }
                                )
                        }
                    )
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .frame(height: Self.barHeight)
        .frame(maxWidth: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
        .overlay(alignment: .bottom) {
            Divider()
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Pane title: \(surfaceView.title)")
    }
}

/// The floating continuation of the pane titlebar for subtitles that don't
/// fit on the single inline line (or contain explicit newlines). Rendered as
/// an overlay over the terminal content — never part of the layout — so the
/// split grid and the surface size are unaffected. Click-through, capped at
/// a few lines, styled as a drop-down extension of the titlebar.
private struct SplitPaneSubtitleExpansion: View {
    @ObservedObject var surfaceView: Ghostty.SurfaceView
    let truncated: Bool

    private static let maxLines = 4

    var body: some View {
        if let subtitle = surfaceView.paneSubtitle,
           truncated || subtitle.contains("\n") {
            Text(subtitle)
                .font(SplitPaneTitlebar.textFont)
                .foregroundStyle(.secondary)
                .lineLimit(Self.maxLines)
                .truncationMode(.tail)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Color(nsColor: .windowBackgroundColor))
                .overlay(alignment: .bottom) {
                    Divider()
                }
                .shadow(color: .black.opacity(0.15), radius: 3, y: 2)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
    }
}

/// True when a pane's inline subtitle line had to truncate; bubbles from the
/// titlebar up to the split leaf that owns the floating expansion overlay.
private struct SplitPaneSubtitleTruncatedKey: PreferenceKey {
    static var defaultValue: Bool = false
    static func reduce(value: inout Bool, nextValue: () -> Bool) {
        value = value || nextValue()
    }
}

fileprivate extension Ghostty.SurfaceView {
    /// The pane subtitle: a manual override if one was set (AppleScript
    /// `subtitle` property), else the live terminal-reported title masked by
    /// a manual name (running command / cwd), else the working directory.
    var paneSubtitle: String? {
        if let override = subtitleOverride, !override.isEmpty {
            return override
        }
        if let fromTerminal = titleFromTerminal,
           !fromTerminal.isEmpty,
           fromTerminal != title {
            return fromTerminal
        }
        guard let pwd, !pwd.isEmpty else { return nil }
        return (pwd as NSString).abbreviatingWithTildeInPath
    }
}

fileprivate extension String {
    /// First line of a (possibly multi-line) subtitle for the inline bar.
    var paneSubtitleFirstLine: String {
        guard let newline = firstIndex(of: "\n") else { return self }
        return String(self[..<newline])
    }
}

enum TerminalSplitDropZone: String, Equatable {
    case top
    case bottom
    case left
    case right

    /// Determines which drop zone the cursor is in based on proximity to edges.
    ///
    /// Divides the view into four triangular regions by drawing diagonals from
    /// corner to corner. The drop zone is determined by which edge the cursor
    /// is closest to, creating natural triangular hit regions for each side.
    static func calculate(at point: CGPoint, in size: CGSize) -> TerminalSplitDropZone {
        let relX = point.x / size.width
        let relY = point.y / size.height

        let distToLeft = relX
        let distToRight = 1 - relX
        let distToTop = relY
        let distToBottom = 1 - relY

        let minDist = min(distToLeft, distToRight, distToTop, distToBottom)

        if minDist == distToLeft { return .left }
        if minDist == distToRight { return .right }
        if minDist == distToTop { return .top }
        return .bottom
    }

    @ViewBuilder
    func overlay(in geometry: GeometryProxy) -> some View {
        let overlayColor = Color.accentColor.opacity(0.3)

        switch self {
        case .top:
            VStack(spacing: 0) {
                Rectangle()
                    .fill(overlayColor)
                    .frame(height: geometry.size.height / 2)
                Spacer()
            }
        case .bottom:
            VStack(spacing: 0) {
                Spacer()
                Rectangle()
                    .fill(overlayColor)
                    .frame(height: geometry.size.height / 2)
            }
        case .left:
            HStack(spacing: 0) {
                Rectangle()
                    .fill(overlayColor)
                    .frame(width: geometry.size.width / 2)
                Spacer()
            }
        case .right:
            HStack(spacing: 0) {
                Spacer()
                Rectangle()
                    .fill(overlayColor)
                    .frame(width: geometry.size.width / 2)
            }
        }
    }
}
