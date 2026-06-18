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
import Logging
import NIOCore

public protocol FileRepo: AnyObject, Sendable {
    associatedtype Model: Identifiable & Sendable

    var allocator: ByteBufferAllocator { get }
    var io: FileIOClient { get }

    var recordSize: Int { get }
    var fieldSelector: ClosedRange<Int>? { get }
    var offset: Int { get }

    func close() async throws
    func fileDecode(id: Int, buffer: inout ByteBuffer) throws -> Model
    func fileEncode(_ row: Model, buffer: inout ByteBuffer) throws
}

public extension FileRepo {
    @inlinable
    var fieldSelector: ClosedRange<Int>? {
        nil
    }

    @usableFromInline
    internal var recordsPerChunk: Int {
        (0xff_ff + 1) / self.recordSize
    }

    /// The chunk size used by ``find(from:through:event:)``: roughly 64 KiB rounded
    /// down to a whole number of records, but never below a single record (which
    /// would otherwise stall the read loop for `recordSize > 64 KiB`).
    @usableFromInline
    internal var chunkByteSize: Int {
        Swift.max(self.recordSize, self.recordSize * self.recordsPerChunk)
    }
}

public extension FileRepo {
    @inlinable
    func fileSize() async throws -> Int {
        Int(try await self.io.size())
    }

    @inlinable
    func close() async throws {
        do {
            try await self.io.synchronize()
        } catch {
            try? await self.io.close()
            throw error
        }
        try await self.io.close()
    }

    @inlinable
    func count() async throws -> Int {
        let fileSize = try await self.fileSize()
        let qr = fileSize.quotientAndRemainder(dividingBy: self.recordSize)
        guard qr.remainder == 0 else {
            throw File.Error.fileCorruptionError(event: #function)
        }
        return qr.quotient
    }

    @inlinable
    func range() async throws -> Range<Int> {
        let count = try await self.count()
        guard count > 0 else {
            throw File.Error.noDataFoundFileEmpty(String(describing: Model.self))
        }

        let lowerHeight = self.offset
        let upperHeight = count + self.offset

        return lowerHeight..<upperHeight
    }

    @inlinable
    func fileDecodeWithOffset(id: Int, buffer: inout ByteBuffer) throws -> Model {
        let offsetId = id + self.offset

        return try self.fileDecode(id: offsetId, buffer: &buffer)
    }

    @inlinable
    func find(id: Int, event: StaticString = #function) async throws -> Model {
        let offsetId = try self.checkOffset(for: id)
        let count = try await self.count()
        guard offsetId >= 0, offsetId < count else {
            throw File.Error.seekError(
                message: "Tried to seek record \(offsetId + self.offset) (file maximum \((self.offset + max(0, count - 1))))",
                event: event
            )
        }

        let readerIndex = offsetId * self.recordSize + (self.fieldSelector?.lowerBound ?? 0)
        let fieldSize: Int
        if let fieldSelector = self.fieldSelector {
            fieldSize = fieldSelector.distance(from: fieldSelector.startIndex, to: fieldSelector.endIndex)
        } else {
            fieldSize = self.recordSize
        }
        assert(readerIndex + fieldSize <= count * self.recordSize)

        var buffer = try await self.io.read(fromOffset: Int64(readerIndex), byteCount: fieldSize)
        return try self.fileDecode(id: id, buffer: &buffer)
    }

    @inlinable
    func find(from: Int, through: Int? = nil, event: StaticString = #function) async throws -> [Model] {
        let fromId = try self.checkOffset(for: from)
        let count = try await self.count()
        let through = through ?? (self.offset + count - 1)
        let throughId = try self.checkOffset(for: through)

        guard fromId >= 0, fromId < count else {
            throw File.Error.seekError(
                message: "Tried to seek record \(from) (file maximum \((self.offset + max(0, count - 1))))",
                event: event
            )
        }
        guard throughId >= fromId, throughId < count else {
            throw File.Error.seekError(
                message: "Tried to seek record \(through) which is either below from \(from) or beyond file maximum \((self.offset + max(0, count - 1)))",
                event: event
            )
        }

        let startByte = Int64(fromId * self.recordSize)
        let totalBytes = (throughId - fromId + 1) * self.recordSize
        let chunkSize = self.chunkByteSize
        let fieldStart = self.fieldSelector?.lowerBound ?? 0

        var result: [Model] = []
        result.reserveCapacity(throughId - fromId + 1)

        var byteCursor = 0
        while byteCursor < totalBytes {
            let want = Swift.min(chunkSize, totalBytes - byteCursor)
            var chunk = try await self.io.read(fromOffset: startByte + Int64(byteCursor), byteCount: want)
            // The whole span lies within the file (`throughId < count`), so a short
            // read here means the file was truncated/corrupted underneath us.
            guard chunk.readableBytes == want else {
                throw File.Error.fileCorruptionError(event: event)
            }
            assert(chunk.readableBytes % self.recordSize == 0)

            while var record = chunk.readSlice(length: self.recordSize) {
                record.moveReaderIndex(forwardBy: fieldStart)
                result.append(try self.fileDecode(id: from + result.count, buffer: &record))
            }
            byteCursor += want
        }

        guard result.count == through - from + 1 else {
            throw File.Error.fileCorruptionError(event: event)
        }

        return result
    }

    /// Logarithmic search over a field assumed sorted ascending across ids.
    /// Implemented in terms of ``find(id:event:)``. On a miss throws
    /// ``File/NoExactMatchFound`` carrying the two records that bracket the target.
    ///
    /// The midpoint rounds *down* using overflow-safe unsigned-width subtraction, so
    /// it is correct for every `left <= right` across the full `Int` range. (One
    /// consequence: among duplicate keys it settles on a higher index than the old
    /// round-up midpoint did.)
    @inlinable
    func binarySearch<T: Comparable & Sendable>(comparable: T,
                                                left: Int,
                                                right: Int,
                                                event: StaticString = #function,
                                                selector: @Sendable (Model) -> T) async throws -> Model {
        var lo = left
        var hi = right
        while lo <= hi {
            let mid = lo + Int(bitPattern: (UInt(bitPattern: hi) &- UInt(bitPattern: lo)) >> 1)
            let row = try await self.find(id: mid, event: event)
            let candidate = selector(row)
            if candidate < comparable {
                lo = mid + 1
            } else if candidate > comparable {
                hi = mid - 1
            } else { // candidate == comparable
                return row
            }
        }

        let bracketLeft = try await self.find(id: Swift.max(left, lo - 1), event: event)
        let bracketRight = try await self.find(id: Swift.min(right, hi + 1), event: event)
        throw File.NoExactMatchFound(left: bracketLeft, right: bracketRight)
    }

    @inlinable
    func checkOffset(for id: Int, function: StaticString = #function) throws -> Int {
        guard id >= self.offset
        else {
            throw File.Error.seekError(message: "Cannot read below offset [\(self.offset)]", event: function)
        }

        return id - self.offset
    }

    /// Truncates the file at record `id`, discarding it and everything after it, then
    /// flushes durably.
    ///
    /// - Important: A mutation — must be serialised with all other mutations (see
    ///   ``write(_:)``).
    @inlinable
    func delete(from id: Int, event: StaticString = #function) async throws {
        let offsetId = try self.checkOffset(for: id, function: event)
        let newSize = Int64(offsetId * self.recordSize)

        let fileSize = try await self.io.size()
        guard newSize < fileSize else {
            throw File.Error.seekError(
                message: "Cannot seek beyond end of file, id \(offsetId)",
                event: #function)
        }

        try await self.io.resize(to: newSize)
        try await self.io.synchronize()
        fileRepoLog.debug("🗑️ deleted from id \(id) (truncated to \(offsetId) records)")
    }

    @inlinable
    func sync() async throws {
        try await self.io.synchronize()
    }

    /// Overwrites the record at `row.id` (growing the file by one, or zero-filling a
    /// gap, when `row.id` is at or beyond the current end).
    ///
    /// - Important: `write` is a read-modify-write (it reads the record to preserve
    ///   the bytes outside `fieldSelector`). Unlike reads — which are concurrency-safe
    ///   on the shared handle — mutations are **not** safe to run concurrently with
    ///   another `write`/``append(_:)``/``delete(from:)`` touching an overlapping
    ///   record: interleaved writes clobber each other. Serialise all mutations
    ///   through a single writer (an `actor` or a dedicated write task). This matches
    ///   the single-writer model of the rest of the store family.
    @inlinable
    func write<T>(_ row: T) async throws where T.ID == Int, T == Model {
        let id = try self.checkOffset(for: row.id)
        let offset = Int64(id * self.recordSize)

        let existing = try await self.io.read(fromOffset: offset,
                                              byteCount: self.recordSize)
        assert(existing.readableBytes == 0 || existing.readableBytes == self.recordSize)

        var record: ByteBuffer
        if existing.readableBytes == 0 { // end of file — grow with a fresh record
            record = self.allocator.buffer(capacity: self.recordSize)
            record.writeRepeatingByte(0, count: self.recordSize)
        } else {
            record = existing
        }

        let size: Int
        if let fieldSelector = self.fieldSelector {
            size = fieldSelector.distance(from: fieldSelector.startIndex, to: fieldSelector.endIndex)
        } else {
            size = self.recordSize
        }
        var newField = self.allocator.buffer(capacity: size)
        try self.fileEncode(row, buffer: &newField)

        record.setBuffer(newField, at: self.fieldSelector?.lowerBound ?? 0)
        assert(record.readableBytes == self.recordSize)

        try await self.io.write(record, toOffset: offset)
    }

    /// Appends `rows` to the end of the file. The first row's id must equal the
    /// current record count (relative to ``offset``) or this throws
    /// ``File/Error/appendFailedIncorrectOrdering`` before writing anything.
    ///
    /// - Important: Like ``write(_:)``, `append` mutates and must be serialised with
    ///   all other mutations (see ``write(_:)``); it is not safe to run concurrently
    ///   with another writer.
    @inlinable
    func append<C, T>(_ rows: C) async throws where C: Collection & Sendable, C.Element == T, T.ID == Int, T == Model {
        guard let first = rows.first else {
            return
        }

        let id = try self.checkOffset(for: first.id)
        let count = try await self.count()
        guard id == count else {
            fileRepoLog.error("❌ append: id \(id) is not the next slot (\(count)) — illegal sequencing")
            throw File.Error.appendFailedIncorrectOrdering
        }

        for row in rows {
            try await self.write(row)
        }
        fileRepoLog.debug("➕ appended \(rows.count) record(s) from id \(first.id)")
    }
}
