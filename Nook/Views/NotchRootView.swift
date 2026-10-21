import SwiftUI

struct NotchRootView: View {
    @ObservedObject var vm: NotchViewModel
    @AppStorage(Prefs.openOnHover) private var openOnHover = true

    private var clickToOpenHover: Bool { !openOnHover && vm.isHovering && !vm.isOpen }

    var body: some View {
        let size = vm.contentSize
        let flare: CGFloat = vm.isOpen ? 12 : 6
        let shape = NotchShape(topRadius: flare, bottomRadius: vm.isOpen ? 24 : 10)
        VStack(spacing: 0) {
            ZStack(alignment: .top) {
                shape
                    .fill(Color.black)
                    .shadow(color: .black.opacity(vm.isOpen ? 0.45 : (clickToOpenHover ? 0.35 : 0)), radius: vm.isOpen ? 18 : 8, y: vm.isOpen ? 8 : 3)
                Group {
                    if vm.showsContent {
                        ExpandedView(vm: vm).transition(.opacity)
                    } else if !vm.isOpen {
                        CollapsedView(vm: vm).transition(.opacity)
                    }
                }
                .padding(.horizontal, flare)
                // A fixed frame, not a flexible one: a flexible frame never goes smaller than its content, so the clip
                // would stay at the open size. Clip to the springing shape so the notch reveals/hides the content.
                .frame(width: size.width + flare * 2, height: size.height, alignment: .top)
                .clipShape(shape)
            }
            .frame(width: size.width + flare * 2, height: size.height)
            .contentShape(Rectangle())
            .onTapGesture {
                guard !vm.isOpen else { return }
                if case .dictation(.failed) = vm.activity { vm.open(tab: "dictation") } else { vm.open() }
            }
            .onDrop(of: [.fileURL], isTargeted: $vm.isDropTargeted) { providers in
                vm.services.shelf.add(providers)
                vm.open(tab: "shelf")
                return true
            }
            Spacer(minLength: 0)
        }
        .frame(width: NotchController.panelSize.width, height: NotchController.panelSize.height)
        .environment(\.colorScheme, .dark)
    }
}

struct CollapsedView: View {
    @ObservedObject var vm: NotchViewModel
    @ObservedObject private var media: MediaController
    @ObservedObject private var timers: TimerService
    @ObservedObject private var dictation: DictationService

    init(vm: NotchViewModel) {
        self.vm = vm
        _media = ObservedObject(wrappedValue: vm.services.media)
        _timers = ObservedObject(wrappedValue: vm.services.timers)
        _dictation = ObservedObject(wrappedValue: vm.services.dictation)
    }

    var body: some View {
        let height = vm.geometry.notch.height
        HStack {
            switch vm.activity {
            case let .dictation(phase):
                dictationSides(phase, height: height)
            case let .plugin(activity):
                Image(systemName: activity.symbol).font(.system(size: 12, weight: .semibold)).foregroundStyle(Color(css: activity.color))
                Spacer()
                Text(activity.text).font(.system(size: 12, weight: .semibold)).foregroundStyle(Color(css: activity.color)).lineLimit(1)
            case .music:
                Artwork(image: media.artwork, size: height - 10)
                Spacer()
                AudioBars(playing: media.track?.isPlaying == true).frame(width: 18, height: height * 0.42)
            case .timer:
                Image(systemName: "timer").font(.system(size: 13, weight: .semibold)).foregroundStyle(.orange)
                Spacer()
                Text(timers.displayText).font(.system(size: 12, weight: .semibold)).monospacedDigit().foregroundStyle(.orange)
            case nil:
                EmptyView()
            }
        }
        .padding(.horizontal, 10)
        .frame(height: height)
    }

    @ViewBuilder
    private func dictationSides(_ phase: DictationService.Phase, height: CGFloat) -> some View {
        switch phase {
        case .recording:
            Circle().fill(Color.red).frame(width: 8, height: 8)
                .shadow(color: .red.opacity(0.8), radius: 4)
            Spacer()
            // How long you've been talking (replaces the level meter).
            TimelineView(.periodic(from: .now, by: 0.5)) { context in
                let seconds = Int(context.date.timeIntervalSince(dictation.recordingStartedAt ?? context.date))
                Text(String(format: "%d:%02d", seconds / 60, seconds % 60))
                    .font(.system(size: 12, weight: .semibold)).monospacedDigit()
                    .foregroundStyle(.red)
            }
        case .transcribing:
            Image(systemName: "waveform").font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
            Spacer()
            ProgressView().controlSize(.mini).tint(.white)
        case .done:
            Image(systemName: "waveform").font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
            Spacer()
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .failed:
            Image(systemName: "waveform").font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
            Spacer()
            Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.red)
        case .idle:
            EmptyView()
        }
    }
}

/// Live mic bars: centre bars move most.
struct LevelBars: View {
    let level: Float

    var body: some View {
        HStack(spacing: 2) {
            ForEach(0..<5, id: \.self) { i in
                let weight: Float = [0.5, 0.8, 1, 0.8, 0.5][i]
                Capsule().fill(Color.white)
                    .frame(width: 2.5)
                    .scaleEffect(y: CGFloat(max(0.15, level * weight)))
            }
        }
        .animation(.easeOut(duration: 0.08), value: level)
    }
}

struct ExpandedView: View {
    @ObservedObject var vm: NotchViewModel

    var body: some View {
        let notch = vm.geometry.notch
        VStack(spacing: 8) {
            HStack(spacing: 0) {
                Text(vm.currentTab?.name ?? "")
                    .font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(.leading, 6)
                Color.clear.frame(width: notch.width)
                HStack(spacing: 2) {
                    Spacer()
                    if vm.currentTab != nil {
                        IconButton(vm.showingSettings ? "slider.horizontal.3" : "slider.horizontal.3", size: 12) {
                            withAnimation(.snappy(duration: 0.2)) { vm.showingSettings.toggle() }
                        }
                        .foregroundStyle(vm.showingSettings ? Color.orange : Color.white)
                        .help("Customize \(vm.currentTab?.name ?? "")")
                    }
                    IconButton(vm.pinned ? "pin.fill" : "pin", size: 12) { vm.pinned.toggle() }
                        .foregroundStyle(vm.pinned ? Color.orange : Color.white)
                        .help(vm.pinned ? "Unpin — close when the mouse leaves" : "Pin — keep the notch open")
                    IconButton("gearshape.fill") { (NSApp.delegate as? AppDelegate)?.openSettings() }
                }
                .frame(maxWidth: .infinity)
            }
            .frame(height: notch.height)

            // The clip lives on this fixed container, so sliding tabs never spill past the content area.
            ZStack {
                content
                    .id(vm.tab)
                    .transition(.push(from: vm.slideEdge))
                if vm.showingSettings, let tab = vm.currentTab {
                    ScrollView {
                        PluginSettingsForm(tab: tab, compact: true) { withAnimation(.snappy(duration: 0.2)) { vm.showingSettings = false } }
                            .padding(14)
                    }
                    .scrollIndicators(.hidden)
                    .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color(white: 0.09)))
                    .transition(.opacity.combined(with: .scale(scale: 0.98)))
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: vm.contentHeight, alignment: .topLeading)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))

            TabDock(vm: vm).frame(height: NotchViewModel.dockHeight)
        }
        .padding(.horizontal, 14)
        .padding(.bottom, 10)
        .foregroundStyle(.white)
    }

    @ViewBuilder private var content: some View {
        let s = vm.services
        if let tab = vm.currentTab, let webView = vm.web.view(for: tab) {
            WebPluginView(webView: webView).id(tab.id)
        } else {
            switch vm.tab {
            case "media": HomeTab(media: s.media)
            case "shelf": ShelfTab(shelf: s.shelf, isTargeted: vm.isDropTargeted)
            case "scratch": ScratchTab()
            case "timers": TimersTab(timers: s.timers)
            default: EmptyState(symbol: "puzzlepiece.extension", title: "Missing plugin", detail: vm.tab)
            }
        }
    }
}

/// Tab icons along the bottom of the open notch.
struct TabDock: View {
    @ObservedObject var vm: NotchViewModel
    @State private var dragging: String?

    var body: some View {
        HStack(spacing: 4) {
            ForEach(vm.enabledTabs) { tab in
                let selected = vm.tab == tab.id
                Image(systemName: tab.symbol)
                    .font(.system(size: 13, weight: .semibold))
                    .frame(width: 34, height: 26)
                    .background(Capsule().fill(Color.white.opacity(selected ? 0.16 : 0)))
                    .foregroundStyle(selected ? .white : .secondary)
                    .opacity(dragging == tab.id ? 0.35 : 1)
                    .contentShape(Capsule())
                    .onTapGesture { vm.select(tab.id) }
                    .onDrag {
                        dragging = tab.id
                        return NSItemProvider(object: tab.id as NSString)
                    }
                    .onDrop(of: [.fileURL, .plainText], delegate: DockDropDelegate(target: tab.id, vm: vm, dragging: $dragging))
                    .help(TabHotkeys.get(tab.id).map { "\(tab.name)  \($0.display)" } ?? tab.name)
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(Capsule().fill(Color.white.opacity(0.05)))
        .onDrop(of: [.plainText], isTargeted: nil) { _ in dragging = nil; return true } // dropped on the dock's padding
    }
}

/// One drop target per dock icon:
/// - dragging another tab icon over it → live reorder (saved for every notch)
/// - dragging a file over it → spring-load: switch to that tab so the file can be dropped there
private struct DockDropDelegate: DropDelegate {
    let target: String
    let vm: NotchViewModel
    @Binding var dragging: String?

    private func isFile(_ info: DropInfo) -> Bool { info.hasItemsConforming(to: [.fileURL]) }

    func dropEntered(info: DropInfo) {
        if isFile(info) {
            if vm.tab != target { withAnimation(.snappy(duration: 0.2)) { vm.tab = target } }
        } else if let dragging, dragging != target {
            withAnimation(.snappy(duration: 0.22)) { vm.services.plugins.move(dragging, to: target) }
        }
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: isFile(info) ? .copy : .move)
    }

    func performDrop(info: DropInfo) -> Bool {
        let wasReorder = dragging != nil && !isFile(info)
        dragging = nil
        return wasReorder
    }
}

extension Color {
    /// "#rrggbb" or a few CSS names; falls back to white.
    init(css: String) {
        let named: [String: Color] = ["orange": .orange, "red": .red, "green": .green, "blue": .blue, "yellow": .yellow, "purple": .purple, "pink": .pink, "white": .white]
        if let color = named[css.lowercased()] { self = color; return }
        let hex = css.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        guard hex.count == 6, let value = UInt32(hex, radix: 16) else { self = .white; return }
        self = Color(red: Double((value >> 16) & 0xFF) / 255, green: Double((value >> 8) & 0xFF) / 255, blue: Double(value & 0xFF) / 255)
    }
}
