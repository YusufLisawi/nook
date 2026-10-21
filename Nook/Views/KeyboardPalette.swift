import SwiftUI

/// The palette stays inside the current tab's canvas and never creates another window.
struct KeyboardPalette: View {
    @ObservedObject var vm: NotchViewModel
    @ObservedObject private var state: NotchKeyboardState
    @ObservedObject private var actions = KeyboardActions.shared
    @ObservedObject private var features = Features.shared
    @FocusState private var searching: Bool

    init(vm: NotchViewModel) {
        self.vm = vm
        _state = ObservedObject(wrappedValue: vm.keyboard)
    }

    var body: some View {
        if state.isPresented {
            VStack(spacing: 0) {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("Search tabs, commands and actions", text: $state.query)
                        .textFieldStyle(.plain).focused($searching)
                        .accessibilityLabel("Search Nook actions")
                    Text("esc").font(.system(size: 10)).foregroundStyle(.secondary)
                }
                .padding(10)
                Divider()
                let results = state.results
                let selectedID = state.selected?.id
                if results.isEmpty {
                    VStack(spacing: 4) {
                        Text("No matching actions").fontWeight(.medium)
                        Text("Try a tab or command name.").foregroundStyle(.secondary)
                    }.frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollViewReader { proxy in
                        ScrollView {
                            LazyVStack(spacing: 2) {
                                ForEach(results) { entry in
                                    Button {
                                        vm.keyboardRun?(entry, false)
                                    } label: {
                                        HStack(spacing: 10) {
                                            Image(systemName: entry.symbol).frame(width: 18)
                                            VStack(alignment: .leading, spacing: 2) {
                                                Text(entry.title).fontWeight(.medium).lineLimit(1)
                                                Text(entry.subtitle).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
                                            }
                                            Spacer(minLength: 4)
                                            Text(entry.shortcut).font(.system(size: 10)).foregroundStyle(.secondary)
                                        }
                                        .padding(.horizontal, 9).padding(.vertical, 6)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .background(RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(selectedID == entry.id ? 0.14 : 0)))
                                        .contentShape(Rectangle())
                                    }
                                    .buttonStyle(.plain)
                                    .accessibilityAddTraits(selectedID == entry.id ? .isSelected : [])
                                    .id(entry.id)
                                }
                            }.padding(4)
                        }
                        .scrollIndicators(.hidden)
                        .onChange(of: state.selected?.id) { _, id in
                            if let id { proxy.scrollTo(id, anchor: .center) }
                        }
                    }
                }
                Divider()
                HStack {
                    Text("↑↓ Navigate   ↩ Run   ⌘↩ Alternate")
                    Spacer()
                    Text("⌘K Actions")
                }
                .font(.system(size: 10)).foregroundStyle(.secondary).padding(.horizontal, 10).padding(.vertical, 6)
            }
            .font(.system(size: 12))
            .background(Color(white: 0.065))
            .onAppear {
                DispatchQueue.main.async {
                    searching = true
                    DispatchQueue.main.async { vm.contentDidAttach?() }
                }
            }
        }
    }
}
