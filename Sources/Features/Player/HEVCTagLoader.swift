import Foundation
import AVFoundation

/// Serves an MP4 to AVPlayer with its `hev1` sample entries renamed to `hvc1`,
/// through a resource loader rather than the local relay.
///
/// The relay reads every response whole before answering, which is fine for a
/// playlist or a segment and ruinous for a feature-length file. Here each byte
/// range AVPlayer asks for is streamed straight from the source — the network
/// with the captured headers, or the file on disk — and the few patched bytes
/// are rewritten as they pass. Seeking works because every request is ranged.
final class HEVCTagLoader: NSObject, AVAssetResourceLoaderDelegate, URLSessionDataDelegate {
    struct Source {
        var url: URL
        var headers: [String: String]
        var isLocal: Bool
        var length: Int64
        /// UTI for the content information request.
        var contentType: String
        var patches: [HEVCTagPatcher.Patch]
    }

    private static let scheme = "panura-hevc"

    private let source: Source
    private let queue = DispatchQueue(label: "panura.hevc-loader")
    private lazy var session: URLSession = {
        let operations = OperationQueue()
        operations.underlyingQueue = queue
        operations.maxConcurrentOperationCount = 1
        return URLSession(configuration: .default, delegate: self, delegateQueue: operations)
    }()

    private final class Running {
        let request: AVAssetResourceLoadingRequest
        let task: URLSessionDataTask
        var offset: Int64
        init(request: AVAssetResourceLoadingRequest, task: URLSessionDataTask, offset: Int64) {
            self.request = request
            self.task = task
            self.offset = offset
        }
    }

    /// Touched only on `queue`, which the loader and the session both use.
    private var running: [Int: Running] = [:]

    init(source: Source) {
        self.source = source
    }

    /// An asset whose every read comes through this loader. The loader must
    /// outlive it — the resource loader holds its delegate weakly.
    func makeAsset() -> AVURLAsset {
        var components = URLComponents(url: source.url, resolvingAgainstBaseURL: false)
        components?.scheme = Self.scheme
        let asset = AVURLAsset(url: components?.url ?? source.url)
        asset.resourceLoader.setDelegate(self, queue: queue)
        return asset
    }

    /// Ends every transfer and breaks the session's hold on this object.
    func invalidate() {
        queue.async { [self] in
            for entry in running.values { entry.task.cancel() }
            running.removeAll()
            session.invalidateAndCancel()
        }
    }

    // MARK: AVAssetResourceLoaderDelegate

    func resourceLoader(
        _ resourceLoader: AVAssetResourceLoader,
        shouldWaitForLoadingOfRequestedResource loadingRequest: AVAssetResourceLoadingRequest
    ) -> Bool {
        if let info = loadingRequest.contentInformationRequest {
            info.contentType = source.contentType
            info.contentLength = source.length
            info.isByteRangeAccessSupported = true
        }
        guard let dataRequest = loadingRequest.dataRequest else {
            loadingRequest.finishLoading()
            return true
        }
        let start = dataRequest.requestedOffset
        let end = dataRequest.requestsAllDataToEndOfResource
            ? source.length
            : min(source.length, start + Int64(dataRequest.requestedLength))
        guard start < end else {
            loadingRequest.finishLoading()
            return true
        }
        if source.isLocal {
            serveFile(loadingRequest, from: start, to: end)
        } else {
            serveNetwork(loadingRequest, from: start, to: end)
        }
        return true
    }

    func resourceLoader(_ resourceLoader: AVAssetResourceLoader, didCancel loadingRequest: AVAssetResourceLoadingRequest) {
        for (id, entry) in running where entry.request === loadingRequest {
            entry.task.cancel()
            running[id] = nil
        }
    }

    // MARK: sources

    private func serveNetwork(_ loadingRequest: AVAssetResourceLoadingRequest, from start: Int64, to end: Int64) {
        var request = URLRequest(url: source.url)
        for (key, value) in source.headers { request.setValue(value, forHTTPHeaderField: key) }
        request.setValue("bytes=\(start)-\(end - 1)", forHTTPHeaderField: "Range")
        let task = session.dataTask(with: request)
        running[task.taskIdentifier] = Running(request: loadingRequest, task: task, offset: start)
        task.resume()
    }

    /// Off the loader's queue: an open-ended read of a large file would
    /// otherwise hold up every other request, cancellations included.
    private func serveFile(_ loadingRequest: AVAssetResourceLoadingRequest, from start: Int64, to end: Int64) {
        let url = source.url
        let patches = source.patches
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let handle = try FileHandle(forReadingFrom: url)
                defer { try? handle.close() }
                try handle.seek(toOffset: UInt64(start))
                var offset = start
                while offset < end, !loadingRequest.isCancelled {
                    let count = Int(min(1 << 20, end - offset))
                    guard var chunk = try handle.read(upToCount: count), !chunk.isEmpty else { break }
                    HEVCTagPatcher.apply(patches, to: &chunk, at: offset)
                    loadingRequest.dataRequest?.respond(with: chunk)
                    offset += Int64(chunk.count)
                }
                if !loadingRequest.isCancelled { loadingRequest.finishLoading() }
            } catch {
                if !loadingRequest.isCancelled { loadingRequest.finishLoading(with: error) }
            }
        }
    }

    // MARK: URLSessionDataDelegate

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        guard let entry = running[dataTask.taskIdentifier] else {
            completionHandler(.cancel)
            return
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        // A server that ignores Range answers 200 from byte 0, which is only the
        // right data when byte 0 is what was asked for.
        if status == 206 || (status == 200 && entry.offset == 0) {
            completionHandler(.allow)
        } else {
            running[dataTask.taskIdentifier] = nil
            entry.request.finishLoading(with: URLError(.badServerResponse))
            completionHandler(.cancel)
        }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard let entry = running[dataTask.taskIdentifier] else { return }
        var chunk = data
        HEVCTagPatcher.apply(source.patches, to: &chunk, at: entry.offset)
        entry.offset += Int64(chunk.count)
        entry.request.dataRequest?.respond(with: chunk)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let entry = running.removeValue(forKey: task.taskIdentifier) else { return }
        if let error {
            entry.request.finishLoading(with: error)
        } else {
            entry.request.finishLoading()
        }
    }
}
