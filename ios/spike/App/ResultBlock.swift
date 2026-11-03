import SwiftUI
import UIKit

/// Сначала текст и копирование; технические показатели доступны по раскрытию.
struct ResultBlock: View {
    let result: SpikeController.RunResult
    let text: String
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(text.isEmpty ? "Речь не распознана. Попробуйте записать фразу ещё раз." : text)
                .textSelection(.enabled)
            if !text.isEmpty {
                Button {
                    UIPasteboard.general.string = text
                    copied = true
                } label: {
                    Label(copied ? "Скопировано" : "Скопировать текст", systemImage: copied ? "checkmark" : "doc.on.doc")
                }
                .buttonStyle(SpikeActionStyle())
                Text(copied ? "В нужном приложении нажмите «Вставить»." : "Скопируйте текст, затем выберите «Вставить» в нужном приложении.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            DisclosureGroup("Замеры · \(SpikeFormat.seconds(result.seconds))") {
                VStack(alignment: .leading, spacing: 8) {
                    Text("RTF \(SpikeFormat.number(result.rtf)) · аудио \(SpikeFormat.seconds(result.audioSeconds))")
                    Text("\(result.modelTitle) · \(result.backendTitle) · \(result.modeTitle)")
                    DelayScale(seconds: result.seconds)
                }
                .font(.caption).foregroundStyle(.secondary)
            }
        }
        .onChange(of: text) { _, _ in copied = false }
    }
}
