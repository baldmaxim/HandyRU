import SwiftUI

/// Кнопка удаления файла модели с подтверждением.
struct DeleteModelButton: View {
    let disabled: Bool
    let onDelete: () -> Void

    @State private var isConfirming = false

    var body: some View {
        Button("Удалить файл модели") {
            isConfirming = true
        }
        .foregroundStyle(.secondary)
        .disabled(disabled)
        .confirmationDialog(
            "Удалить файл модели? Потом его придётся скачивать заново",
            isPresented: $isConfirming,
            titleVisibility: .visible
        ) {
            Button("Удалить", role: .destructive) {
                onDelete()
            }
        }
    }
}
