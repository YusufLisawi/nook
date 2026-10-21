import SwiftUI

/// A quiet, scrollable row above the active plugin. Its height is separate from the plugin's own canvas.
struct TabDeckSwitcher: View {
    @ObservedObject var vm: NotchViewModel

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal) {
                HStack(spacing: 3) {
                    ForEach(vm.deckDisplayTabs) { member in
                        let selected = member.id == vm.tab
                        Button { vm.select(member.id) } label: {
                            Label(member.name, systemImage: member.symbol)
                                .font(.system(size: 11, weight: selected ? .semibold : .medium))
                                .lineLimit(1).padding(.horizontal, 10).frame(height: 24)
                                .background(Capsule().fill(.white.opacity(selected ? 0.14 : 0)))
                                .foregroundStyle(selected ? .white : .secondary)
                        }
                        .buttonStyle(.plain).keyboardFocusRing()
                        .id(member.id)
                        .accessibilityLabel(member.name)
                        .accessibilityValue(selected ? "Selected" : "")
                        .onKeyPress(.leftArrow) { vm.stepDeck(-1); return .handled }
                        .onKeyPress(.rightArrow) { vm.stepDeck(1); return .handled }
                        .help("\(member.name) · ⌥⌘← / ⌥⌘→ switch deck members")
                    }
                }
                .padding(2)
                .background(Capsule().fill(.white.opacity(0.05)))
            }
            .scrollIndicators(.hidden)
            .onChange(of: vm.tab) { _, id in withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo(id, anchor: .center) } }
            .onAppear { proxy.scrollTo(vm.tab, anchor: .center) }
        }
        .frame(height: 26)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(vm.currentGroup?.name ?? "Tab") deck")
    }
}

/// Dock items are either standalone plugins or a single icon representing a deck.
struct TabDock: View {
    @ObservedObject var vm: NotchViewModel
    @ObservedObject private var navigation = TabNavigationStore.shared
    @State private var dragging: String?

    /// The dock never grows past this; extra icons scroll sideways with no scroll bar.
    static let maxWidth: CGFloat = 400
    @State private var fadeLeading = false
    @State private var fadeTrailing = false

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal) {
                HStack(spacing: 4) {
                    ForEach(vm.dockItems) { item in dockButton(item) }
                }
                .padding(.horizontal, 6).padding(.vertical, 2)
                .onDrop(of: [.plainText], isTargeted: nil) { _ in dragging = nil; return true }
            }
            .scrollIndicators(.never) // .hidden still shows with "Always show scroll bars"
            .modifier(DockEdgeTracker(leading: $fadeLeading, trailing: $fadeTrailing))
            .mask(edgeFade)
            .onChange(of: vm.currentDockID) { _, id in
                withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo(id, anchor: .center) }
            }
            .onAppear { proxy.scrollTo(vm.currentDockID, anchor: .center) }
        }
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: Self.maxWidth)
        .background(Capsule().fill(.white.opacity(0.05)))
        .clipShape(Capsule())
        .frame(maxWidth: .infinity)
        .frame(height: NotchViewModel.dockHeight)
    }

    /// Soft shadows at the edges that still have icons beyond them.
    private var edgeFade: some View {
        HStack(spacing: 0) {
            LinearGradient(colors: [.black.opacity(fadeLeading ? 0 : 1), .black], startPoint: .leading, endPoint: .trailing).frame(width: 28)
            Color.black
            LinearGradient(colors: [.black, .black.opacity(fadeTrailing ? 0 : 1)], startPoint: .leading, endPoint: .trailing).frame(width: 28)
        }
        .animation(.easeOut(duration: 0.15), value: fadeLeading)
        .animation(.easeOut(duration: 0.15), value: fadeTrailing)
    }

    private func dockButton(_ item: DockItem) -> some View {
        let group = item.groupID.flatMap { navigation.group($0) }
        let plugin = vm.enabledTabs.first { $0.id == item.pluginIDs.first }
        let name = group?.name ?? plugin?.name ?? "Plugin"
        let selected = vm.currentDockID == item.id
        let shortcut = group?.hotkey ?? plugin.flatMap { TabHotkeys.get($0.id) }
        return Button { vm.selectDockItem(item) } label: {
            Image(systemName: group?.symbol ?? plugin?.symbol ?? "puzzlepiece.extension")
                .font(.system(size: 13, weight: .semibold))
                .frame(width: 34, height: 26)
                .background(Capsule().fill(.white.opacity(selected ? 0.16 : 0)))
                .foregroundStyle(selected ? .white : .secondary)
                .opacity(dragging == item.id ? 0.35 : 1)
                .contentShape(Capsule())
        }
        .id(item.id)
        .buttonStyle(.plain).keyboardFocusRing()
        .onKeyPress(.return) { vm.selectDockItem(item); return .handled }
        .accessibilityLabel(group == nil ? name : "\(name) group")
        .accessibilityValue(selected ? "Selected" : "")
        .onDrag { dragging = item.id; return NSItemProvider(object: item.id as NSString) }
        .onDrop(of: [.fileURL, .plainText], delegate: NavigationDockDrop(target: item, vm: vm, dragging: $dragging))
        .contextMenu {
            Button("Hide from Dock", systemImage: "eye.slash") {
                for id in group?.members ?? item.pluginIDs { navigation.setHidden(id, true) }
            }
            Menu("Add to Group") {
                let targets = navigation.groups.filter { $0.id != item.groupID }
                ForEach(targets) { target in
                    Button(target.name, systemImage: target.symbol) {
                        let member = item.pluginIDs.contains(vm.tab) ? vm.tab : item.pluginIDs.first
                        if let member { navigation.add(member, to: target.id, pluginIDs: vm.services.plugins.orderedTabs.map(\.id)) }
                    }
                }
                if targets.isEmpty { Text("Create a group in Tabs & Plugins") }
            }
            Divider()
            Button("Settings…", systemImage: "slider.horizontal.3") {
                navigation.settingsSelection = item.id
                (NSApp.delegate as? AppDelegate)?.showSettings(pane: "tabs")
            }
        }
        .help(shortcut.map { "\(name)  \($0.display)" } ?? name)
    }
}

private struct NavigationDockDrop: DropDelegate {
    let target: DockItem
    let vm: NotchViewModel
    @Binding var dragging: String?

    private func isFile(_ info: DropInfo) -> Bool { info.hasItemsConforming(to: [.fileURL]) }
    func dropEntered(info: DropInfo) {
        if isFile(info) { vm.selectDockItem(target) }
        else if let dragging, dragging != target.id {
            withAnimation(.snappy(duration: 0.22)) {
                TabNavigationStore.shared.move(dragging, to: target.id, items: vm.dockItems)
            }
        }
    }
    func dropUpdated(info: DropInfo) -> DropProposal? { DropProposal(operation: isFile(info) ? .copy : .move) }
    func performDrop(info: DropInfo) -> Bool {
        let wasReorder = dragging != nil && !isFile(info)
        dragging = nil
        return wasReorder
    }
}

/// Which dock edges have more icons past them (macOS 15+ reads the live scroll position).
private struct DockEdgeTracker: ViewModifier {
    @Binding var leading: Bool
    @Binding var trailing: Bool

    func body(content: Content) -> some View {
        if #available(macOS 15.0, *) {
            content.onScrollGeometryChange(for: [Bool].self) { geo in
                let x = geo.contentOffset.x + geo.contentInsets.leading
                return [x > 1, x + geo.containerSize.width < geo.contentSize.width - 1]
            } action: { _, edges in
                leading = edges[0]
                trailing = edges[1]
            }
        } else {
            content.onAppear { trailing = true } // macOS 14: no scroll position, hint that more is to the right
        }
    }
}
