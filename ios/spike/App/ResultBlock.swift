import SwiftUI
import UIKit

/// Распознанный текст и копирование. Технические показатели — в «Настройки и диагностика».
struct ResultBlock: View {
    let text: String
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if text.isEmpty {
                Text("Речи не слышно. Попробуйте записать фразу ещё раз.")
                    .foregroundStyle(.secondary)
            } else {
                Text(text)
                    .textSelection(.enabled)
                Button {
                    UIPasteboard.general.string = text
                    copied = true
                } label: {
                    Label(copied ? "Скопировано" : "Скопировать текст", systemImage: copied ? "checkmark" : "doc.on.doc")
                }
                .buttonStyle(SpikeActionStyle(kind: .primary))
            }
        }
        .onChange(of: text) { _, _ in copied = false }
    }
}
