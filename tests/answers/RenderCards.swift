import SwiftUI

/// Offscreen SwiftUI rendering only. No windows, NSApplication activation, launcher, hotkeys or input events.
@main struct RenderCards {
    @MainActor static func main() throws {
        let answers = [
            LauncherAnswer(expression: "200 + 12", leftBadge: "Sum", result: "212", rightBadge: "Two Hundred Twelve", copyValue: "212"),
            LauncherAnswer(expression: "time in spain", leftBadge: "Spain", result: "20:18", rightBadge: "GMT+2", copyValue: "20:18"),
            LauncherAnswer(expression: "1000$", leftBadge: "US Dollar", result: "9,819.62 MAD", rightBadge: "Moroccan Dirham", note: "Updated 1 minute ago", copyValue: "9819.62"),
            LauncherAnswer(section: "Color", expression: "#ff9f0a to rgb", leftBadge: "HEX", result: "rgb(255, 159, 10)", rightBadge: "RGB", copyValue: "rgb(255, 159, 10)", swatch: .init(red: 1, green: 159.0/255, blue: 10.0/255))
        ]
        let view = VStack(spacing: 8) {
            ForEach(Array(answers.enumerated()), id: \.offset) { _, answer in
                LauncherAnswerCard(answer: answer, selected: true, run: {})
            }
        }.padding(12).frame(width: 720).foregroundStyle(.white).background(.black).environment(\.colorScheme, .dark)
        let renderer = ImageRenderer(content: view); renderer.scale = 2
        guard let image = renderer.nsImage, let data = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: data), let png = bitmap.representation(using: .png, properties: [:]) else {
            throw NSError(domain: "AnswersSnapshot", code: 1)
        }
        try png.write(to: URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? "/tmp/nook-answer-cards.png"))
    }
}
