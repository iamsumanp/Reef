//
//  CyclePanelView.swift
//  Reef
//
//  Window switcher panel UI
//

import SwiftUI

/// How the switcher lays out windows when previews are on.
enum SwitcherStyle: String, CaseIterable, Identifiable {
    /// Cards side by side, each a big picture with its title underneath. The default.
    case grid
    /// A list on the left, a big picture of the selected window on the right.
    case listWithPreview
    /// One list with larger pictures in every row, nothing beside it.
    case largeThumbnails
    /// A big picture of the selected window on top, small pictures in a strip below.
    case spotlight

    static let preferenceKey = "switcherStyle"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .listWithPreview: return "List + big preview"
        case .largeThumbnails: return "List with large pictures"
        case .grid: return "Grid of cards"
        case .spotlight: return "Big preview + strip"
        }
    }

    static var current: SwitcherStyle {
        UserDefaults.standard.string(forKey: preferenceKey).flatMap(SwitcherStyle.init) ?? .grid
    }
}

/// Sizes shared by the panel view and the controller that sizes its window.
struct CyclePanelLayout {
    static let headerHeight: CGFloat = 44
    static let dividerHeight: CGFloat = 1
    static let rowSpacing: CGFloat = 4
    static let listPadding: CGFloat = 8
    static let maxNonScrollingRows = 5

    // List + big preview
    static let rowThumbnailSize = CGSize(width: 80, height: 50)
    static let largePreviewSize = CGSize(width: 320, height: 200)
    static let previewPanePadding: CGFloat = 14
    static let previewCaptionHeight: CGFloat = 56

    // List with large pictures
    static let largeRowThumbnailSize = CGSize(width: 120, height: 75)

    // Grid of cards
    static let cardThumbnailSize = CGSize(width: 224, height: 140)
    static let cardPadding: CGFloat = 8
    /// Room for a title of up to two lines plus the detail line.
    static let cardCaptionHeight: CGFloat = 52
    static let cardSpacing: CGFloat = 10
    static let gridPadding: CGFloat = 14
    static let maxGridColumns = 4
    static let maxVisibleGridRows = 2

    // Big preview + strip
    static let spotlightSize = CGSize(width: 480, height: 300)
    static let spotlightCaptionHeight: CGFloat = 44
    static let stripThumbnailSize = CGSize(width: 112, height: 70)
    static let stripCellPadding: CGFloat = 6
    static let stripTitleHeight: CGFloat = 15
    static let stripSpacing: CGFloat = 8
    static let maxVisibleStripCells = 5

    /// The largest picture any style draws; previews are captured at this size.
    static let captureSize = spotlightSize

    let style: SwitcherStyle
    /// Windows get a second line (website, folder, screen); actions do not.
    let showsDetails: Bool
    let showsPreviews: Bool
    let itemCount: Int
    /// "Slack isn't open — press 3 again" instead of the window list.
    var showsLaunchPrompt = false
    /// The other-apps switcher's bottom line (filter, "give it a number" hint).
    var showsFooter = false

    static let footerHeight: CGFloat = 34

    static let launchPromptHeight: CGFloat = 118

    /// The style actually drawn: without previews every style falls back to the plain list.
    var effectiveStyle: SwitcherStyle? { showsPreviews ? style : nil }

    // MARK: Lists

    var rowHeight: CGFloat {
        switch effectiveStyle {
        case .listWithPreview: return 64
        case .largeThumbnails: return largeRowHeight
        default: return showsDetails ? 52 : 44
        }
    }

    private var largeRowHeight: CGFloat { Self.largeRowThumbnailSize.height + 12 }

    var listWidth: CGFloat {
        switch effectiveStyle {
        case .listWithPreview: return 420
        case .largeThumbnails: return 540
        default: return 400
        }
    }

    var listHeight: CGFloat {
        let rows = min(itemCount, Self.maxNonScrollingRows)
        return CGFloat(rows) * rowHeight
            + CGFloat(max(0, rows - 1)) * Self.rowSpacing
            + Self.listPadding * 2
    }

    var previewPaneWidth: CGFloat { Self.largePreviewSize.width + Self.previewPanePadding * 2 }

    var previewPaneHeight: CGFloat {
        Self.previewPanePadding * 2 + Self.largePreviewSize.height + 8 + Self.previewCaptionHeight
    }

    // MARK: Grid

    var cardSize: CGSize {
        CGSize(
            width: Self.cardThumbnailSize.width + Self.cardPadding * 2,
            height: Self.cardPadding * 2 + Self.cardThumbnailSize.height + 6 + Self.cardCaptionHeight
        )
    }

    var gridColumns: Int { max(1, min(itemCount, Self.maxGridColumns)) }

    var gridRows: Int { Int((Double(itemCount) / Double(gridColumns)).rounded(.up)) }

    var gridWidth: CGFloat {
        CGFloat(gridColumns) * cardSize.width
            + CGFloat(gridColumns - 1) * Self.cardSpacing
            + Self.gridPadding * 2
    }

    var gridVisibleHeight: CGFloat {
        let rows = min(gridRows, Self.maxVisibleGridRows)
        return CGFloat(rows) * cardSize.height
            + CGFloat(max(0, rows - 1)) * Self.cardSpacing
            + Self.gridPadding * 2
    }

    // MARK: Big preview + strip

    var stripCellSize: CGSize {
        CGSize(
            width: Self.stripThumbnailSize.width + Self.stripCellPadding * 2,
            height: Self.stripCellPadding * 2 + Self.stripThumbnailSize.height + 4 + Self.stripTitleHeight
        )
    }

    var stripVisibleWidth: CGFloat {
        let cells = min(itemCount, Self.maxVisibleStripCells)
        return CGFloat(cells) * stripCellSize.width + CGFloat(max(0, cells - 1)) * Self.stripSpacing
    }

    var spotlightInnerWidth: CGFloat { max(Self.spotlightSize.width, stripVisibleWidth) }

    // MARK: Panel

    var panelWidth: CGFloat {
        switch effectiveStyle {
        case .listWithPreview: return listWidth + Self.dividerHeight + previewPaneWidth
        case .largeThumbnails: return listWidth
        case .grid: return max(400, gridWidth)
        case .spotlight: return spotlightInnerWidth + Self.gridPadding * 2
        case nil: return listWidth
        }
    }

    var contentHeight: CGFloat {
        if showsLaunchPrompt {
            return Self.headerHeight + Self.dividerHeight + Self.launchPromptHeight
        }
        let body: CGFloat
        switch effectiveStyle {
        case .listWithPreview: body = max(listHeight, previewPaneHeight)
        case .largeThumbnails, nil: body = listHeight
        case .grid: body = gridVisibleHeight
        case .spotlight:
            body = Self.gridPadding + Self.spotlightSize.height + 8 + Self.spotlightCaptionHeight
                + 10 + stripCellSize.height + Self.gridPadding
        }
        return Self.headerHeight + Self.dividerHeight + body + (showsFooter ? Self.footerHeight : 0)
    }
}

struct CyclePanelView: View {
    @ObservedObject var state: CyclePanelState
    @AppStorage(SwitcherStyle.preferenceKey) private var styleRawValue = SwitcherStyle.grid.rawValue

    private let headerPadding: Double = 12

    private var layout: CyclePanelLayout {
        CyclePanelLayout(
            style: SwitcherStyle(rawValue: styleRawValue) ?? .grid,
            showsDetails: !state.windows.isEmpty,
            showsPreviews: state.showsPreviews,
            itemCount: state.layoutItemCount,
            showsLaunchPrompt: state.launchPrompt != nil,
            showsFooter: state.mode == .otherApps
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            Text(state.applicationTitle)
                .font(.headline)
                .foregroundColor(.white)
                .lineLimit(1)
                .padding(.vertical, headerPadding)

            Divider()
                .background(Color.white.opacity(0.2))

            if let prompt = state.launchPrompt {
                LaunchPromptView(
                    appName: state.applicationTitle,
                    icon: state.applicationIcon,
                    prompt: prompt
                )
                .frame(height: CyclePanelLayout.launchPromptHeight)
            } else {
            if state.items.isEmpty, state.mode == .otherApps {
                Text("No open app matches “\(state.filterText)”")
                    .foregroundColor(.white.opacity(0.6))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 40)
            } else {
            switch layout.effectiveStyle {
            case .listWithPreview: listWithPreview
            case .largeThumbnails: windowList(thumbnailSize: CyclePanelLayout.largeRowThumbnailSize)
            case .grid: grid
            case .spotlight: spotlight
            case nil: windowList(thumbnailSize: nil)
            }
            }
            }

            if state.mode == .otherApps {
                Spacer(minLength: 0)
                OtherAppsFooter(state: state)
                    .frame(height: CyclePanelLayout.footerHeight)
            }
        }
        .frame(width: layout.panelWidth, alignment: .top)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Color.clear)
    }

    // MARK: - Item text and pictures

    private func itemTitle(_ item: CyclePanelItem) -> String {
        switch item {
        case .window(let window):
            return state.displayTitles[window.id] ?? window.title
        case .action(let action):
            return action.title
        }
    }

    private func itemDetail(_ item: CyclePanelItem) -> String? {
        switch item {
        case .window(let window):
            let detail = state.details[window.id]?.text
            // Several apps are mixed together here, so name the app.
            guard state.mode == .otherApps else { return detail }
            return [window.application.title, detail].compactMap { $0 }.joined(separator: " · ")
        case .action:
            return nil
        }
    }

    /// Shown while a picture loads, or instead of one.
    private func itemIcon(_ item: CyclePanelItem) -> NSImage? {
        guard state.mode == .otherApps else { return state.applicationIcon }
        switch item {
        case .window(let window): return window.application.runningApplication?.icon
        case .action: return nil
        }
    }

    /// The small app icon on a card's corner, when windows of several apps are mixed.
    private func itemBadge(_ item: CyclePanelItem) -> NSImage? {
        guard state.mode == .otherApps else { return nil }
        switch item {
        case .window(let window): return window.application.runningApplication?.icon
        case .action: return nil
        }
    }

    private func itemImage(_ item: CyclePanelItem) -> NSImage? {
        switch item {
        case .window(let window): return state.thumbnails[window.id]
        case .action: return nil
        }
    }

    private var indexedItems: [(offset: Int, element: CyclePanelItem)] {
        Array(state.items.enumerated())
    }

    // MARK: - List (+ big preview)

    @ViewBuilder
    private var listWithPreview: some View {
        HStack(alignment: .top, spacing: 0) {
            windowList(thumbnailSize: CyclePanelLayout.rowThumbnailSize)
                .frame(width: layout.listWidth)

            Rectangle()
                .fill(Color.white.opacity(0.12))
                .frame(width: CyclePanelLayout.dividerHeight)
                .frame(maxHeight: .infinity)

            if let item = state.currentItem {
                SelectedWindowPreview(
                    image: itemImage(item),
                    fallbackIcon: itemIcon(item),
                    title: itemTitle(item),
                    detail: itemDetail(item)
                )
                .frame(width: layout.previewPaneWidth)
            }
        }
    }

    @ViewBuilder
    private func windowList(thumbnailSize: CGSize?) -> some View {
        let rows = VStack(spacing: CyclePanelLayout.rowSpacing) {
            ForEach(indexedItems, id: \.offset) { index, item in
                CyclePanelRow(
                    title: itemTitle(item),
                    detail: itemDetail(item),
                    isSelected: index == state.selectedIndex,
                    height: layout.rowHeight,
                    preview: thumbnailSize.flatMap { size in
                        if case .action = item { return nil }
                        return CyclePanelRow.Preview(image: itemImage(item), fallbackIcon: itemIcon(item), size: size, badge: itemBadge(item))
                    }
                )
                .id(index)
            }
        }
        .padding(CyclePanelLayout.listPadding)

        if state.items.count <= CyclePanelLayout.maxNonScrollingRows {
            rows
        } else {
            ScrollViewReader { proxy in
                ScrollView { rows }
                    .frame(height: layout.listHeight)
                    .onChange(of: state.selectedIndex) {
                        withAnimation(.easeInOut(duration: 0.15)) {
                            proxy.scrollTo(state.selectedIndex, anchor: .center)
                        }
                    }
            }
        }
    }

    // MARK: - Grid

    @ViewBuilder
    private var grid: some View {
        let columns = Array(
            repeating: GridItem(.fixed(layout.cardSize.width), spacing: CyclePanelLayout.cardSpacing),
            count: layout.gridColumns
        )
        let cards = LazyVGrid(columns: columns, spacing: CyclePanelLayout.cardSpacing) {
            ForEach(indexedItems, id: \.offset) { index, item in
                WindowCard(
                    image: itemImage(item),
                    fallbackIcon: itemIcon(item),
                    badge: itemBadge(item),
                    title: itemTitle(item),
                    detail: itemDetail(item),
                    isSelected: index == state.selectedIndex
                )
                .id(index)
            }
        }
        .padding(CyclePanelLayout.gridPadding)

        if layout.gridRows <= CyclePanelLayout.maxVisibleGridRows {
            cards
        } else {
            ScrollViewReader { proxy in
                ScrollView { cards }
                    .frame(height: layout.gridVisibleHeight)
                    .onChange(of: state.selectedIndex) {
                        withAnimation(.easeInOut(duration: 0.15)) {
                            proxy.scrollTo(state.selectedIndex, anchor: .center)
                        }
                    }
            }
        }
    }

    // MARK: - Big preview + strip

    @ViewBuilder
    private var spotlight: some View {
        VStack(spacing: 0) {
            if let item = state.currentItem {
                VStack(alignment: .center, spacing: 8) {
                    WindowThumbnailView(
                        image: itemImage(item),
                        fallbackIcon: itemIcon(item),
                        isSelected: false,
                        size: CyclePanelLayout.spotlightSize,
                        iconSize: 64
                    )

                    VStack(spacing: 2) {
                        Text(itemTitle(item))
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundColor(.white)
                            .lineLimit(1)
                        if let detail = itemDetail(item) {
                            Text(detail)
                                .font(.caption)
                                .foregroundColor(.white.opacity(0.6))
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                    }
                    .frame(height: CyclePanelLayout.spotlightCaptionHeight, alignment: .top)
                }
                .padding(.top, CyclePanelLayout.gridPadding)
            }

            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: CyclePanelLayout.stripSpacing) {
                        ForEach(indexedItems, id: \.offset) { index, item in
                            StripCell(
                                image: itemImage(item),
                                fallbackIcon: itemIcon(item),
                                badge: itemBadge(item),
                                title: itemTitle(item),
                                isSelected: index == state.selectedIndex
                            )
                            .id(index)
                        }
                    }
                }
                .frame(width: layout.stripVisibleWidth, height: layout.stripCellSize.height)
                .onChange(of: state.selectedIndex) {
                    withAnimation(.easeInOut(duration: 0.15)) {
                        proxy.scrollTo(state.selectedIndex, anchor: .center)
                    }
                }
            }
            .padding(.top, 10)
            .padding(.bottom, CyclePanelLayout.gridPadding)
        }
        .frame(maxWidth: .infinity)
    }
}

// MARK: - Pieces

/// Shown when the bound app is not running: launching waits for a second press.
struct LaunchPromptView: View {
    let appName: String
    let icon: NSImage?
    let prompt: CyclePanelState.LaunchPrompt

    var body: some View {
        HStack(spacing: 16) {
            if let icon {
                Image(nsImage: icon)
                    .resizable()
                    .frame(width: 56, height: 56)
                    .opacity(0.85)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("\(appName) isn't open")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(.white)
                    .lineLimit(1)

                HStack(spacing: 6) {
                    Text("Press")
                    KeyCap(text: prompt.key)
                    Text("again to open it")
                }
                .font(.system(size: 13))
                .foregroundColor(.white.opacity(0.85))

                Text("Let go of \(prompt.modifiers) or press Esc to cancel")
                    .font(.caption)
                    .foregroundColor(.white.opacity(0.5))
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 24)
    }
}

/// A key drawn like a keyboard key.
struct KeyCap: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 12, weight: .semibold, design: .rounded))
            .foregroundColor(.white)
            .frame(minWidth: 22, minHeight: 22)
            .padding(.horizontal, 4)
            .background(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(Color.white.opacity(0.16))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.25), lineWidth: 1)
            )
    }
}

struct CyclePanelRow: View {
    /// What to draw in the preview slot. A row without one keeps the compact text-only look.
    struct Preview {
        let image: NSImage?
        let fallbackIcon: NSImage?
        var size: CGSize = CyclePanelLayout.rowThumbnailSize
        var badge: NSImage? = nil
    }

    let title: String
    var detail: String? = nil
    let isSelected: Bool
    var height: CGFloat = 44
    var preview: Preview? = nil

    var body: some View {
        HStack(spacing: 12) {
            // Selection indicator
            Circle()
                .fill(isSelected ? Color.accentColor : Color.clear)
                .frame(width: 6, height: 6)

            if let preview {
                WindowThumbnailView(
                    image: preview.image,
                    fallbackIcon: preview.fallbackIcon,
                    isSelected: isSelected,
                    size: preview.size,
                    iconSize: preview.size.height * 0.45,
                    badge: preview.badge
                )
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .foregroundColor(isSelected ? .white : .primary)
                    .lineLimit(1)

                if let detail {
                    Text(detail)
                        .font(.caption)
                        .foregroundColor(.white.opacity(isSelected ? 0.75 : 0.5))
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .frame(height: height)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(isSelected ? Color.accentColor.opacity(0.3) : Color.clear)
        )
    }
}

/// The big picture of the selected window, like a browser's tab hover preview.
struct SelectedWindowPreview: View {
    let image: NSImage?
    let fallbackIcon: NSImage?
    let title: String
    let detail: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            WindowThumbnailView(
                image: image,
                fallbackIcon: fallbackIcon,
                isSelected: false,
                size: CyclePanelLayout.largePreviewSize,
                iconSize: 56
            )

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.white)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)

                if let detail {
                    Text(detail)
                        .font(.caption)
                        .foregroundColor(.white.opacity(0.6))
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            .frame(height: CyclePanelLayout.previewCaptionHeight, alignment: .topLeading)
        }
        .padding(CyclePanelLayout.previewPanePadding)
    }
}

/// One window in the grid: a big picture with its title and detail underneath.
struct WindowCard: View {
    let image: NSImage?
    let fallbackIcon: NSImage?
    var badge: NSImage? = nil
    let title: String
    let detail: String?
    let isSelected: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            WindowThumbnailView(
                image: image,
                fallbackIcon: fallbackIcon,
                isSelected: isSelected,
                size: CyclePanelLayout.cardThumbnailSize,
                iconSize: 48,
                badge: badge
            )

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.white.opacity(isSelected ? 1 : 0.85))
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                if let detail {
                    Text(detail)
                        .font(.caption)
                        .foregroundColor(.white.opacity(isSelected ? 0.75 : 0.5))
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            .frame(width: CyclePanelLayout.cardThumbnailSize.width, height: CyclePanelLayout.cardCaptionHeight, alignment: .topLeading)
        }
        .padding(CyclePanelLayout.cardPadding)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(isSelected ? Color.accentColor.opacity(0.3) : Color.white.opacity(0.04))
        )
    }
}

/// One window in the strip under the big preview.
struct StripCell: View {
    let image: NSImage?
    let fallbackIcon: NSImage?
    var badge: NSImage? = nil
    let title: String
    let isSelected: Bool

    var body: some View {
        VStack(spacing: 4) {
            WindowThumbnailView(
                image: image,
                fallbackIcon: fallbackIcon,
                isSelected: isSelected,
                size: CyclePanelLayout.stripThumbnailSize,
                iconSize: 28,
                badge: badge
            )
            Text(title)
                .font(.system(size: 11))
                .foregroundColor(.white.opacity(isSelected ? 1 : 0.6))
                .lineLimit(1)
                .frame(width: CyclePanelLayout.stripThumbnailSize.width, height: CyclePanelLayout.stripTitleHeight)
        }
        .padding(CyclePanelLayout.stripCellPadding)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(isSelected ? Color.accentColor.opacity(0.3) : Color.clear)
        )
    }
}

/// A picture of a window, fitted into a box of the given size.
struct WindowThumbnailView: View {
    let image: NSImage?
    let fallbackIcon: NSImage?
    let isSelected: Bool
    let size: CGSize
    var iconSize: CGFloat = 24
    /// A small app icon in the bottom-left corner.
    var badge: NSImage? = nil

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color.black.opacity(0.25))

            if let image {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                    .padding(2)
            } else if let icon = fallbackIcon {
                // No picture yet (still loading, or the window is minimized).
                Image(nsImage: icon)
                    .resizable()
                    .frame(width: iconSize, height: iconSize)
                    .opacity(0.6)
            }
        }
        .frame(width: size.width, height: size.height)
        .overlay(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .strokeBorder(
                    isSelected ? Color.accentColor : Color.white.opacity(0.15),
                    lineWidth: isSelected ? 2 : 1
                )
        )
        .overlay(alignment: .bottomLeading) {
            // Only over a picture: without one, the big app icon already says which app.
            if let badge, image != nil {
                let side = min(28, max(16, size.height * 0.2))
                Image(nsImage: badge)
                    .resizable()
                    .frame(width: side, height: side)
                    .shadow(color: .black.opacity(0.5), radius: 2, y: 1)
                    .offset(x: 6, y: -6)
            }
        }
    }
}

/// Bottom line of the other-apps switcher: what's been typed, and how to give an app a number.
struct OtherAppsFooter: View {
    @ObservedObject var state: CyclePanelState

    private var hint: String {
        if let message = state.footerMessage { return message }
        guard !state.freeNumbers.isEmpty else { return "Every number is taken" }
        let numbers = state.freeNumbers.prefix(4).map(String.init).joined(separator: " ")
        let more = state.freeNumbers.count > 4 ? " …" : ""
        return "\(state.modifierSymbols) + a free number (\(numbers)\(more)) gives it a number"
    }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundColor(.white.opacity(0.5))
            if state.filterText.isEmpty {
                Text("Type to search")
                    .foregroundColor(.white.opacity(0.4))
            } else {
                Text(state.filterText)
                    .foregroundColor(.white)
                + Text("  Return to switch")
                    .foregroundColor(.white.opacity(0.4))
            }

            Spacer(minLength: 12)

            Text(hint)
                .foregroundColor(state.footerMessage == nil ? .white.opacity(0.5) : .green.opacity(0.9))
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .font(.system(size: 12))
        .padding(.horizontal, 16)
        .background(Color.white.opacity(0.04))
    }
}
