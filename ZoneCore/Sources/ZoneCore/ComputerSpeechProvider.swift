// by zayd/cold @ zayd.wtf
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// OpenAI-compatible multipart audio API. A redirect must never forward someone's recording.
public enum ComputerSpeechProvider {
    // The keyboard has its own memory budget. URLSession calls this delegate on a serial queue.
    static let responseLimit = 1_048_576
    private final class ResponseReceiver: NSObject, URLSessionDataDelegate, @unchecked Sendable {
        private let result: AsyncThrowingStream<Data, Error>.Continuation
        private var body = Data()
        private var failure: URLError?

        init(result: AsyncThrowingStream<Data, Error>.Continuation) { self.result = result }

        func urlSession(_ session: URLSession, task: URLSessionTask,
                        willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                        completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }

        func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
            if (response as? HTTPURLResponse)?.statusCode != 200 { failure = URLError(.badServerResponse) }
            else if response.expectedContentLength > responseLimit { failure = URLError(.dataLengthExceedsMaximum) }
            completionHandler(failure == nil ? .allow : .cancel)
        }

        func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
            guard failure == nil else { return }
            guard data.count <= responseLimit - body.count else {
                failure = URLError(.dataLengthExceedsMaximum)
                dataTask.cancel()
                return
            }
            body.append(data)
        }

        func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
            if let error = failure ?? error { result.finish(throwing: error) }
            else { result.yield(body); result.finish() }
        }
    }
    public struct Transcript: Decodable, Sendable {
        public let text: String
        public let words: [Word]?
        public struct Word: Decodable, Sendable {
            public let word: String
            public let probability: Float?
        }
    }
    public static func recognize(_ audio: URL, using settings: KeyboardVoiceRoute, timeout: TimeInterval,
                                 submitted: @Sendable () -> Void = {}) async throws -> Transcript {
        try await recognize(audio, using: settings, timeout: timeout, configuration: .ephemeral, submitted: submitted)
    }

    static func recognize(_ audio: URL, using settings: KeyboardVoiceRoute, timeout: TimeInterval,
                          configuration config: URLSessionConfiguration, submitted: @Sendable () -> Void = {}) async throws -> Transcript {
        guard settings.mode == .computer, let url = settings.providerURL else { throw URLError(.badURL) }
        let size = try audio.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size > 0, size <= 25 * 1024 * 1024 else { throw CocoaError(.fileReadTooLarge) }
        let boundary = "zone-" + UUID().uuidString
        let form = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: form) }
        let header = "--\(boundary)\r\nContent-Disposition: form-data; name=\"model\"\r\n\r\n\(settings.model)\r\n--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"dictation.wav\"\r\nContent-Type: audio/wav\r\n\r\n"
        try Data(header.utf8).write(to: form, options: .completeFileProtection)
        let input = try FileHandle(forReadingFrom: audio), output = try FileHandle(forWritingTo: form)
        defer { try? input.close(); try? output.close() }
        try output.seekToEnd()
        while let block = try input.read(upToCount: 256 * 1024), !block.isEmpty {
            try Task.checkCancellation()
            try output.write(contentsOf: block)
        }
        try output.write(contentsOf: Data("\r\n--\(boundary)--\r\n".utf8))
        try output.close()
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.httpMethod = "POST"
        request.setValue("multipart/form-data; boundary=" + boundary, forHTTPHeaderField: "Content-Type")
        if !settings.token.isEmpty { request.setValue("Bearer " + settings.token, forHTTPHeaderField: "Authorization") }
        config.httpShouldSetCookies = false
        config.urlCredentialStorage = nil
        config.urlCache = nil
        let (stream, continuation) = AsyncThrowingStream<Data, Error>.makeStream()
        let session = URLSession(configuration: config, delegate: ResponseReceiver(result: continuation), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let task = session.uploadTask(with: request, fromFile: form)
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            submitted()
            task.resume()
            for try await data in stream {
                try Task.checkCancellation()
                return try JSONDecoder().decode(Transcript.self, from: data)
            }
            throw CancellationError()
        } onCancel: { task.cancel() }
    }
}
