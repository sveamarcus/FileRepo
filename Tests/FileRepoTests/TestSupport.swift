//===----------------------------------------------------------------------===//
//
// This source file is part of the FileRepo open source project
//
// Copyright (c) 2022 fltrWallet AG and the FileRepo project authors
// Licensed under Apache License v2.0
//
// See LICENSE for license information
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//
//
// Shared fixtures for the FileRepo test suite (Swift Testing).
//
// FileRepo is a fixed-record-size, height-indexed flat file used as a linear
// database for Bitcoin blockchain storage. These helpers build an isolated repo
// over a freshly created temp file, run a body that drives the repo through its
// (blocking-`wait`ed) EventLoopFuture API, and guarantee teardown — so every test
// runs against pristine, independent state even under Swift Testing's parallel
// execution.
//
import FileRepo
import Foundation
import NIOCore
import NIOPosix
import Testing

// MARK: - Concrete repo under test

/// A concrete `FileRepo` whose record payload is a UTF-8 null-terminated string,
/// with a configurable `recordSize`, logical `offset` (a starting block height)
/// and optional `fieldSelector` (the record sub-range that holds the indexed
/// field). This is the workhorse conformer exercised by the suite.
final class StringRepo: FileRepo {
    struct Model: Identifiable, Sendable, Equatable {
        let id: Int
        let value: String
    }

    let allocator: ByteBufferAllocator
    let nioFileHandle: NIOFileHandle
    let nonBlockingFileIO: NonBlockingFileIOClient
    let eventLoop: EventLoop
    let recordSize: Int
    let offset: Int
    let fieldSelector: ClosedRange<Int>?

    init(allocator: ByteBufferAllocator = .init(),
         nioFileHandle: NIOFileHandle,
         nonBlockingFileIO: NonBlockingFileIOClient,
         eventLoop: EventLoop,
         recordSize: Int,
         offset: Int = 0,
         fieldSelector: ClosedRange<Int>? = nil) {
        self.allocator = allocator
        self.nioFileHandle = nioFileHandle
        self.nonBlockingFileIO = nonBlockingFileIO
        self.eventLoop = eventLoop
        self.recordSize = recordSize
        self.offset = offset
        self.fieldSelector = fieldSelector
    }

    func fileDecode(id: Int, buffer: inout ByteBuffer) throws -> Model {
        var copy = buffer
        guard let string = copy.readNullTerminatedString() else {
            throw File.Error.readError(message: "Cannot read string", event: #function)
        }
        return .init(id: id, value: string)
    }

    func fileEncode(_ row: Model, buffer: inout ByteBuffer) throws {
        let capacity = self.fieldSelector?.count ?? self.recordSize
        // Reserve one byte for the NUL terminator.
        guard row.value.utf8.count < capacity else {
            throw File.Error.illegalArgument
        }
        buffer.writeNullTerminatedString(row.value)
    }
}

// MARK: - Fixture

/// Owns the NIO machinery and a temporary file for the lifetime of a single test.
/// Construct via the `withStringRepo`/`withRawStringRepo` helpers, which guarantee
/// `shutdown()` runs even when the test body throws.
final class FileRepoFixture {
    let eventLoopGroup: MultiThreadedEventLoopGroup
    let threadPool: NIOThreadPool
    let eventLoop: EventLoop
    let client: NonBlockingFileIOClient
    let path: String
    let fileHandle: NIOFileHandle

    /// Creates the temp file and writes `seed` bytes verbatim as its initial contents.
    init(seed: [UInt8]) throws {
        self.path = "/tmp/filerepo_test_\(UUID().uuidString)"
        self.eventLoopGroup = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        self.threadPool = NIOThreadPool(numberOfThreads: 2)
        self.threadPool.start()
        self.eventLoop = self.eventLoopGroup.next()
        self.client = NonBlockingFileIOClient.live(self.threadPool)

        let handle = try NIOFileHandle(path: self.path,
                                       mode: [.read, .write],
                                       flags: .allowFileCreation(posixMode: 0o600))
        self.fileHandle = handle

        if !seed.isEmpty {
            var buffer = ByteBufferAllocator().buffer(capacity: seed.count)
            buffer.writeBytes(seed)
            try self.client.write(fileHandle: handle, toOffset: 0, buffer: buffer, eventLoop: self.eventLoop).wait()
        }
    }

    func shutdown() {
        // Close the repo's file handle (ignore double-close), remove the temp file,
        // and tear down the NIO machinery. Failures here are cleanup noise, not test
        // signal, so they are swallowed deliberately.
        try? self.fileHandle.close()
        try? FileManager.default.removeItem(atPath: self.path)
        try? self.threadPool.syncShutdownGracefully()
        try? self.eventLoopGroup.syncShutdownGracefully()
    }
}

// MARK: - Raw record encoding

/// Encodes `values` into a flat byte image of fixed-size records: each record is
/// zeroed, then the NUL-terminated UTF-8 string is laid down starting at
/// `fieldStart`. Mirrors the on-disk layout the repo expects.
func encodeRecords(_ values: [String], recordSize: Int, fieldStart: Int = 0) -> [UInt8] {
    var image = [UInt8](repeating: 0, count: recordSize * values.count)
    for (i, value) in values.enumerated() {
        let bytes = Array(value.utf8)
        let base = i * recordSize + fieldStart
        precondition(fieldStart + bytes.count + 1 <= recordSize, "record \(i) overflows its field")
        for (j, b) in bytes.enumerated() { image[base + j] = b }
        // trailing byte stays 0 → NUL terminator
    }
    return image
}

// MARK: - Repo drivers

/// Seed a repo with `values` (one record each) and drive it through `body`.
@discardableResult
func withStringRepo<R>(recordSize: Int = 100,
                       offset: Int = 0,
                       fieldSelector: ClosedRange<Int>? = nil,
                       seed values: [String],
                       _ body: (StringRepo, FileRepoFixture) throws -> R) throws -> R {
    let fieldStart = fieldSelector?.lowerBound ?? 0
    let fixture = try FileRepoFixture(seed: encodeRecords(values, recordSize: recordSize, fieldStart: fieldStart))
    defer { fixture.shutdown() }
    let repo = StringRepo(nioFileHandle: fixture.fileHandle,
                          nonBlockingFileIO: fixture.client,
                          eventLoop: fixture.eventLoop,
                          recordSize: recordSize,
                          offset: offset,
                          fieldSelector: fieldSelector)
    return try body(repo, fixture)
}

/// Seed a repo with an arbitrary raw byte image — used to inject corruption
/// (e.g. a file whose length is not a whole multiple of `recordSize`).
@discardableResult
func withRawStringRepo<R>(recordSize: Int,
                          offset: Int = 0,
                          fieldSelector: ClosedRange<Int>? = nil,
                          rawBytes: [UInt8],
                          _ body: (StringRepo, FileRepoFixture) throws -> R) throws -> R {
    let fixture = try FileRepoFixture(seed: rawBytes)
    defer { fixture.shutdown() }
    let repo = StringRepo(nioFileHandle: fixture.fileHandle,
                          nonBlockingFileIO: fixture.client,
                          eventLoop: fixture.eventLoop,
                          recordSize: recordSize,
                          offset: offset,
                          fieldSelector: fieldSelector)
    return try body(repo, fixture)
}

// MARK: - Deterministic pseudo-randomness

/// A tiny seedable LCG (Numerical Recipes constants). `Date`/`Math.random` are not
/// usable in this environment and we want fully reproducible "fuzz" anyway, so all
/// randomized tests draw from a constant-seeded stream.
struct LCG {
    private var state: UInt64
    init(seed: UInt64) { self.state = seed }
    mutating func next() -> UInt64 {
        self.state = 6_364_136_223_846_793_005 &* self.state &+ 1_442_695_040_888_963_407
        return self.state
    }
    /// Uniform in `0..<upperBound`.
    mutating func int(_ upperBound: Int) -> Int {
        precondition(upperBound > 0)
        return Int(self.next() >> 11) % upperBound
    }
}

// MARK: - Header repo conformer

/// A minimal `HeaderRepoProtocol` conformer (Model.ID == Int) for exercising the
/// height-range API, mirroring the compact-filter-header use case.
final class HeaderRepo: HeaderRepoProtocol {
    struct Model: Identifiable, Sendable, Equatable {
        let id: Int
        let value: String
    }

    let allocator: ByteBufferAllocator
    let nioFileHandle: NIOFileHandle
    let nonBlockingFileIO: NonBlockingFileIOClient
    let eventLoop: EventLoop
    let recordSize: Int
    let offset: Int

    init(nioFileHandle: NIOFileHandle,
         nonBlockingFileIO: NonBlockingFileIOClient,
         eventLoop: EventLoop,
         recordSize: Int,
         offset: Int) {
        self.allocator = .init()
        self.nioFileHandle = nioFileHandle
        self.nonBlockingFileIO = nonBlockingFileIO
        self.eventLoop = eventLoop
        self.recordSize = recordSize
        self.offset = offset
    }

    func fileDecode(id: Int, buffer: inout ByteBuffer) throws -> Model {
        var copy = buffer
        guard let string = copy.readNullTerminatedString() else {
            throw File.Error.readError(message: "Cannot read string", event: #function)
        }
        return .init(id: id, value: string)
    }

    func fileEncode(_ row: Model, buffer: inout ByteBuffer) throws {
        guard row.value.utf8.count < self.recordSize else { throw File.Error.illegalArgument }
        buffer.writeNullTerminatedString(row.value)
    }
}

// MARK: - File.Error case predicates

extension File.Error {
    var isSeek: Bool { if case .seekError = self { return true }; return false }
    var isCorruption: Bool { if case .fileCorruptionError = self { return true }; return false }
    var isEmptyFile: Bool { if case .noDataFoundFileEmpty = self { return true }; return false }
    var isAppendOrdering: Bool { if case .appendFailedIncorrectOrdering = self { return true }; return false }
    var isNotFound: Bool { if case .notFound = self { return true }; return false }
    var isRead: Bool { if case .readError = self { return true }; return false }
    var isIllegalArgument: Bool { if case .illegalArgument = self { return true }; return false }

    /// The human-readable message carried by `.seekError`, for asserting offset arithmetic.
    var seekMessage: String? { if case let .seekError(message, _) = self { return message }; return nil }
}

/// Run a throwing body that is expected to fail with a `File.Error`; return it for
/// case inspection. Records a Swift Testing issue if it does not throw, or throws a
/// different error type.
@discardableResult
func captureFileError<R>(_ body: () throws -> R,
                         sourceLocation: SourceLocation = #_sourceLocation) -> File.Error? {
    do {
        _ = try body()
        Issue.record("expected a thrown File.Error, but the call returned normally", sourceLocation: sourceLocation)
        return nil
    } catch let error as File.Error {
        return error
    } catch {
        Issue.record("expected a File.Error, got \(type(of: error)): \(error)", sourceLocation: sourceLocation)
        return nil
    }
}

// MARK: - Fault injection

struct InjectedWriteError: Swift.Error {}

/// A client that delegates everything to `base` except `write`, which always fails
/// with `InjectedWriteError`. Lets us exercise the write-failure path of `append`
/// and `write` deterministically (count()/read still work so ordering checks pass).
func faultyWriteClient(base: NonBlockingFileIOClient) -> NonBlockingFileIOClient {
    NonBlockingFileIOClient(
        changeFileSize0: { fh, sz, el in base.changeFileSize(fileHandle: fh, size: sz, eventLoop: el) },
        close0: { fh, el in base.close(fileHandle: fh, eventLoop: el) },
        openFile0: { path, mode, flags, el in base.openFile(path: path, mode: mode, flags: flags, eventLoop: el) },
        readChunkedFileHandle: { fh, bc, cs, alloc, el, handler in
            base.readChunked(fileHandle: fh, byteCount: bc, chunkSize: cs, allocator: alloc, eventLoop: el, chunkHandler: handler)
        },
        readChunkedFileOffset: { fh, off, bc, cs, alloc, el, handler in
            base.readChunked(fileHandle: fh, fromOffset: off, byteCount: bc, chunkSize: cs, allocator: alloc, eventLoop: el, chunkHandler: handler)
        },
        readChunkedFileRegion: { region, cs, alloc, el, handler in
            base.readChunked(fileRegion: region, chunkSize: cs, allocator: alloc, eventLoop: el, chunkHandler: handler)
        },
        readFileHandle: { fh, bc, alloc, el in base.read(fileHandle: fh, byteCount: bc, allocator: alloc, eventLoop: el) },
        readFileOffset: { fh, off, bc, alloc, el in base.read(fileHandle: fh, fromOffset: off, byteCount: bc, allocator: alloc, eventLoop: el) },
        readFileRegion: { region, alloc, el in base.read(fileRegion: region, allocator: alloc, eventLoop: el) },
        readFileSize0: { fh, el in base.readFileSize(fileHandle: fh, eventLoop: el) },
        write0: { _, _, _, el in el.makeFailedFuture(InjectedWriteError()) },
        sync0: { fh, el in base.sync(fileHandle: fh, eventLoop: el) }
    )
}

// MARK: - Sorted-key helper

/// Zero-padded key whose lexicographic order matches numeric order for
/// non-negative values — so a field of these values is genuinely sorted ascending
/// and a valid `binarySearch` subject. (The original suite searched unpadded
/// "String \(i)" values, which are NOT lexicographically sorted across digit
/// widths; see the binary-search suite.)
func sortedKey(_ value: Int, width: Int = 8) -> String {
    precondition(value >= 0)
    return String(format: "%0\(width)d", value)
}
