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
import HaByLo
import NIOConcurrencyHelpers
import NIOCore

public protocol FileRepo: AnyObject, Sendable {
    associatedtype Model: Identifiable & Sendable

    var allocator: ByteBufferAllocator { get }
    var nioFileHandle: NIOFileHandle { get }
    var nonBlockingFileIO: NonBlockingFileIOClient { get }
    var eventLoop: EventLoop { get }

    var recordSize: Int { get }
    var fieldSelector: ClosedRange<Int>? { get }
    var offset: Int { get }

    func close() -> EventLoopFuture<Void>
    func fileDecode(id: Int, buffer: inout ByteBuffer) throws -> Model
    func fileEncode(_ row: Model, buffer: inout ByteBuffer) throws
}

public extension FileRepo {
    @inlinable
    var fieldSelector: ClosedRange<Int>? {
        nil
    }

    @inlinable
    var nonBlockingFileIOnumberOfChunks: Int {
        (0xff_ff + 1) / self.recordSize
    }
}

public extension FileRepo {
    @inlinable
    func fileSize() -> EventLoopFuture<Int> {
        self.nonBlockingFileIO.readFileSize(fileHandle: self.nioFileHandle,
                                            eventLoop: self.eventLoop)
        .map {
            Int($0)
        }
    }
    
    @inlinable
    func close() -> EventLoopFuture<Void> {
        return self.nonBlockingFileIO.close(fileHandle: self.nioFileHandle, eventLoop: self.eventLoop)
    }

    @inlinable
    func count() -> EventLoopFuture<Int> {
        self.fileSize().flatMapThrowing { fileSize in
            let qr = fileSize.quotientAndRemainder(dividingBy: self.recordSize)
            guard qr.remainder == 0 else {
                throw File.Error.fileCorruptionError(event: #function)
            }
            return qr.quotient
        }
    }
    
    @inlinable
    func range() -> EventLoopFuture<Range<Int>> {
        self.count().flatMapThrowing { count in
            guard count > 0 else {
                throw File.Error.noDataFoundFileEmpty(String(describing: Model.self))
            }
            
            let lowerHeight = self.offset
            let upperHeight = count + (self.offset)
            
            return lowerHeight..<upperHeight
        }
    }
    
    @inlinable
    func fileDecodeWithOffset(id: Int, buffer: inout ByteBuffer) throws -> Model {
        let offsetId = id + self.offset
        
        return try self.fileDecode(id: offsetId, buffer: &buffer)
    }
    
    @inlinable
    func find(id: Int, event: StaticString = #function) -> EventLoopFuture<Model> {
        self.checkOffset(for: id).flatMap { offsetId in
            self.count()
            .flatMapThrowing { count in
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
                let endIndex = readerIndex + fieldSize
                assert(endIndex <= count * self.recordSize)
                
                return FileRegion.init(fileHandle: self.nioFileHandle,
                                       readerIndex: readerIndex,
                                       endIndex: endIndex)
            }
            .flatMap { fileRegion in
                self.nonBlockingFileIO.read(fileRegion: fileRegion,
                                            allocator: self.allocator,
                                            eventLoop: self.eventLoop)
            }
            .flatMapThrowing {
                var buffer = $0
                return try self.fileDecode(id: id, buffer: &buffer)
            }
        }
    }
    
    @inlinable
    func find(from: Int, through: Int? = nil, event: StaticString = #function) -> EventLoopFuture<[Model]> {
        // `readChunked` invokes its chunk handler repeatedly, and the handler is an
        // `@Sendable` closure, so the running tally cannot live in captured `var`s
        // under complete concurrency checking. A lock-protected box carries it across
        // invocations; the lock is uncontended because the handler only ever runs
        // serially on `self.eventLoop`. Tuple .0 = decoded rows, .1 = records read.
        let accumulator = NIOLockedValueBox<([Model], Int)>(([], 0))

        return self.checkOffset(for: from).flatMap { fromId in
            self.count().flatMap { count in
                let through = through ?? (self.offset + count - 1)
                return self.checkOffset(for: through)
                .flatMapThrowing { throughId -> (Int, Int) in
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

                    let chunkedReaderIndex = fromId * self.recordSize
                    let chunkedReadedEndIndex = (throughId + 1) * self.recordSize

                    return (chunkedReaderIndex, chunkedReadedEndIndex)
                }
                .flatMap { chunkedReaderIndex, chunkedReadedEndIndex in
                    self.nonBlockingFileIO.readChunked(fileHandle: self.nioFileHandle,
                                                       fromOffset: Int64(chunkedReaderIndex),
                                                       byteCount: chunkedReadedEndIndex - chunkedReaderIndex,
                                                       chunkSize: self.recordSize * self.nonBlockingFileIOnumberOfChunks,
                                                       allocator: self.allocator,
                                                       eventLoop: self.eventLoop) { (buffer: ByteBuffer) in
                        assert(buffer.readableBytes % self.recordSize == 0)

                        var buffer = buffer
                        let fieldStart = self.fieldSelector?.lowerBound ?? 0

                        do {
                            try accumulator.withLockedValue { tally in
                                while var record = buffer.readSlice(length: self.recordSize) {
                                    record.moveReaderIndex(forwardBy: fieldStart)
                                    tally.0.append(
                                        try self.fileDecode(id: from + tally.1, buffer: &record)
                                    )
                                    tally.1 += 1
                                }
                            }
                        } catch {
                            return self.eventLoop.makeFailedFuture(error)
                        }

                        return self.eventLoop.makeSucceededFuture(())
                    }
                    .flatMapThrowing {
                        let (result, readCount) = accumulator.withLockedValue { $0 }
                        assert(result.count == readCount)

                        guard result.count == through - from + 1 else {
                            throw File.Error.fileCorruptionError(event: event)
                        }

                        return result
                    }
                }
            }
        }
    }

    @inlinable
    func binarySearch<T: Comparable & Sendable>(comparable: T,
                                                left: Int,
                                                right: Int,
                                                event: StaticString = #function,
                                                selector: @escaping @Sendable (Model) -> T) -> EventLoopFuture<Model> {
        @Sendable func innerBinarySearch(innerLeft: Int,
                                         innerRight: Int) -> EventLoopFuture<Model> {
            guard innerLeft <= innerRight else {
                return self.find(id: max(left, innerLeft - 1), event: event)
                .and(self.find(id: min(right, innerRight + 1), event: event))
                .flatMap {
                    self.eventLoop.makeFailedFuture(
                        File.NoExactMatchFound(left: $0.0, right: $0.1)
                    )
                }
            }

            let mid = (1 + innerLeft + innerRight) / 2
            let midRow: EventLoopFuture<Model> = self.find(id: mid, event: event)

            return midRow.flatMap { row in
                let candidate = selector(row)
                if candidate < comparable {
                    return innerBinarySearch(innerLeft: mid + 1, innerRight: innerRight)
                } else if candidate > comparable {
                    return innerBinarySearch(innerLeft: innerLeft, innerRight: mid - 1)
                } else { // candidate == comparable
                    return midRow
                }
            }
        }
        
        return innerBinarySearch(innerLeft: left, innerRight: right)
    }
    @inlinable
    func binarySearch<T: Comparable & Sendable>(comparable: T,
                                                left: Int,
                                                right: Int,
                                                promise: EventLoopPromise<Model>,
                                                selector: @escaping @Sendable (Model) -> T) {
        guard left <= right else {
            promise.fail(File.Error.notFound(message: "left index greater than right index"))
            return
        }
        
        let mid = (1 + left + right) / 2
        let midRow: EventLoopFuture<Model> = self.find(id: mid, event: #function)
        let tuple = midRow.and(midRow.map(selector))
        tuple.cascadeFailure(to: promise)
        tuple.whenSuccess { row, candidate in
            if candidate < comparable {
                self.eventLoop.execute {
                    self.binarySearch(comparable: comparable,
                                      left: mid + 1,
                                      right: right,
                                      promise: promise,
                                      selector: selector)
                }
            } else if candidate > comparable {
                self.eventLoop.execute {
                    self.binarySearch(comparable: comparable,
                                      left: left,
                                      right: mid - 1,
                                      promise: promise,
                                      selector: selector)
                }
            } else { // candidate == comparable
                promise.succeed(row)
            }
        }
    }

    @inlinable
    func checkOffset(for id: Int, function: StaticString = #function) -> EventLoopFuture<Int> {
        self.eventLoop.makeSucceededFuture(id - self.offset)
        .flatMapThrowing { offsetId in
            guard id >= self.offset else {
                throw File.Error.seekError(message: "Cannot read below offset [\(self.offset)]", event: function)
            }

            return offsetId
        }
    }
    
    @inlinable
    func checkOffset(for id: Int, function: StaticString = #function) throws -> Int {
        guard id >= self.offset
        else {
            throw File.Error.seekError(message: "Cannot read below offset [\(self.offset)]", event: function)
        }

        return id - self.offset
    }
    
    @inlinable
    func delete(from id: Int, event: StaticString = #function) -> EventLoopFuture<Void> {
        self.checkOffset(for: id, function: event).flatMap { id in
            let newSize = Int64(id * self.recordSize)
            
            return self.fileSize()
            .flatMap { fileSize in
                if newSize >= fileSize {
                    return self.eventLoop.makeFailedFuture(
                        File.Error.seekError(
                            message: "Cannot seek beyond end of file, id \(id)",
                            event: #function)
                    )
                } else {
                    return self.nonBlockingFileIO.changeFileSize(fileHandle: self.nioFileHandle,
                                                                 size: newSize,
                                                                 eventLoop: self.eventLoop)
                }
            }
        }
        .flatMap {
            self.nonBlockingFileIO.sync(fileHandle: self.nioFileHandle,
                                        eventLoop: self.eventLoop)
        }
    }
    
    @inlinable
    func sync() -> EventLoopFuture<Void> {
        self.nonBlockingFileIO.sync(fileHandle: self.nioFileHandle,
                                    eventLoop: self.eventLoop)
    }

    @inlinable
    func write<T>(_ row: T) -> EventLoopFuture<Void> where T.ID == Int, T == Model {
        return self.checkOffset(for: row.id).flatMap { id in
            let offset = Int64(id * self.recordSize)
            
            return self.nonBlockingFileIO.read(
                fileHandle: self.nioFileHandle,
                fromOffset: offset,
                byteCount: self.recordSize,
                allocator: self.allocator,
                eventLoop: self.eventLoop
            )
            .map {
                assert($0.readableBytes == 0 || $0.readableBytes == self.recordSize)
                if $0.readableBytes == 0 { // end of file
                    var emptyBuffer = self.allocator.buffer(capacity: self.recordSize)
                    emptyBuffer.writeRepeatingByte(0, count: self.recordSize)
                    return emptyBuffer
                } else {
                    return $0
                }
            }
            .flatMapThrowing { (record: ByteBuffer) in
                let size: Int
                if let fieldSelector = self.fieldSelector {
                    size = fieldSelector.distance(from: fieldSelector.startIndex, to: fieldSelector.endIndex)
                } else {
                    size = self.recordSize
                }
                var newField = self.allocator.buffer(capacity: size)
                try self.fileEncode(row, buffer: &newField)
                
                var modifiedRecord = record
                modifiedRecord.setBuffer(newField, at: self.fieldSelector?.lowerBound ?? 0)
                
                return modifiedRecord
            }
            .flatMap { (modifiedRecord: ByteBuffer) in
                assert(modifiedRecord.readableBytes == self.recordSize)
                
                return self.nonBlockingFileIO.write(fileHandle: self.nioFileHandle,
                                                    toOffset: offset,
                                                    buffer: modifiedRecord,
                                                    eventLoop: self.eventLoop)
            }
        }
    }
    
    @inlinable
    func append<C, T>(_ rows: C) -> EventLoopFuture<Void> where C: Collection & Sendable, C.Element == T, T.ID == Int, T == Model {
        guard let first = rows.first else {
            return self.eventLoop.makeSucceededFuture(())
        }

        return self.checkOffset(for: first.id)
        .and(self.count())
        .flatMapThrowing { id, count in
            guard id == count else {
                logger.error("File", #function, "- Appending of id \(id) to end of file \(count - 1), illegal sequencing")
                throw File.Error.appendFailedIncorrectOrdering
            }
        }
        .flatMap {
            rows.reduce(self.eventLoop.makeSucceededFuture(())) { chain, row in
                chain.flatMap { self.write(row) }
            }
        }
    }
}
