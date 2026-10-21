import SwiftUI

struct LauncherAnswerCard: View {
    let answer: LauncherAnswer
    let selected: Bool
    let run: () -> Void
    private let dimmed: Set<String> = ["+", "-", "−", "×", "÷", "*", "/", "^", "in", "to", "of", "from", "plus", "minus", "times", "divided", "by", "between", "and", "until"]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(answer.section).font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
                .padding(.horizontal, 10).frame(height: 24)
            Button(action: run) {
                HStack(spacing: 28) {
                    half(expression, badge: answer.leftBadge)
                    half(Text(answer.result), badge: answer.rightBadge, swatch: answer.swatch)
                }
                .padding(.horizontal, 24).frame(height: 124)
                .frame(maxWidth: .infinity)
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.white.opacity(selected ? 0.16 : 0.08)))
                .overlay {
                    VStack(spacing: 0) {
                        Rectangle().fill(Color.white.opacity(0.1)).frame(width: 1)
                        Color.clear.frame(height: answer.note == nil ? 38 : 64)
                        Rectangle().fill(Color.white.opacity(0.1)).frame(width: 1)
                    }
                    Image(systemName: "arrow.right").font(.system(size: 13, weight: .medium)).foregroundStyle(.white.opacity(0.8))
                    if let note = answer.note {
                        Text(note).font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary)
                            .lineLimit(2).multilineTextAlignment(.center).frame(width: 180).offset(y: 25)
                    }
                }
                .contentShape(RoundedRectangle(cornerRadius: 12))
            }
            .buttonStyle(.plain).focusEffectDisabled()
            .accessibilityLabel("\(answer.expression), \(answer.result), \(answer.rightBadge)\(answer.note.map { ", " + $0 } ?? "")")
            .accessibilityHint(answer.isAvailable ? "Return copies the result. Command Return pastes. Command K opens actions." : "Exchange rates are unavailable. Command K opens the rate provider.")
            .accessibilityAddTraits(selected ? .isSelected : [])
        }.padding(.horizontal, 8).padding(.bottom, 8)
    }
    private var expression: Text {
        let words = answer.expression.components(separatedBy: " ")
        return words.enumerated().reduce(Text("")) { text, item in
            text + Text((item.offset == 0 ? "" : " ") + item.element)
                .foregroundColor(.white.opacity(dimmed.contains(item.element.lowercased()) ? 0.45 : 1))
        }
    }
    private func half(_ text: Text, badge: String, swatch: LauncherAnswer.Swatch? = nil) -> some View {
        VStack(spacing: 22) {
            HStack(spacing: 8) {
                if let swatch {
                    RoundedRectangle(cornerRadius: 5).fill(Color(red: swatch.red, green: swatch.green, blue: swatch.blue))
                        .frame(width: 24, height: 24).accessibilityLabel("Color preview")
                }
                text.font(.system(size: 25, weight: .semibold)).lineLimit(1).minimumScaleFactor(0.45)
            }.frame(maxWidth: .infinity)
            Text(badge).font(.system(size: 10, weight: .semibold)).lineLimit(1)
                .padding(.horizontal, 8).padding(.vertical, 4)
                .background(RoundedRectangle(cornerRadius: 5).fill(Color.white.opacity(0.1)))
        }.frame(maxWidth: .infinity)
    }
}

struct LauncherAnswerActions: View {
    let answer: LauncherAnswer
    let selectedIndex: Int
    let run: (LauncherAnswer.Action) -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(answer.result).font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary).lineLimit(1).padding(6)
            ForEach(Array(answer.actions.enumerated()), id: \.offset) { index, action in
                Button { run(action) } label: {
                    HStack { Text(action.title); Spacer(); if selectedIndex == index { Text("↩").foregroundStyle(.secondary) } }
                        .font(.system(size: 12)).padding(8)
                        .background(RoundedRectangle(cornerRadius: 7).fill(Color.white.opacity(selectedIndex == index ? 0.12 : 0)))
                }.buttonStyle(.plain).focusEffectDisabled()
            }
        }.padding(6).frame(width: 260)
            .background(RoundedRectangle(cornerRadius: 12).fill(Color(white: 0.12)))
            .padding(10).accessibilityElement(children: .contain).accessibilityLabel("Answer actions")
    }
}
