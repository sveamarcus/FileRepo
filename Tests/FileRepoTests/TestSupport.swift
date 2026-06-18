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
// database for Bitcoin blockchain storage. Following the NIOFileSystem + async/await
// migration these helpers build an isolated repo over a freshly created temp file,
// run an `async` body that drives the repo through its `async throws` API, and
// guarantee teardown (which now `await`s the handle close) on both the success and
// failure paths.
//
import FileRepo
import Foundation
import NIOCore
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
    let io: FileIOClient
    let recordSize: Int
    let offset: Int
    let fieldSelector: ClosedRange<Int>?

    init(allocator: ByteBufferAllocator = .init(),
         io: FileIOClient,
         recordSize: Int,
         offset: Int = 0,
         fieldSelector: ClosedRange<Int>? = nil) {
        self.allocator = allocator
        self.io = io
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

/// Owns a `FileIOClient` over a temporary file for the lifetime of a single test.
/// Construct via the `withStringRepo`/`withRawStringRepo` helpers, which guarantee
/// `shutdown()` runs (and is awaited) even when the test body throws.
final class FileRepoFixture {
    let io: FileIOClient
    let path: String

    /// Creates the temp file and writes `seed` bytes verbatim as its initial contents.
    init(seed: [UInt8]) async throws {
        self.path = "/tmp/filerepo_test_\(UUID().uuidString)"
        self.io = try await FileIOClient.live(path: self.path)

        if !seed.isEmpty {
            var buffer = ByteBufferAllocator().buffer(capacity: seed.count)
            buffer.writeBytes(seed)
            try await self.io.write(buffer, toOffset: 0)
        }
    }

    /// Close the handle (idempotent — safe even if the test already closed the repo)
    /// and remove the temp file. Failures here are cleanup noise, not test signal, so
    /// they are swallowed deliberately.
    func shutdown() async {
        try? await self.io.close()
        try? await File.delete(file: self.path)
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
                       _ body: (StringRepo, FileRepoFixture) async throws -> R) async throws -> R {
    let fieldStart = fieldSelector?.lowerBound ?? 0
    let fixture = try await FileRepoFixture(seed: encodeRecords(values, recordSize: recordSize, fieldStart: fieldStart))
    do {
        let repo = StringRepo(io: fixture.io,
                              recordSize: recordSize,
                              offset: offset,
                              fieldSelector: fieldSelector)
        let result = try await body(repo, fixture)
        await fixture.shutdown()
        return result
    } catch {
        await fixture.shutdown()
        throw error
    }
}

/// Seed a repo with an arbitrary raw byte image — used to inject corruption
/// (e.g. a file whose length is not a whole multiple of `recordSize`).
@discardableResult
func withRawStringRepo<R>(recordSize: Int,
                          offset: Int = 0,
                          fieldSelector: ClosedRange<Int>? = nil,
                          rawBytes: [UInt8],
                          _ body: (StringRepo, FileRepoFixture) async throws -> R) async throws -> R {
    let fixture = try await FileRepoFixture(seed: rawBytes)
    do {
        let repo = StringRepo(io: fixture.io,
                              recordSize: recordSize,
                              offset: offset,
                              fieldSelector: fieldSelector)
        let result = try await body(repo, fixture)
        await fixture.shutdown()
        return result
    } catch {
        await fixture.shutdown()
        throw error
    }
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
    let io: FileIOClient
    let recordSize: Int
    let offset: Int

    init(io: FileIOClient,
         recordSize: Int,
         offset: Int) {
        self.allocator = .init()
        self.io = io
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
    var isRead: Bool { if case .readError = self { return true }; return false }
    var isIllegalArgument: Bool { if case .illegalArgument = self { return true }; return false }

    /// The human-readable message carried by `.seekError`, for asserting offset arithmetic.
    var seekMessage: String? { if case let .seekError(message, _) = self { return message }; return nil }
}

/// Run a throwing `async` body that is expected to fail with a `File.Error`; return
/// it for case inspection. Records a Swift Testing issue if it does not throw, or
/// throws a different error type.
@discardableResult
func captureFileError<R>(_ body: () async throws -> R,
                         sourceLocation: SourceLocation = #_sourceLocation) async -> File.Error? {
    do {
        _ = try await body()
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
struct InjectedSyncError: Swift.Error {}

/// A client that delegates everything to `base` except `write`, which always fails
/// with `InjectedWriteError`. Lets us exercise the write-failure path of `append`
/// and `write` deterministically (count()/read still work so ordering checks pass).
func faultyWriteClient(base: FileIOClient) -> FileIOClient {
    FileIOClient(
        readChunk0: { offset, byteCount in try await base.readChunk(fromOffset: offset, byteCount: byteCount) },
        write0: { _, _ in throw InjectedWriteError() },
        size0: { try await base.size() },
        resize0: { size in try await base.resize(to: size) },
        synchronize0: { try await base.synchronize() },
        close0: { try await base.close() }
    )
}

/// A client that delegates everything to `base` except `synchronize`, which always
/// fails with `InjectedSyncError`. Lets us assert that `close()` still closes the
/// handle (no leaked-descriptor trap) when its durability flush fails.
func faultySyncClient(base: FileIOClient) -> FileIOClient {
    FileIOClient(
        readChunk0: { offset, byteCount in try await base.readChunk(fromOffset: offset, byteCount: byteCount) },
        write0: { buffer, offset in try await base.write(buffer, toOffset: offset) },
        size0: { try await base.size() },
        resize0: { size in try await base.resize(to: size) },
        synchronize0: { throw InjectedSyncError() },
        close0: { try await base.close() }
    )
}

/// A client whose single-`pread` `readChunk` never returns more than `cap` bytes,
/// forcing `FileIOClient.read(fromOffset:byteCount:)` to exercise its multi-chunk
/// fill loop (and its true-EOF stop condition).
func cappedReadClient(base: FileIOClient, cap: Int) -> FileIOClient {
    FileIOClient(
        readChunk0: { offset, byteCount in try await base.readChunk(fromOffset: offset, byteCount: Swift.min(byteCount, cap)) },
        write0: { buffer, offset in try await base.write(buffer, toOffset: offset) },
        size0: { try await base.size() },
        resize0: { size in try await base.resize(to: size) },
        synchronize0: { try await base.synchronize() },
        close0: { try await base.close() }
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
