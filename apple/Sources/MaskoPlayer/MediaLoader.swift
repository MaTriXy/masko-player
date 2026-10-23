import CoreGraphics
import Foundation
import ImageIO

/// Gets a local copy of a clip, sound or still. `key` names what the file is
/// (an edge and its size, a pose's still), so a file fetched once keeps
/// playing after its signed link is refreshed.
@MainActor
protocol MediaLoader: AnyObject {
    func file(_ url: URL, key: String, done: @escaping @MainActor (URL?) -> Void)
    func image(_ url: URL, key: String, done: @escaping @MainActor (CGImage?) -> Void)
}

/// Downloads files into a temporary folder and keeps the most recent few
/// (the preload cache of player.md). Local files are used where they are.
@MainActor
final class FileCache: MediaLoader {
    private let session: URLSession
    private let folder: URL
    private let capacity: Int
    /// Keys from least to most recently used.
    private var order: [String] = []
    private var files: [String: URL] = [:]
    private var images: [String: CGImage] = [:]
    private var waiting: [String: [@MainActor (URL?) -> Void]] = [:]
    private var closed = false

    init(session: URLSession = .shared, capacity: Int = 16) {
        self.session = session
        self.capacity = capacity
        folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("MaskoPlayer", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: folder)
    }

    func file(_ url: URL, key: String, done: @escaping @MainActor (URL?) -> Void) {
        if url.isFileURL {
            done(FileManager.default.fileExists(atPath: url.path) ? url : nil)
            return
        }
        if let local = files[key] {
            touch(key)
            done(local)
            return
        }
        if waiting[key] != nil {
            waiting[key]?.append(done)
            return
        }
        waiting[key] = [done]
        let destination = folder.appendingPathComponent(UUID().uuidString + "-" + url.lastPathComponent)
        let folder = self.folder
        let task = session.downloadTask(with: url) { temporary, response, _ in
            var saved: URL?
            let status = (response as? HTTPURLResponse)?.statusCode ?? 200
            if let temporary, (200..<300).contains(status) {
                do {
                    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                    try FileManager.default.moveItem(at: temporary, to: destination)
                    saved = destination
                } catch {
                    saved = nil
                }
            }
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self.finish(key, saved) }
            }
        }
        task.resume()
    }

    private func finish(_ key: String, _ file: URL?) {
        if closed {
            if let file { try? FileManager.default.removeItem(at: file) }
            return
        }
        if let file {
            files[key] = file
            touch(key)
            evict()
        }
        let callbacks = waiting.removeValue(forKey: key) ?? []
        callbacks.forEach { $0(file) }
    }

    func image(_ url: URL, key: String, done: @escaping @MainActor (CGImage?) -> Void) {
        if let image = images[key] {
            done(image)
            return
        }
        file(url, key: key) { [weak self] local in
            guard let local else { return done(nil) }
            DispatchQueue.global(qos: .userInitiated).async {
                let image = CGImageSourceCreateWithURL(local as CFURL, nil)
                    .flatMap { CGImageSourceCreateImageAtIndex($0, 0, nil) }
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        if let image { self?.images[key] = image }
                        done(image)
                    }
                }
            }
        }
    }

    private func touch(_ key: String) {
        order.removeAll { $0 == key }
        order.append(key)
    }

    private func evict() {
        while order.count > capacity {
            let key = order.removeFirst()
            if let file = files.removeValue(forKey: key) {
                try? FileManager.default.removeItem(at: file)
            }
        }
    }

    /// Deletes every downloaded file.
    func clear() {
        closed = true
        waiting = [:]
        files = [:]
        order = []
        images = [:]
        try? FileManager.default.removeItem(at: folder)
    }
}
