import SwiftUI

/// Шаг инструкции: цифра в кружке и текст.
struct InstructionStep: View {
    let number: String
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Text(number).font(.caption.bold()).frame(width: 22, height: 22)
                .background(Color("HandyAccent").opacity(0.15), in: Circle())
            Text(text).font(.subheadline).fixedSize(horizontal: false, vertical: true)
        }
    }
}
