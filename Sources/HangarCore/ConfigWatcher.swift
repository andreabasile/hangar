import Foundation

/// Watches the config folder and file. Editors save either by renaming a new file over the old
/// one (the folder changes) or by rewriting in place (the file changes), so both are watched and
/// reopened after every event. Calls `onChange` after 0.3 s of quiet.
@MainActor
public final class ConfigWatcher {
    private let folder: URL
    private let file: URL
    private let onChange: @MainActor () -> Void
    private var sources: [any DispatchSourceFileSystemObject] = []
    private var quiet: Task<Void, Never>?

    public init(folder: URL, file: URL, onChange: @escaping @MainActor () -> Void) {
        self.folder = folder
        self.file = file
        self.onChange = onChange
        watch()
    }

    private func watch() {
        sources.forEach { $0.cancel() }
        sources = [folder, file].compactMap { source($0) }
    }

    private func source(_ url: URL) -> (any DispatchSourceFileSystemObject)? {
        let descriptor = open(url.path, O_EVTONLY)
        guard descriptor >= 0 else { return nil }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: descriptor,
                                                               eventMask: [.write, .extend, .delete, .rename], queue: .main)
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated { self?.changed() }
        }
        source.setCancelHandler { close(descriptor) }
        source.resume()
        return source
    }

    private func changed() {
        quiet?.cancel()
        quiet = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled, let self else { return }
            self.onChange()
            self.watch()
        }
    }
}
