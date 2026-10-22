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
                    // Double-click any empty part of the open notch to pin/unpin it.
                    .onTapGesture(count: 2) { if vm.isOpen { vm.pinned.toggle() } }
                    .shadow(color: .black.opacity(vm.isOpen ? 0.45 : (clickToOpenHover ? 0.35 : 0)), radius: vm.isOpen ? 18 : 8, y: vm.isOpen ? 8 : 3)
                Group {
                    if vm.showsContent {
                        Group {
                            if vm.launcherPresented { LauncherView(vm: vm).transition(.identity) }
                            else {
                                ExpandedView(vm: vm).transition(.identity)
                                    .onAppear { vm.contentDidAttach?() }
                            }
                        }
                        // No fade on open: an opacity transition renders outside the clip. The content is simply there,
                        // revealed by the springing shape like a mask.
                        .transition(.identity)
                    } else if !vm.isOpen, vm.panelVisible {
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
                if case let .plugin(activity) = vm.activity { vm.open(tab: activity.pluginID) } else { vm.open() }
            }
            .onDrop(of: [.fileURL], isTargeted: $vm.isDropTargeted) { providers in
                guard Features.shared.tabEnabled("shelf") else { return false }
                vm.services.shelf.add(providers)
                vm.open(tab: "shelf")
                return true
            }
            Spacer(minLength: 0)
        }
        .frame(width: NotchController.panelSize.width, height: NotchController.panelSize.height)
        .environment(\.colorScheme, .dark)
        .focusEffectDisabled() // no system focus rings anywhere in the notch; focused controls get a soft tint instead
    }
}

struct CollapsedView: View {
    @ObservedObject var vm: NotchViewModel
    private var media: MediaController { vm.services.media }
    private var timers: TimerService { vm.services.timers }

    var body: some View {
        let height = vm.geometry.notch.height
        HStack {
            switch vm.activity {
            case let .plugin(activity):
                switch activity.style {
                case "recording": // dictation look: glowing red dot + elapsed time, no level meter
                    Circle().fill(Color.red).frame(width: 8, height: 8).shadow(color: .red.opacity(0.8), radius: 4)
                    Spacer()
                    TimelineView(.periodic(from: .now, by: 0.5)) { context in
                        let seconds = max(0, Int(context.date.timeIntervalSince(activity.startedAt ?? context.date)))
                        Text(String(format: "%d:%02d", seconds / 60, seconds % 60)).font(.system(size: 12, weight: .semibold)).monospacedDigit().foregroundStyle(.red)
                    }
                case "progress":
                    Image(systemName: activity.symbol).font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
                    Spacer()
                    ProgressView().controlSize(.mini).tint(.white)
                case "done":
                    Image(systemName: activity.symbol).font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
                    Spacer()
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                case "failed":
                    Image(systemName: activity.symbol).font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
                    Spacer()
                    Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.red)
                default:
                    Image(systemName: activity.symbol).font(.system(size: 12, weight: .semibold)).foregroundStyle(Color(css: activity.color))
                    Spacer()
                    if let started = activity.startedAt {
                        TimelineView(.periodic(from:.now,by:0.5)) { context in
                            let seconds = max(0,Int(context.date.timeIntervalSince(started)))
                            Text(String(format:"%d:%02d",seconds / 60, seconds % 60)).font(.system(size:12,weight:.semibold)).monospacedDigit().foregroundStyle(Color(css:activity.color))
                        }
                    } else { Text(activity.text).font(.system(size: 12, weight: .semibold)).foregroundStyle(Color(css: activity.color)).lineLimit(1) }
                }
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
                Text(vm.currentGroup?.name ?? vm.currentTab?.name ?? "")
                    .font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(.leading, 6)
                Color.clear.frame(width: notch.width)
                HStack(spacing: 2) {
                    Spacer()
                    if Features.shared.enabled("launcher") {
                    IconButton("magnifyingglass", size: 12) { (NSApp.delegate as? AppDelegate)?.openLauncher(in: vm) }
                        .help("Search enabled plugin providers")
                    }
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

            if vm.currentGroup != nil { TabDeckSwitcher(vm: vm) }

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
                if Features.shared.enabled("keyboard"), vm.keyboard.isPresented { KeyboardPalette(vm: vm) }
            }
            .frame(maxWidth: .infinity)
            .frame(height: vm.contentHeight, alignment: .topLeading)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))

            TabDock(vm: vm).frame(height: NotchViewModel.dockHeight)
        }
        .padding(.horizontal, 14)
        .padding(.bottom, 10)
        .foregroundStyle(.white)
        .environment(\.nookKeyboardOwner, vm.web.keyboardID)
    }

    @ViewBuilder private var content: some View {
        let s = vm.services
        if let tab = vm.currentTab, let webView = vm.web.view(for: tab) {
            WebPluginView(webView: webView).id(tab.id)
        } else if vm.currentTab != nil {
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
