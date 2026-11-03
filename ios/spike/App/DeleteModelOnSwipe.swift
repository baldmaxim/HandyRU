import SwiftUI

/// Удаление доступно только после свайпа влево по строке модели.
struct DeleteModelOnSwipe: ViewModifier {
    let disabled: Bool
    let onDelete: () -> Void

    @State private var isConfirming = false

    func body(content: Content) -> some View {
        content
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            if !disabled {
                // Destructive-роль здесь заставляет List убирать строку до подтверждения.
                // Красный цвет задаём явно, роль destructive остаётся у действия в диалоге.
                Button {
                    isConfirming = true
                } label: {
                    Label("Удалить", systemImage: "trash")
                }
                .tint(.red)
            }
        }
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
