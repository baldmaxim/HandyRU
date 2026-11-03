import Foundation

/// Производные состояния модели, общие для нескольких секций экрана.
/// Секции хранят `controller` и `store` как `@ObservedObject` и сами обновляются при изменениях.
@MainActor
struct ModelState {
    let controller: SpikeController
    let store: ModelStore

    /// Файлы выбранной модели лежат на iPhone.
    var isDownloaded: Bool {
        if controller.selectedBackend.isCoreML { return store.coreMLDownloaded }
        guard let model = controller.selectedModel else { return false }
        return store.isDownloaded(model)
    }

    /// Выбранная модель загружена в память.
    var isLoaded: Bool { controller.selectedModelIsLoaded }

    /// Загрузка или выгрузка модели идёт прямо сейчас.
    var isPreparing: Bool { controller.phase == .loading || controller.phase == .unloading }

    /// Модель готова к работе: загружена и не перезагружается.
    var isReady: Bool { isLoaded && !isPreparing }

    var isDownloading: Bool { store.downloadingID != nil }

    var actionsDisabled: Bool {
        controller.isBusy || controller.backgroundDictationEnabled || isDownloading
    }

    var canRecord: Bool {
        isLoaded && !controller.isBusy && !isDownloading
    }

    var sizeMB: Int {
        controller.selectedBackend.isCoreML ? ModelStore.coreMLSizeMB : (controller.selectedModel?.sizeMB ?? 0)
    }
}
