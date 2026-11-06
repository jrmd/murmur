import CryptoKit
import Foundation

/// Downloads a model file to disk with progress, resume, cancellation and integrity checks.
///
/// Bytes are written to a `.part` file next to the destination, so an interrupted download resumes with an HTTP
/// `Range` request instead of starting over. The finished file is verified (optional SHA-256, then the GGUF magic)
/// and only then moved into place, so a truncated or corrupt file never appears at the destination.
public final class ModelDownloader: @unchecked Sendable {
    /// Called with the fraction of the file downloaded so far, from 0 to 1.
    public typealias ProgressHandler = @Sendable (Double) -> Void

    /// The `.part` file a download of `destination` is written to.
    public static func partURL(for destination: URL) -> URL { destination.appendingPathExtension("part") }

    private let fileManager: FileManager
    /// The size the caller expects, used for progress when the server sends no `Content-Length`.
    private let expectedBytes: Int64?
    private let delegate: DownloadDelegate
    private let session: URLSession

    /// `configuration` is injectable so tests can stub the network with a `URLProtocol`.
    public init(configuration: URLSessionConfiguration = .default, expectedBytes: Int64? = nil, fileManager: FileManager = .default) {
        let delegate = DownloadDelegate()
        self.fileManager = fileManager
        self.expectedBytes = expectedBytes
        self.delegate = delegate
        self.session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
    }

    /// Downloads `url` to `destination`, resuming a `.part` file left by an earlier attempt when the server allows it.
    /// Cancelling the calling task stops the transfer and keeps the `.part` file for the next attempt.
    /// - Parameter expectedSHA256: when set, the finished file must hash to this value or it is deleted and the
    ///   download fails.
    public func download(from url: URL, to destination: URL, expectedSHA256: String? = nil, progress: ProgressHandler? = nil) async throws {
        defer { session.finishTasksAndInvalidate() }
        try Task.checkCancellation()
        try fileManager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        let partURL = Self.partURL(for: destination)
        try await transfer(from: url, to: partURL, progress: progress, mayRestart: true)
        try verify(partURL, expectedSHA256: expectedSHA256, name: destination.lastPathComponent)
        if fileManager.fileExists(atPath: destination.path) { try fileManager.removeItem(at: destination) }
        try fileManager.moveItem(at: partURL, to: destination)
    }

    private func transfer(from url: URL, to partURL: URL, progress: ProgressHandler?, mayRestart: Bool) async throws {
        var offset = fileSize(partURL)
        var request = URLRequest(url: url)
        request.timeoutInterval = 60
        if offset > 0 { request.setValue("bytes=\(offset)-", forHTTPHeaderField: "Range") }
        let handle: FileHandle
        if offset > 0, let existing = try? FileHandle(forWritingTo: partURL) {
            handle = existing
            _ = try? handle.seekToEnd()
        } else {
            offset = 0
            try? fileManager.removeItem(at: partURL)
            fileManager.createFile(atPath: partURL.path, contents: nil)
            guard let created = try? FileHandle(forWritingTo: partURL) else { throw CoreError.message("Could not write to \(partURL.path).") }
            handle = created
        }
        defer { try? handle.close() }
        let download = Download(handle: handle, progress: progress, expectedBytes: expectedBytes, received: offset)
        download.report()
        let task = session.dataTask(with: request)
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                download.continuation = continuation
                delegate.register(download, for: task)
                task.resume()
            }
        } onCancel: {
            task.cancel()
        }
        if download.statusCode == 416, mayRestart {
            // The `.part` file is already as large as the file on the server, so start over from zero.
            try? fileManager.removeItem(at: partURL)
            return try await transfer(from: url, to: partURL, progress: progress, mayRestart: false)
        }
        if let total = download.total, download.received < total {
            throw CoreError.message("The download stopped before the whole file arrived. Try again to resume it.")
        }
    }

    private func verify(_ url: URL, expectedSHA256: String?, name: String) throws {
        if let expected = expectedSHA256?.lowercased(), !expected.isEmpty {
            guard let actual = try? Self.sha256(of: url), actual == expected else {
                try? fileManager.removeItem(at: url)
                throw CoreError.message("\(name) failed its integrity check, so it was deleted. Try downloading it again.")
            }
        }
        guard Self.isGGUF(url) else {
            try? fileManager.removeItem(at: url)
            throw CoreError.message("\(name) is not a GGUF model file.")
        }
    }

    /// Streams the file through SHA-256 in 1 MB chunks, so a 1 GB model never has to fit in memory.
    static func sha256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty { hasher.update(data: chunk) }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// GGUF files start with the ASCII magic "GGUF"; this catches an HTML error page saved in its place.
    static func isGGUF(_ url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        return (try? handle.read(upToCount: 4)) == Data("GGUF".utf8)
    }

    /// `URL.resourceValues` caches, which would report a stale size after the `.part` file is deleted.
    private func fileSize(_ url: URL) -> Int64 {
        guard let attributes = try? fileManager.attributesOfItem(atPath: url.path) else { return 0 }
        return (attributes[.size] as? NSNumber)?.int64Value ?? 0
    }
}

/// One in-flight transfer: the file it appends to, how far it has got, and the continuation waiting for it to end.
private final class Download: @unchecked Sendable {
    let handle: FileHandle
    let progress: ModelDownloader.ProgressHandler?
    let expectedBytes: Int64?
    var received: Int64
    var total: Int64?
    var statusCode: Int?
    var failure: Error?
    var continuation: CheckedContinuation<Void, Error>?

    init(handle: FileHandle, progress: ModelDownloader.ProgressHandler?, expectedBytes: Int64?, received: Int64) {
        self.handle = handle
        self.progress = progress
        self.expectedBytes = expectedBytes
        self.received = received
    }

    func report() {
        guard let progress, let total, total > 0 else { return }
        progress(min(max(Double(received) / Double(total), 0), 1))
    }
}

/// Writes the response body straight to the `.part` file, so a cancelled transfer keeps what it already received.
private final class DownloadDelegate: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var downloads: [Int: Download] = [:]

    func register(_ download: Download, for task: URLSessionTask) {
        lock.lock(); downloads[task.taskIdentifier] = download; lock.unlock()
    }
    private func download(for task: URLSessionTask) -> Download? {
        lock.lock(); defer { lock.unlock() }
        return downloads[task.taskIdentifier]
    }
    private func take(_ task: URLSessionTask) -> Download? {
        lock.lock(); defer { lock.unlock() }
        return downloads.removeValue(forKey: task.taskIdentifier)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse, completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard let download = download(for: dataTask) else { return completionHandler(.cancel) }
        guard let http = response as? HTTPURLResponse else {
            download.failure = CoreError.message("The server sent an unexpected response.")
            return completionHandler(.cancel)
        }
        download.statusCode = http.statusCode
        switch http.statusCode {
        case 206:
            download.total = download.received + max(response.expectedContentLength, 0)
        case 200:
            // The server ignored the Range header, so the body is the whole file: start the `.part` file again.
            try? download.handle.truncate(atOffset: 0)
            try? download.handle.seek(toOffset: 0)
            download.received = 0
            download.total = response.expectedContentLength > 0 ? response.expectedContentLength : download.expectedBytes
        case 416:
            break // the caller restarts from zero
        case 200..<300:
            download.total = response.expectedContentLength > 0 ? response.expectedContentLength : download.expectedBytes
        default:
            download.failure = CoreError.message("The server returned an error (\(http.statusCode)).")
            return completionHandler(.cancel)
        }
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard let download = download(for: dataTask) else { return }
        do { try download.handle.write(contentsOf: data) } catch {
            download.failure = CoreError.message("Could not write the download to disk.")
            return dataTask.cancel()
        }
        download.received += Int64(data.count)
        download.report()
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let download = take(task) else { return }
        if let failure = download.failure { download.continuation?.resume(throwing: failure) }
        else if let error {
            if (error as? URLError)?.code == .cancelled { download.continuation?.resume(throwing: CancellationError()) }
            else { download.continuation?.resume(throwing: error) }
        } else {
            download.continuation?.resume()
        }
    }
}
