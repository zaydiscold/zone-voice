// by zayd/cold @ zayd.wtf
import UIKit
import WebKit
import ZoneCore

/// A single recognition job owns its page and grants it access to one sealed WAV.
@MainActor final class KeyboardWebSpeech: NSObject, WKNavigationDelegate, WKURLSchemeHandler {
    private var page: WKWebView?
    private let audio: URL
    private let model: URL
    private let resources: Bundle
    private var pending: CheckedContinuation<KeyboardRecognitionResult, Error>?
    private var transfers: [ObjectIdentifier: FileHandle] = [:]

    init(audio: URL, model: URL, resources: Bundle = Bundle(for: KeyboardWebSpeech.self)) {
        self.audio = audio
        self.model = model
        self.resources = resources
    }

    private var submitted: (@Sendable () -> Void)?
    private var documentReady = false
    private var initializationFailed: Error?
    private(set) var modelReady = false
    private var warmAtStop = false

    /// Loading may overlap capture. The scheme handler grants audio access only at recognition.
    func prepare(in host: UIView) {
        guard page == nil, initializationFailed == nil else { return }
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        config.setURLSchemeHandler(self, forURLScheme: "zonevoice")
        let view = WKWebView(frame: CGRect(x: 0, y: 0, width: 2, height: 2), configuration: config)
        view.isUserInteractionEnabled = false
        view.accessibilityElementsHidden = true
        view.alpha = 0.01
        page = view
        view.navigationDelegate = self
        host.addSubview(view)
        view.load(URLRequest(url: URL(string: "zonevoice://local/index.html")!))
    }

    func recognize(in host: UIView, submitted: @escaping @Sendable () -> Void = {}) async throws -> KeyboardRecognitionResult {
        try Task.checkCancellation()
        if let initializationFailed { throw initializationFailed }
        self.submitted = submitted
        warmAtStop = modelReady
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                pending = continuation
                prepare(in: host)
                if documentReady, let page { run(in: page) }
            }
        } onCancel: { Task { @MainActor in self.cancel() } }
    }

    func cancel() {
        if page != nil || pending != nil { finish(.failure(CancellationError())) }
    }

    private func finish(_ result: Result<KeyboardRecognitionResult, Error>) {
        if case .failure(let error) = result { initializationFailed = error }
        let continuation = pending
        pending = nil
        submitted = nil
        page?.navigationDelegate = nil
        page?.stopLoading()
        page?.removeFromSuperview()
        page = nil
        for handle in transfers.values { try? handle.close() }
        transfers.removeAll()
        continuation?.resume(with: result)
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) { finish(.failure(URLError(.networkConnectionLost))) }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { finish(.failure(error)) }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { finish(.failure(error)) }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        documentReady = true
        if pending != nil {
            run(in: webView)
        } else {
            webView.callAsyncJavaScript("await (await import('/fluid-mini/fluid-mini.js')).warm(); return true",
                                        arguments: [:], in: nil, in: .page) { [weak self, weak webView] result in
                guard let self, let webView, self.page === webView else { return }
                switch result {
                case .success: self.modelReady = true
                case .failure(let error): self.finish(.failure(error))
                }
            }
        }
    }

    private func run(in webView: WKWebView) {
        webView.callAsyncJavaScript("return await (await import('/keyboard.mjs')).run()", arguments: [:], in: nil, in: .page) { [weak self] value in
            guard let self else { return }
            do {
                guard let result = try value.get() as? [String: Any], let text = result["text"] as? String,
                      let tokens = result["pieces"] as? [[String: Any]] else { throw CocoaError(.coderReadCorrupt) }
                let pieces = tokens.compactMap { token -> (piece: String, confidence: Float)? in
                    guard let word = token["piece"] as? String, let score = token["confidence"] as? NSNumber else { return nil }
                    return (word, score.floatValue)
                }
                let doubts = DoubtfulWords.candidates(DoubtfulWords.words(pieces: pieces))
                self.finish(.success(.init(text: SegmentText.cleaned(text), module: "fluidMiniWeb", doubts: doubts,
                                           fields: ["webModelReadyAtStop": String(self.warmAtStop)])))
            } catch { self.finish(.failure(error)) }
        }
    }

    func webView(_ webView: WKWebView, start task: WKURLSchemeTask) {
        guard let url = task.request.url, url.host == "local" else { return task.didFailWithError(URLError(.badURL)) }
        if url.path == "/index.html" {
            let data = Data("<!doctype html><meta charset=utf-8>".utf8)
            task.didReceive(URLResponse(url: url, mimeType: "text/html", expectedContentLength: data.count, textEncodingName: "utf-8"))
            task.didReceive(data)
            task.didFinish()
            return
        }
        let name = url.lastPathComponent
        let file: URL?
        switch url.path {
        case "/audio.wav": file = pending == nil ? nil : audio
        case "/fluid-mini/fluid-mini.js", "/keyboard.mjs", "/fluid-mini/ort.wasm.min.mjs", "/fluid-mini/ort-wasm-simd-threaded.mjs", "/fluid-mini/ort-wasm-simd-threaded.wasm":
            file = resources.resourceURL?.appendingPathComponent("KeyboardWebASR/" + name)
        default: file = url.path == "/fluid-mini/" + name && FluidWebModel.files[name] != nil ? model.appendingPathComponent(name) : nil
        }
        do {
            guard let file else { throw URLError(.resourceUnavailable) }
            let handle = try FileHandle(forReadingFrom: file)
            let size = try file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            let mime = ["js":"text/javascript", "mjs":"text/javascript", "wasm":"application/wasm", "wav":"audio/wav", "json":"application/json"][file.pathExtension] ?? "application/octet-stream"
            task.didReceive(HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1",
                                            headerFields: ["Content-Type": mime, "Content-Length": String(size), "Cache-Control": "no-store"])!)
            transfers[ObjectIdentifier(task)] = handle
            send(task)
        } catch { task.didFailWithError(error) }
    }

    private func send(_ task: WKURLSchemeTask) {
        let id = ObjectIdentifier(task)
        guard let handle = transfers[id] else { return }
        do {
            if let chunk = try handle.read(upToCount: 256 * 1024), !chunk.isEmpty {
                if task.request.url?.path == "/audio.wav" {
                    submitted?()
                    submitted = nil
                }
                task.didReceive(chunk)
                DispatchQueue.main.async { [weak self] in self?.send(task) }
                return
            }
            task.didFinish()
        } catch { task.didFailWithError(error) }
        try? transfers.removeValue(forKey: id)?.close()
    }
    func webView(_ webView: WKWebView, stop task: WKURLSchemeTask) {
        try? transfers.removeValue(forKey: ObjectIdentifier(task))?.close()
    }
}
