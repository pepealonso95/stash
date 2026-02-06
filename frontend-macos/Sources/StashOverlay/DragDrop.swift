import Foundation
import SwiftUI
import UniformTypeIdentifiers

final class FileDropDelegate: DropDelegate {
    private let viewModel: OverlayViewModel

    init(viewModel: OverlayViewModel) {
        self.viewModel = viewModel
    }

    func validateDrop(info: DropInfo) -> Bool {
        info.hasItemsConforming(to: [UTType.fileURL, UTType.folder])
    }

    func dropEntered(info: DropInfo) {
        viewModel.isDragTarget = true
    }

    func dropExited(info: DropInfo) {
        viewModel.isDragTarget = false
    }

    func performDrop(info: DropInfo) -> Bool {
        viewModel.isDragTarget = false
        let providers = info.itemProviders(for: [UTType.fileURL, UTType.folder])
        guard !providers.isEmpty else { return false }

        let group = DispatchGroup()
        let lock = NSLock()
        var urls: [URL] = []

        for provider in providers {
            group.enter()
            loadURL(from: provider, typeIdentifiers: [UTType.fileURL.identifier, UTType.folder.identifier]) { url in
                defer { group.leave() }
                guard let url else { return }
                lock.lock()
                urls.append(url)
                lock.unlock()
            }
        }

        group.notify(queue: .main) { [weak viewModel] in
            guard let viewModel else { return }
            viewModel.handleDroppedFiles(urls)
        }

        return true
    }

    private func loadURL(from provider: NSItemProvider, typeIdentifiers: [String], completion: @escaping (URL?) -> Void) {
        func attempt(_ index: Int) {
            guard index < typeIdentifiers.count else {
                completion(nil)
                return
            }

            provider.loadItem(forTypeIdentifier: typeIdentifiers[index], options: nil) { item, _error in
                if let data = item as? Data, let url = URL(dataRepresentation: data, relativeTo: nil) {
                    completion(url)
                    return
                }
                if let url = item as? URL {
                    completion(url)
                    return
                }
                if let string = item as? String, let url = URL(string: string) {
                    completion(url)
                    return
                }
                attempt(index + 1)
            }
        }

        attempt(0)
    }
}
