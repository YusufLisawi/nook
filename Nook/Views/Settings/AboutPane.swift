import SwiftUI

struct AboutPane: View {
    var body: some View {
        Form {
            Section {
                HStack(spacing: 18) {
                    Image(nsImage: NSImage(named: "AppIcon") ?? NSWorkspace.shared.icon(forFile: Bundle.main.bundlePath))
                        .resizable().scaledToFit().frame(width: 80, height: 80)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 5) {
                        Text("Nook").font(.largeTitle.weight(.semibold))
                        Text("Version \(NookVersion.description)").foregroundStyle(.secondary)
                            .textSelection(.enabled)
                        Text("A quiet home in your Mac’s notch.").font(.callout).foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 10)
                SettingsCheckForUpdatesButton()
            }
            Section("Learn More") {
                Link("Nook Website", destination: URL(string: "https://nook.motkan.com")!)
                Link("Source Code on GitHub", destination: URL(string: "https://github.com/YusufLisawi/nook")!)
                Link("Report an Issue", destination: URL(string: "https://github.com/YusufLisawi/nook/issues")!)
            }
            Section {
                LabeledContent("License", value: "MIT")
                Text("Copyright © 2026 Youssef El Aissaoui").font(.callout).foregroundStyle(.secondary)
                DisclosureGroup("View License") {
                    Text(Self.license).font(.callout).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                        .padding(.vertical, 8)
                }
            } header: {
                Text("Open Source")
            } footer: {
                Text("Made for macOS. Built with SwiftUI, AppKit, and web plugins.")
            }
        }
        .formStyle(.grouped)
    }

    private static let license = """
    MIT License

    Copyright (c) 2026 Youssef El Aissaoui

    Permission is hereby granted, free of charge, to any person obtaining a copy
    of this software and associated documentation files (the "Software"), to deal
    in the Software without restriction, including without limitation the rights
    to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
    copies of the Software, and to permit persons to whom the Software is
    furnished to do so, subject to the following conditions:

    The above copyright notice and this permission notice shall be included in all
    copies or substantial portions of the Software.

    THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
    IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
    FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
    AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
    LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
    OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
    SOFTWARE.
    """
}
