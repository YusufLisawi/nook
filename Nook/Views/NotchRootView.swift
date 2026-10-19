import SwiftUI

struct NotchRootView: View {
    @ObservedObject var vm: NotchViewModel

    var body: some View {
        let size = vm.contentSize
        let flare: CGFloat = vm.isOpen ? 12 : 6
        VStack(spacing: 0) {
            ZStack(alignment: .top) {
                NotchShape(topRadius: flare, bottomRadius: vm.isOpen ? 24 : 10)
                    .fill(Color.black)
                    .shadow(color: .black.opacity(vm.isOpen ? 0.45 : 0), radius: 18, y: 8)
                Group {
                    if vm.isOpen {
                        ExpandedView(vm: vm).transition(.opacity.combined(with: .scale(scale: 0.96, anchor: .top)))
                    } else {
                        CollapsedView(vm: vm).transition(.opacity)
                    }
                }
                .padding(.horizontal, flare)
            }
            .frame(width: size.width + flare * 2, height: size.height)
            .contentShape(Rectangle())
            .onTapGesture { if !vm.isOpen { vm.open() } }
            .onDrop(of: [.fileURL], isTargeted: $vm.isDropTargeted) { providers in
                vm.shelf.add(providers)
                vm.open(tab: .shelf)
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

    init(vm: NotchViewModel) {
        self.vm = vm
        _media = ObservedObject(wrappedValue: vm.media)
        _timers = ObservedObject(wrappedValue: vm.timers)
    }

    var body: some View {
        let height = vm.geometry.notch.height
        HStack {
            switch vm.activity {
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

struct ExpandedView: View {
    @ObservedObject var vm: NotchViewModel

    var body: some View {
        let notch = vm.geometry.notch
        VStack(spacing: 10) {
            HStack(spacing: 0) {
                TabDock(vm: vm).frame(maxWidth: .infinity, alignment: .leading)
                Color.clear.frame(width: notch.width)
                HStack {
                    Spacer()
                    IconButton("gearshape.fill") { (NSApp.delegate as? AppDelegate)?.openSettings() }
                }
                .frame(maxWidth: .infinity)
            }
            .frame(height: notch.height)

            Group {
                switch vm.tab {
                case .home: HomeTab(media: vm.media, calendar: vm.calendar)
                case .shelf: ShelfTab(shelf: vm.shelf, isTargeted: vm.isDropTargeted)
                case .scratch: ScratchTab()
                case .timers: TimersTab(timers: vm.timers)
                case .calendar: CalendarTab(calendar: vm.calendar)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .padding(.horizontal, 14)
        .padding(.bottom, 14)
        .foregroundStyle(.white)
    }
}

struct TabDock: View {
    @ObservedObject var vm: NotchViewModel

    var body: some View {
        HStack(spacing: 4) {
            ForEach(vm.enabledTabs) { tab in
                Button {
                    withAnimation(.snappy(duration: 0.2)) { vm.tab = tab }
                } label: {
                    Image(systemName: tab.icon)
                        .font(.system(size: 12, weight: .semibold))
                        .frame(width: 30, height: 24)
                        .background(Capsule().fill(Color.white.opacity(vm.tab == tab ? 0.16 : 0)))
                        .foregroundStyle(vm.tab == tab ? .white : .secondary)
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .help(tab.title)
            }
        }
    }
}
