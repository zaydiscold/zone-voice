// by zayd/cold @ zayd.wtf

import Foundation
import ImageIO
import UniformTypeIdentifiers

public struct ClipboardImage: Sendable {
    private static let preparation = DispatchQueue(label: "Zone.clipboard.image", qos: .userInitiated)

    public let data: Data
    public let thumbnail: Data
    public let type: String

    /// Read through ImageIO from the provider file. Never create a full-size bitmap.
    public init?(url: URL) {
        let options = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithURL(url as CFURL, options),
              let identifier = CGImageSourceGetType(source) as String?,
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = props[kCGImagePropertyPixelWidth] as? Int,
              let height = props[kCGImagePropertyPixelHeight] as? Int,
              let bytes = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
              width > 0, height > 0, width <= 32_768, height <= 32_768,
              width * height <= 120_000_000, bytes <= 64 * 1024 * 1024,
              let preview = Self.jpeg(source, longestSide: 128) else { return nil }
        thumbnail = preview
        if bytes <= 2_097_152, max(width, height) <= 2048,
           [UTType.jpeg.identifier, UTType.png.identifier, UTType.heic.identifier].contains(identifier),
           let original = try? Data(contentsOf: url, options: .uncached) {
            data = original
            type = identifier
        } else {
            guard let reduced = Self.jpeg(source, longestSide: 1536), reduced.count <= 2_097_152 else { return nil }
            data = reduced
            type = UTType.jpeg.identifier
        }
    }

    private static func jpeg(_ source: CGImageSource, longestSide: Int) -> Data? {
        let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                        kCGImageSourceCreateThumbnailWithTransform: true,
                                        kCGImageSourceThumbnailMaxPixelSize: longestSide,
                                        kCGImageSourceShouldCache: false]
        guard let bitmap = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        let buffer = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(buffer, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, bitmap, [kCGImageDestinationLossyCompressionQuality: 0.78] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return buffer as Data
    }
}

#if os(iOS)
import UIKit
import SwiftUI

/// ImageIO finishes decoding on a worker before SwiftUI receives the pixels.
public struct SavedClipboardImage: View {
    private let url: URL?
    @State private var bitmap: CGImage?

    public init(url: URL?) { self.url = url }

    public var body: some View {
        Group {
            if let bitmap {
                Image(bitmap, scale: 1, label: Text("Saved image")).resizable().scaledToFit()
            } else {
                Color.clear
            }
        }
        .task(id: url) {
            bitmap = nil
            guard let url else { return }
            let result = await Task.detached(priority: .utility) {
                guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil as CGImage? }
                let options = [kCGImageSourceShouldCacheImmediately: true] as CFDictionary
                return CGImageSourceCreateImageAtIndex(source, 0, options)
            }.value
            if !Task.isCancelled { bitmap = result }
        }
    }
}

public enum ClipboardPasteText {
    public static let acceptedTypes = [UTType.plainText.identifier, UTType.url.identifier, UTType.rtf.identifier, UTType.image.identifier]

    public static func supports(_ provider: NSItemProvider) -> Bool {
        provider.canLoadObject(ofClass: String.self) || provider.canLoadObject(ofClass: URL.self)
            || provider.hasItemConformingToTypeIdentifier(UTType.rtf.identifier)
    }

    /// A copied selection may include a separate source URL or rich link preview.
    public static func preferred(in providers: [NSItemProvider]) -> NSItemProvider? {
        providers.first { $0.hasItemConformingToTypeIdentifier(UTType.rtf.identifier) }
            ?? providers.first { $0.hasItemConformingToTypeIdentifier(UTType.plainText.identifier)
            && !$0.hasItemConformingToTypeIdentifier(UTType.url.identifier) && $0.canLoadObject(ofClass: String.self) }
            ?? providers.first(where: supports)
    }

    // UIKit supplies these providers fully registered. We only load from them, and the next
    // representation starts after the previous provider's completion. No mutable cursor is shared.
    private enum Representation: @unchecked Sendable {
        case richText(NSItemProvider), string(NSItemProvider), url(NSItemProvider), image(NSItemProvider, String)
    }

    public static func load(from providers: [NSItemProvider], then: @escaping @Sendable (String?) -> Void) {
        loadCopy(from: providers, includeImages: false) { value in
            if case .text(let text) = value { then(text) } else { then(nil) }
        }
    }

    public static func load(_ provider: NSItemProvider, then: @escaping @Sendable (String?) -> Void) {
        load(from: [provider], then: then)
    }

    /// Exhaust selected text across items before links, then try each allowed image representation.
    public static func loadCopy(from providers: [NSItemProvider], includeImages: Bool,
                                allowed: @escaping @Sendable () -> Bool = { true },
                                then: @escaping @Sendable (AutomaticClipboardValue?) -> Void) {
        guard allowed() else { then(nil); return }
        let rich = providers.filter { $0.hasItemConformingToTypeIdentifier(UTType.rtf.identifier) }
        let strings = providers.filter { $0.canLoadObject(ofClass: String.self) }
        let links = providers.filter { $0.canLoadObject(ofClass: URL.self) }
        let orderedStrings = strings.filter { !$0.canLoadObject(ofClass: URL.self) }
            + strings.filter { $0.canLoadObject(ofClass: URL.self) }
        let images: [Representation] = includeImages ? providers.flatMap { provider in
            provider.registeredTypeIdentifiers.compactMap { type in
                UTType(type)?.conforms(to: .image) == true ? .image(provider, type) : nil
            }
        } : []
        let candidates = rich.map(Representation.richText) + orderedStrings.map(Representation.string)
            + links.map(Representation.url) + images

        @Sendable func attempt(_ index: Int) {
            guard allowed(), candidates.indices.contains(index) else { then(nil); return }
            let receive: @Sendable (AutomaticClipboardValue?) -> Void = { value in
                guard allowed() else { then(nil); return }
                if let value { then(value) } else { attempt(index + 1) }
            }
            let words: @Sendable (String?) -> Void = { text in
                if let text, !text.isEmpty { receive(.text(text)) } else { receive(nil) }
            }
            switch candidates[index] {
            case .richText(let provider):
                provider.loadDataRepresentation(forTypeIdentifier: UTType.rtf.identifier) { data, _ in
                    words(data.flatMap { try? NSAttributedString(data: $0, options: [.documentType: NSAttributedString.DocumentType.rtf],
                                                                 documentAttributes: nil).string })
                }
            case .string(let provider):
                _ = provider.loadObject(ofClass: String.self) { text, _ in words(text) }
            case .url(let provider):
                _ = provider.loadObject(ofClass: URL.self) { url, _ in words(url?.absoluteString) }
            case .image(let provider, let type):
                ClipboardImage.load(from: provider, type: type) { receive($0.map(AutomaticClipboardValue.image)) }
            }
        }
        attempt(0)
    }
}

public extension ClipboardImage {
    static func load(from provider: NSItemProvider, then: @escaping @MainActor @Sendable (ClipboardImage?) -> Void) {
        guard let type = provider.registeredTypeIdentifiers.first(where: { UTType($0)?.conforms(to: .image) == true }) else { Task { @MainActor in then(nil) }; return }
        load(from: provider, type: type, then: then)
    }

    fileprivate static func load(from provider: NSItemProvider, type: String,
                                 then: @escaping @MainActor @Sendable (ClipboardImage?) -> Void) {
        provider.loadFileRepresentation(forTypeIdentifier: type) { url, _ in
            // Own the provider file before returning it to iOS. An async dispatch keeps
            // image preparation off the main thread even for a synchronous provider.
            let owned = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            do {
                guard let url, let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
                      size <= 64 * 1024 * 1024 else {
                    Task { @MainActor in then(nil) }
                    return
                }
                try FileManager.default.copyItem(at: url, to: owned)
                try FileManager.default.setAttributes([.protectionKey: FileProtectionType.complete], ofItemAtPath: owned.path)
            } catch {
                try? FileManager.default.removeItem(at: owned)
                Task { @MainActor in then(nil) }
                return
            }
            preparation.async {
                let image = autoreleasepool { ClipboardImage(url: owned) }
                try? FileManager.default.removeItem(at: owned)
                Task { @MainActor in then(image) }
            }
        }
    }
}

public extension ClipboardHistory {
    @MainActor func copyImage(_ entry: ClipboardEntry) -> Bool {
        guard let type = entry.imageType, let data = try? Data(contentsOf: imageURL(entry.id)) else { return false }
        UIPasteboard.general.setItems([[type: data, ClipboardPolicy.ownType: Data()]], options: [.localOnly: true])
        return true
    }
}
#endif
