// by zayd/cold @ zayd.wtf

import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// Reads a speech model's compiled program back into memory before its first decode after idle.
///
/// Core ML keeps each model's compiled CPU program as a file in its compile cache
/// (`CompiledModelCache`). Fluid Speech Mini's encoder is one `bnns_program.bnnsir` of about
/// 1.2 GB. Core ML maps the file instead of copying it, so its pages are clean file pages: iOS
/// drops them while Zone idles in the background, and the next decode faults them back in on
/// demand, a few pages at a time. On the phone that cost about 3 s; the journal showed short
/// dictations after 15 s of idle taking 1,540 ms at the median against 237 ms otherwise.
///
/// Reading the same file with a few parallel `pread`s is an order of magnitude faster than
/// faulting it in (measured on the M4 Pro: 629 MB/s faulting from one thread, 5.8 GB/s with
/// four readers; `scripts/model-pagein-bench`, docs/research/2026-11-18-model-page-in.md). The
/// reads fill the file cache that the mapping shares, so the decode afterwards only maps pages.
///
/// The files are found by residency, not by name: right after the model's own decode, the
/// program files in memory are the ones that decode used (`Program.learn`). Core ML's cache
/// layout is private and has changed between OS versions (descriptors named the model's path on
/// some builds and a content hash on iOS 26.2 and macOS 26.1), so nothing here parses it.
public enum CompiledProgramReadahead {
    public struct Report: Equatable, Sendable {
        public var files = 0
        /// Size of every file asked for.
        public var bytes: Int64 = 0
        /// Bytes actually read: chunks already in memory are skipped.
        public var bytesRead: Int64 = 0
        public var seconds: Double = 0

        public init(files: Int = 0, bytes: Int64 = 0, bytesRead: Int64 = 0, seconds: Double = 0) {
            self.files = files
            self.bytes = bytes
            self.bytesRead = bytesRead
            self.seconds = seconds
        }
    }

    /// Smallest file worth reading ahead; smaller ones fault in quickly enough.
    public static let minimumBytes: Int64 = 1 << 20

    /// Regular files of at least `minimumBytes` under `cacheRoot/<osBuild>` (every build when nil),
    /// largest first. Symbolic links and unfinished compiles (`.tmp.` in the path) are skipped.
    public static func programFiles(cacheRoot: URL, osBuild: String?, minimumBytes: Int64 = minimumBytes,
                                    fileManager: FileManager = .default) -> [URL] {
        let roots: [URL]
        if let osBuild {
            roots = [cacheRoot.appendingPathComponent(osBuild, isDirectory: true)]
        } else {
            roots = (try? fileManager.contentsOfDirectory(at: cacheRoot, includingPropertiesForKeys: nil)) ?? []
        }
        var found: [(url: URL, bytes: Int)] = []
        let keys: [URLResourceKey] = [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]
        for root in roots {
            guard let walker = fileManager.enumerator(at: root, includingPropertiesForKeys: keys, options: []) else { continue }
            for case let url as URL in walker {
                guard !url.path.contains(".tmp."),
                      let values = try? url.resourceValues(forKeys: Set(keys)),
                      values.isSymbolicLink != true, values.isRegularFile == true,
                      let size = values.fileSize, Int64(size) >= minimumBytes else { continue }
                found.append((url, size))
            }
        }
        return found.sorted { $0.bytes != $1.bytes ? $0.bytes > $1.bytes : $0.url.path < $1.url.path }.map(\.url)
    }

    /// Fraction of each file's pages in memory now, 0...1, keyed by file; files that cannot be
    /// opened or mapped are left out.
    public static func residency(of files: [URL]) -> [URL: Double] {
        var result: [URL: Double] = [:]
        for url in files {
            guard let file = MappedFile(url) else { continue }
            defer { file.close() }
            let pages = file.pageCount
            var vector = [CChar](repeating: 0, count: pages)
            guard mincore(file.base, file.size, &vector) == 0 else { continue }
            let resident = vector.reduce(0) { $0 + (($1 & CChar(MINCORE_INCORE)) != 0 ? 1 : 0) }
            result[url] = Double(resident) / Double(max(pages, 1))
        }
        return result
    }

    /// Reads `files` into the file cache with `concurrency` workers taking `chunkBytes` chunks in
    /// turn. Chunks whose pages are all in memory already are skipped (`mincore`), so a warm model
    /// costs one residency scan. Blocks until done; never call it on the main thread.
    @discardableResult
    public static func read(_ files: [URL], chunkBytes: Int = 1 << 20, concurrency: Int = 4) -> Report {
        let began = ProcessInfo.processInfo.systemUptime
        let page = Int(vm_page_size)
        let step = max(chunkBytes / page, 1) * page
        let mapped = files.compactMap(MappedFile.init)
        defer { mapped.forEach { $0.close() } }
        var chunks: [(file: Int, offset: Int, length: Int)] = []
        for (index, file) in mapped.enumerated() {
            var offset = 0
            while offset < file.size {
                let length = min(step, file.size - offset)
                chunks.append((index, offset, length))
                offset += length
            }
        }
        let queue = WorkQueue(count: chunks.count)
        let workers = max(1, min(concurrency, chunks.count))
        DispatchQueue.concurrentPerform(iterations: workers) { _ in
            let buffer = UnsafeMutableRawPointer.allocate(byteCount: step, alignment: page)
            defer { buffer.deallocate() }
            var residency = [CChar](repeating: 0, count: step / page)
            while let index = queue.next() {
                let chunk = chunks[index]
                let file = mapped[chunk.file]
                let pages = (chunk.length + page - 1) / page
                if mincore(file.base + chunk.offset, chunk.length, &residency) == 0,
                   !residency[0..<pages].contains(where: { ($0 & CChar(MINCORE_INCORE)) == 0 }) {
                    continue
                }
                var done = 0
                while done < chunk.length {
                    let got = pread(file.fd, buffer + done, chunk.length - done, off_t(chunk.offset + done))
                    if got <= 0 { break }
                    done += got
                }
                queue.add(read: done)
            }
        }
        return Report(files: mapped.count, bytes: Int64(mapped.reduce(0) { $0 + $1.size }),
                      bytesRead: queue.bytesRead, seconds: ProcessInfo.processInfo.systemUptime - began)
    }

    /// One loaded model's program: which files it is, learned once its first decode has run, and
    /// the readahead before each warm-up. Thread-safe.
    public final class Program: @unchecked Sendable {
        /// A file this resident right after the model's decode belongs to the model. A just-used
        /// file is entirely resident; a file another model used long ago is mostly not.
        public static let inUseResidency = 0.9

        private let cacheRoot: URL?
        private let osBuild: String?
        private let lock = NSLock()
        private var known: [URL] = []

        /// `cacheRoot` is the app's `com.apple.e5rt.e5bundlecache`; nil turns the readahead off.
        public init(cacheRoot: URL?, osBuild: String?) {
            self.cacheRoot = cacheRoot
            self.osBuild = osBuild
        }

        public var files: [URL] { lock.withLock { known } }

        /// Call right after the model's own decode. Records the program files in memory now,
        /// leaving out `excluding` (the files of other models this process has loaded, which may
        /// still be resident after an engine switch). Returns the files learned.
        @discardableResult
        public func learn(excluding: Set<URL> = []) -> [URL] {
            guard let cacheRoot else { return [] }
            let candidates = CompiledProgramReadahead.programFiles(cacheRoot: cacheRoot, osBuild: osBuild)
                .filter { !excluding.contains($0) }
            let residency = CompiledProgramReadahead.residency(of: candidates)
            let inUse = candidates.filter { (residency[$0] ?? 0) >= Self.inUseResidency }
            lock.withLock { known = inUse }
            return inUse
        }

        /// Reads the learned files back into memory; nil before `learn` found any. Blocking.
        public func prefetch(concurrency: Int = 4) -> Report? {
            let files = self.files
            guard !files.isEmpty else { return nil }
            return CompiledProgramReadahead.read(files, concurrency: concurrency)
        }
    }

    /// A read-only mapping, for residency checks. Mapping reserves address space only.
    private final class MappedFile: @unchecked Sendable {
        let fd: Int32
        let size: Int
        let base: UnsafeMutableRawPointer

        init?(_ url: URL) {
            fd = open(url.path, O_RDONLY | O_CLOEXEC)
            guard fd >= 0 else { return nil }
            var info = stat()
            guard fstat(fd, &info) == 0, info.st_size > 0,
                  let pointer = mmap(nil, Int(info.st_size), PROT_READ, MAP_SHARED, fd, 0), pointer != MAP_FAILED else {
                Darwin.close(fd)
                return nil
            }
            size = Int(info.st_size)
            base = pointer
        }

        var pageCount: Int { (size + Int(vm_page_size) - 1) / Int(vm_page_size) }

        func close() {
            munmap(base, size)
            Darwin.close(fd)
        }
    }

    /// Hands out chunk indexes to the workers and totals what they read.
    private final class WorkQueue: @unchecked Sendable {
        private let lock = NSLock()
        private let count: Int
        private var position = 0
        private var read: Int64 = 0

        init(count: Int) { self.count = count }

        func next() -> Int? {
            lock.withLock {
                guard position < count else { return nil }
                defer { position += 1 }
                return position
            }
        }

        func add(read bytes: Int) { lock.withLock { read += Int64(bytes) } }
        var bytesRead: Int64 { lock.withLock { read } }
    }
}
