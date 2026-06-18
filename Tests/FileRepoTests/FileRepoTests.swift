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
// Adversarial test suite for FileRepo — a fixed-record-size, height-indexed flat
// file used as a linear database for Bitcoin blockchain storage. Migrated from
// XCTest to Swift Testing. Beyond the original happy-path coverage, these tests
// attack boundaries, corrupted files, offset arithmetic, the sorted-input
// precondition of binary search, mutation contracts, concurrency, and scale.
//
// RUN SERIALLY:  swift test --no-parallel
// These are blocking integration tests — each drives the NIO future API via
// `.wait()`. Under Swift Testing's default parallel execution those blocking waits
// saturate the Swift Concurrency cooperative pool and the run deadlocks. `--no-parallel`
// runs the whole suite in ~0.35s. (The repo also enforces single-handle access, so
// concurrent operations on one instance are unsupported regardless — see the
// Concurrency suite.)
//
// Throwing reads are hoisted into `let` bindings before `#expect(...)`: the
// `#expect` macro wraps its argument in a non-throwing autoclosure, so a `try`
// placed directly inside `#expect(...)` within these (closure-nested) bodies does
// not type-check.
//
// Honesty notes (verified by these tests):
//  * `append([])` is now a no-op (it previously force-unwrapped `rows.first!` and
//    trapped the process). See `MutationContracts.emptyAppendIsNoOp`.
//  * `append`/`write` now propagate I/O failures instead of `preconditionFailure`
//    crashing. See `MutationContracts.writeFailurePropagates`.
//  * `binarySearch` requires the selected field to be sorted ascending; on
//    unsorted input it can fail to find a present value. See `BinarySearch.unsortedInputIsUnreliable`.
//  * `write` beyond end-of-file silently creates a zero-filled gap record. See
//    `MutationContracts.writeBeyondEndOfFileCreatesGap`.
//
import FileRepo
import NIOCore
import Testing

// MARK: - Core round-trip & reads

@Suite("Core round-trip & reads")
struct CoreReads {
    @Test("count() returns the number of records", arguments: [0, 1, 100, 1000])
    func countReturnsRecordCount(capacity: Int) throws {
        let values = (0..<capacity).map { "rec \($0)" }
        try withStringRepo(seed: values) { repo, _ in
            let count = try repo.count().wait()
            #expect(count == capacity)
        }
    }

    @Test("find(id:) returns each record by id")
    func findEachRecord() throws {
        let capacity = 500
        let values = (0..<capacity).map { "String \($0)" }
        try withStringRepo(seed: values) { repo, _ in
            for i in 0..<capacity {
                let record = try repo.find(id: i).wait()
                #expect(record.id == i)
                #expect(record.value == "String \(i)")
            }
        }
    }

    @Test("find(from:) returns the tail of the file")
    func findFromTail() throws {
        let capacity = 1000
        let values = (0..<capacity).map { "String \($0)" }
        try withStringRepo(seed: values) { repo, _ in
            let records = try repo.find(from: 1).wait()
            #expect(records.count == capacity - 1)
            for i in 1..<capacity {
                #expect(records[i - 1].id == i)
                #expect(records[i - 1].value == "String \(i)")
            }
        }
    }

    @Test("range() returns [0, count)")
    func rangeBounds() throws {
        try withStringRepo(seed: (0..<250).map { "r\($0)" }) { repo, _ in
            let range = try repo.range().wait()
            #expect(range == 0..<250)
        }
    }

    @Test("find(from:through:) round-trips the whole file in order")
    func fullFileRoundTrip() throws {
        let values = (0..<300).map { "String \($0)" }
        try withStringRepo(seed: values) { repo, _ in
            let all = try repo.find(from: 0, through: 299).wait()
            #expect(all.map(\.value) == values)
            #expect(all.map(\.id) == Array(0..<300))
        }
    }
}

// MARK: - Corruption & integrity

@Suite("Corruption & integrity")
struct Corruption {
    @Test("count() throws fileCorruptionError when file size is not a multiple of recordSize")
    func misalignedFileSize() throws {
        // 250 bytes with recordSize 100 = 2 whole records + a 50-byte fragment.
        try withRawStringRepo(recordSize: 100, rawBytes: [UInt8](repeating: 0, count: 250)) { repo, _ in
            let e = captureFileError { try repo.count().wait() }
            #expect(e?.isCorruption == true)
        }
    }

    @Test("count() is 0 and range() throws noDataFoundFileEmpty on an empty file")
    func emptyFile() throws {
        try withStringRepo(seed: []) { repo, _ in
            let count = try repo.count().wait()
            #expect(count == 0)
            let e = captureFileError { try repo.range().wait() }
            #expect(e?.isEmptyFile == true)
        }
    }

    @Test("find(id:) surfaces a decode failure as readError on a record with no NUL terminator")
    func decodeFailureSurfaces() throws {
        // A single 100-byte record full of 0xFF: no NUL terminator, so the string
        // decode returns nil and the repo throws readError.
        try withRawStringRepo(recordSize: 100, rawBytes: [UInt8](repeating: 0xFF, count: 100)) { repo, _ in
            let count = try repo.count().wait()
            #expect(count == 1)
            let e = captureFileError { _ = try repo.find(id: 0).wait() }
            #expect(e?.isRead == true)
        }
    }

    @Test("find(from:through:) propagates a mid-stream decode failure")
    func chunkedDecodeFailurePropagates() throws {
        // 3 records: record 1 is corrupt (no terminator). find over the range must
        // fail with the decode error, not silently drop the record.
        var raw = [UInt8]()
        raw += encodeRecords(["alpha"], recordSize: 100)
        raw += [UInt8](repeating: 0xFF, count: 100)
        raw += encodeRecords(["gamma"], recordSize: 100)
        try withRawStringRepo(recordSize: 100, rawBytes: raw) { repo, _ in
            let e = captureFileError { _ = try repo.find(from: 0, through: 2).wait() }
            #expect(e?.isRead == true)
        }
    }
}

// MARK: - Offset arithmetic (Bitcoin height base)

@Suite("Offset arithmetic (Bitcoin height base)")
struct OffsetArithmetic {
    static let base = 500_000
    static let capacity = 100

    private func withHeightRepo(_ body: (StringRepo) throws -> Void) throws {
        let values = (0..<Self.capacity).map { "block \(Self.base + $0)" }
        try withStringRepo(offset: Self.base, seed: values, { repo, _ in try body(repo) })
    }

    @Test("find below the offset throws seekError citing the offset")
    func findBelowOffset() throws {
        try withHeightRepo { repo in
            let e = captureFileError { _ = try repo.find(id: Self.base - 1).wait() }
            #expect(e?.isSeek == true)
            #expect(e?.seekMessage?.contains("Cannot read below offset [\(Self.base)]") == true)
        }
    }

    @Test("find at the offset (logical id 0) decodes the logical id, not the physical index")
    func findAtOffset() throws {
        try withHeightRepo { repo in
            let record = try repo.find(id: Self.base).wait()
            #expect(record.id == Self.base)
            #expect(record.value == "block \(Self.base)")
        }
    }

    @Test("find at offset+count-1 (file maximum) succeeds")
    func findAtFileMaximum() throws {
        try withHeightRepo { repo in
            let last = Self.base + Self.capacity - 1
            let record = try repo.find(id: last).wait()
            #expect(record.id == last)
        }
    }

    @Test("find beyond offset+count throws seekError with offset-adjusted message")
    func findBeyondFileMaximum() throws {
        try withHeightRepo { repo in
            let beyond = Self.base + Self.capacity        // 500100
            let e = captureFileError { _ = try repo.find(id: beyond).wait() }
            #expect(e?.isSeek == true)
            // "Tried to seek record 500100 (file maximum 500099)"
            #expect(e?.seekMessage?.contains("seek record \(beyond)") == true)
            #expect(e?.seekMessage?.contains("file maximum \(Self.base + Self.capacity - 1)") == true)
        }
    }

    @Test("find(from:through:) decodes correct logical ids despite chunking")
    func rangeReadLogicalIds() throws {
        try withHeightRepo { repo in
            let from = Self.base + 10
            let through = Self.base + 19
            let records = try repo.find(from: from, through: through).wait()
            #expect(records.map(\.id) == Array(from...through))
            #expect(records.first?.value == "block \(from)")
            #expect(records.last?.value == "block \(through)")
        }
    }

    @Test("range() reports logical (height) bounds")
    func rangeWithOffset() throws {
        try withHeightRepo { repo in
            let range = try repo.range().wait()
            #expect(range == Self.base..<(Self.base + Self.capacity))
        }
    }

    @Test("write and delete below the offset throw seekError")
    func mutationBelowOffset() throws {
        try withHeightRepo { repo in
            let writeErr = captureFileError {
                try repo.write(.init(id: Self.base - 1, value: "x")).wait()
            }
            #expect(writeErr?.isSeek == true)
            let deleteErr = captureFileError { try repo.delete(from: Self.base - 1).wait() }
            #expect(deleteErr?.isSeek == true)
        }
    }
}

// MARK: - Boundary & seek errors

@Suite("Boundary & seek errors")
struct Boundaries {
    private func with1000(_ body: (StringRepo) throws -> Void) throws {
        try withStringRepo(seed: (0..<1000).map { "String \($0)" }, { repo, _ in try body(repo) })
    }

    @Test("find(id:) one past the end throws seekError")
    func findOffTheEnd() throws {
        try with1000 { repo in
            let e = captureFileError { _ = try repo.find(id: 1000).wait() }
            #expect(e?.isSeek == true)
        }
    }

    @Test("find(from:through: .max) throws seekError")
    func findThroughMax() throws {
        try with1000 { repo in
            let e = captureFileError { _ = try repo.find(from: 1, through: .max).wait() }
            #expect(e?.isSeek == true)
        }
    }

    @Test("find(from:through:) with through < from throws seekError mentioning 'below from'")
    func findThroughBelowFrom() throws {
        try with1000 { repo in
            let e = captureFileError { _ = try repo.find(from: 10, through: 9).wait() }
            #expect(e?.isSeek == true)
            #expect(e?.seekMessage?.contains("below from") == true)
        }
    }

    @Test("find(from: .max) throws seekError")
    func findFromMax() throws {
        try with1000 { repo in
            let e = captureFileError { _ = try repo.find(from: .max).wait() }
            #expect(e?.isSeek == true)
        }
    }
}

// MARK: - Binary search

@Suite("Binary search")
struct BinarySearch {
    /// `capacity` records whose value field is the zero-padded id — genuinely sorted.
    private func withSorted(_ capacity: Int, _ body: (StringRepo) throws -> Void) throws {
        try withStringRepo(seed: (0..<capacity).map { sortedKey($0) }, { repo, _ in try body(repo) })
    }

    @Test("future overload finds a present key")
    func futureFindsPresent() throws {
        try withSorted(1000) { repo in
            let hit = try repo.binarySearch(comparable: sortedKey(232), left: 0, right: 999, selector: \.value).wait()
            #expect(hit.id == 232)
            #expect(hit.value == sortedKey(232))
        }
    }

    @Test("promise overload finds a present key")
    func promiseFindsPresent() throws {
        try withSorted(1000) { repo in
            let promise = repo.eventLoop.makePromise(of: StringRepo.Model.self)
            repo.binarySearch(comparable: sortedKey(232), left: 0, right: 999, promise: promise, selector: \.value)
            let hit = try promise.futureResult.wait()
            #expect(hit.id == 232)
        }
    }

    @Test("future overload: target below all keys → NoExactMatchFound bracketed by the first record")
    func futureBelowAll() throws {
        try withSorted(100) { repo in
            do {
                // The empty string sorts below every "0…"-padded key.
                _ = try repo.binarySearch(comparable: "", left: 0, right: 99, selector: \.value).wait()
                Issue.record("expected NoExactMatchFound")
            } catch let miss as File.NoExactMatchFound<StringRepo.Model> {
                #expect(miss.left.id == 0)
                #expect(miss.right.id == 0)
            }
        }
    }

    @Test("future overload: target above all keys → NoExactMatchFound bracketed by the last record")
    func futureAboveAll() throws {
        try withSorted(100) { repo in
            do {
                _ = try repo.binarySearch(comparable: "zzzzzzzz", left: 0, right: 99, selector: \.value).wait()
                Issue.record("expected NoExactMatchFound")
            } catch let miss as File.NoExactMatchFound<StringRepo.Model> {
                #expect(miss.left.id == 99)
                #expect(miss.right.id == 99)
            }
        }
    }

    @Test("future overload: target strictly between present keys → NoExactMatchFound brackets it")
    func futureBetween() throws {
        // Values are even ids only, so any odd target is absent and lies between neighbors.
        try withStringRepo(seed: (0..<100).map { sortedKey($0 * 2) }) { repo, _ in
            do {
                _ = try repo.binarySearch(comparable: sortedKey(51), left: 0, right: 99, selector: \.value).wait()
                Issue.record("expected NoExactMatchFound")
            } catch let miss as File.NoExactMatchFound<StringRepo.Model> {
                #expect(miss.left.value < sortedKey(51))
                #expect(miss.right.value > sortedKey(51))
            }
        }
    }

    @Test("promise overload reports absent target as notFound (differs from the future overload)")
    func promiseAbsentIsNotFound() throws {
        try withStringRepo(seed: (0..<100).map { sortedKey($0 * 2) }) { repo, _ in
            let promise = repo.eventLoop.makePromise(of: StringRepo.Model.self)
            repo.binarySearch(comparable: sortedKey(51), left: 0, right: 99, promise: promise, selector: \.value)
            let e = captureFileError { _ = try promise.futureResult.wait() }
            #expect(e?.isNotFound == true)
        }
    }

    @Test("duplicate keys: returns some record carrying the target value")
    func duplicateKeys() throws {
        // ids 0..49 share key "00000010", ids 50..99 share "00000020".
        let values = (0..<100).map { $0 < 50 ? sortedKey(10) : sortedKey(20) }
        try withStringRepo(seed: values) { repo, _ in
            let hit = try repo.binarySearch(comparable: sortedKey(20), left: 0, right: 99, selector: \.value).wait()
            #expect(hit.value == sortedKey(20))
            #expect(hit.id >= 50)
        }
    }

    @Test("UNSORTED input: binary search fails to find a value that IS present (sorted-input precondition)")
    func unsortedInputIsUnreliable() throws {
        // Descending values violate the ascending-sorted precondition. Searching for
        // the maximum value (present at index 0) deterministically misses.
        try withStringRepo(seed: (0..<10).map { sortedKey(9 - $0) }) { repo, _ in
            do {
                _ = try repo.binarySearch(comparable: sortedKey(9), left: 0, right: 9, selector: \.value).wait()
                Issue.record("unexpectedly found a value in unsorted data — precondition assumptions changed")
            } catch is File.NoExactMatchFound<StringRepo.Model> {
                // Expected: the present value is not located because the data is not sorted.
            }
        }
    }

    @Test("future overload finds many present keys", arguments: [0, 1, 2, 499, 500, 501, 998, 999])
    func futureFindsMany(target: Int) throws {
        try withSorted(1000) { repo in
            let hit = try repo.binarySearch(comparable: sortedKey(target), left: 0, right: 999, selector: \.value).wait()
            #expect(hit.id == target)
        }
    }
}

// MARK: - Mutation contracts

@Suite("Mutation contracts")
struct MutationContracts {
    @Test("overwrite a record then read back the new value")
    func overwrite() throws {
        try withStringRepo(seed: (0..<1000).map { "String \($0)" }) { repo, _ in
            try repo.write(.init(id: 100, value: "Overwrite")).wait()
            try repo.sync().wait()
            let updated = try repo.find(id: 100).wait()
            #expect(updated.value == "Overwrite")
            // Neighbours untouched.
            let before = try repo.find(id: 99).wait()
            let after = try repo.find(id: 101).wait()
            #expect(before.value == "String 99")
            #expect(after.value == "String 101")
        }
    }

    @Test("write with a fieldSelector updates only the field and preserves surrounding bytes")
    func fieldSelectorPartialUpdate() throws {
        let recordSize = 20
        let field = 4...11                              // 8-byte indexed field
        // record: bytes 0..3 = 0xEE sentinel, field "AAAA\0...", bytes 12..19 = 0xEE.
        var raw = [UInt8](repeating: 0xEE, count: recordSize)
        for (j, b) in Array("AAAA".utf8).enumerated() { raw[field.lowerBound + j] = b }
        raw[field.lowerBound + 4] = 0                   // NUL terminator inside field

        try withRawStringRepo(recordSize: recordSize, fieldSelector: field, rawBytes: raw) { repo, fix in
            let initial = try repo.find(id: 0).wait()
            #expect(initial.value == "AAAA")
            try repo.write(.init(id: 0, value: "BB")).wait()
            try repo.sync().wait()
            let updated = try repo.find(id: 0).wait()
            #expect(updated.value == "BB")

            // Read the raw record back and confirm the sentinel bytes survived.
            let rawBack = try fix.client.read(fileHandle: fix.fileHandle, fromOffset: 0,
                                              byteCount: recordSize, allocator: .init(),
                                              eventLoop: fix.eventLoop).wait()
            let bytes = try #require(rawBack.getBytes(at: 0, length: recordSize))
            #expect(Array(bytes[0..<4]) == [0xEE, 0xEE, 0xEE, 0xEE])
            #expect(Array(bytes[12..<20]) == [UInt8](repeating: 0xEE, count: 8))
        }
    }

    @Test("write beyond end-of-file silently creates a zero-filled gap record (documented sharp edge)")
    func writeBeyondEndOfFileCreatesGap() throws {
        let capacity = 1000
        try withStringRepo(seed: (0..<capacity).map { "String \($0)" }) { repo, _ in
            // Writing well past EOF zero-fills the intervening record(s).
            try repo.write(.init(id: capacity + 1, value: "Skip")).wait()
            try repo.sync().wait()
            // The gap record at `capacity` now exists and reads back empty.
            let gap = try repo.find(id: capacity).wait()
            #expect(gap.value.isEmpty)
            let skip = try repo.find(id: capacity + 1).wait()
            #expect(skip.value == "Skip")
        }
    }

    @Test("append a correctly-ordered record grows the file")
    func appendInOrder() throws {
        let capacity = 1000
        try withStringRepo(seed: (0..<capacity).map { "String \($0)" }) { repo, _ in
            try repo.append([.init(id: capacity, value: "Append String")]).wait()
            try repo.sync().wait()
            let count = try repo.count().wait()
            #expect(count == capacity + 1)
            let appended = try repo.find(id: capacity).wait()
            #expect(appended.value == "Append String")
        }
    }

    @Test("append with the wrong id throws appendFailedIncorrectOrdering")
    func appendWrongOrder() throws {
        try withStringRepo(seed: (0..<1000).map { "String \($0)" }) { repo, _ in
            let e = captureFileError { try repo.append([.init(id: .max, value: "fail")]).wait() }
            #expect(e?.isAppendOrdering == true)
        }
    }

    @Test("append([]) is a no-op (regression: previously trapped on rows.first!)")
    func emptyAppendIsNoOp() throws {
        try withStringRepo(seed: (0..<10).map { "String \($0)" }) { repo, _ in
            try repo.append([]).wait()              // must not crash
            let count = try repo.count().wait()
            #expect(count == 10)                    // unchanged
        }
    }

    @Test("a write failure propagates as a failed future (regression: previously preconditionFailure)")
    func writeFailurePropagates() throws {
        try withStringRepo(seed: (0..<10).map { "String \($0)" }) { _, fix in
            let faulty = StringRepo(nioFileHandle: fix.fileHandle,
                                    nonBlockingFileIO: faultyWriteClient(base: fix.client),
                                    eventLoop: fix.eventLoop,
                                    recordSize: 100)
            // direct write surfaces the injected error rather than crashing
            #expect(throws: InjectedWriteError.self) {
                try faulty.write(.init(id: 0, value: "x")).wait()
            }
            // append of a correctly-ordered row reaches the write stage and also propagates
            #expect(throws: (any Error).self) {
                try faulty.append([.init(id: 10, value: "x")]).wait()
            }
        }
    }

    @Test("delete truncates at the record boundary; deleted ids then seek-error")
    func deleteTruncates() throws {
        try withStringRepo(seed: (0..<1000).map { "String \($0)" }) { repo, _ in
            try repo.delete(from: 100).wait()
            let count = try repo.count().wait()
            #expect(count == 100)
            let survivor = try repo.find(id: 99).wait()
            #expect(survivor.value == "String 99")
            let e = captureFileError { _ = try repo.find(id: 100).wait() }
            #expect(e?.isSeek == true)
        }
    }

    @Test("delete beyond end-of-file throws seekError")
    func deleteBeyondEnd() throws {
        try withStringRepo(seed: (0..<3).map { "String \($0)" }) { repo, _ in
            let e = captureFileError { try repo.delete(from: 5).wait() }
            #expect(e?.isSeek == true)
            #expect(e?.seekMessage?.contains("Cannot seek beyond end of file") == true)
        }
    }
}

// MARK: - Concurrency, data-race safety & the single-handle constraint

@Suite("Concurrency & data-race safety")
struct Concurrency {
    @Test("find(from:through:) spanning many chunks preserves order, count, and ids")
    func multiChunkOrdering() throws {
        // recordSize 100 → ~655 records per chunk; 2000 records forces multiple chunks
        // and exercises the migrated lock-protected accumulator (NIOLockedValueBox)
        // across chunk boundaries within a single, internally-sequential call.
        let capacity = 2000
        try withStringRepo(seed: (0..<capacity).map { "String \($0)" }) { repo, _ in
            let all = try repo.find(from: 0, through: capacity - 1).wait()
            #expect(all.count == capacity)
            #expect(all.map(\.id) == Array(0..<capacity))
            #expect(all.first?.value == "String 0")
            #expect(all.last?.value == "String \(capacity - 1)")
        }
    }

    @Test("sequential operations on one repo are reliable")
    func sequentialAccess() throws {
        try withStringRepo(seed: (0..<200).map { "String \($0)" }) { repo, _ in
            for i in 0..<200 {
                let r = try repo.find(id: i).wait()
                #expect(r.value == "String \(i)")
            }
        }
    }

    @Test("a repo serialises file access: concurrent operations on one handle may throw EBUSY")
    func singularHandleAccess() throws {
        // FileRepo shares ONE NIOFileHandle across every operation. As of SwiftNIO
        // 2.77 NIOFileHandle enforces *singular access* and throws
        // IOError(EBUSY, "file descriptor currently in use") on overlapping use — so
        // a parallel fan-out of operations against a single repo is unsupported and
        // fails intermittently. Documented here as a known, intermittent issue so the
        // limitation is visible rather than latent. (fltrDB's LMDB backend supports
        // unbounded concurrent readers via MVCC and is not subject to this.)
        let capacity = 200
        try withStringRepo(seed: (0..<capacity).map { "String \($0)" }) { repo, _ in
            withKnownIssue(
                "NIOFileHandle enforces singular access (NIO ≥ 2.77); a concurrent fan-out on one shared handle races with EBUSY",
                isIntermittent: true
            ) {
                let futures = (0..<capacity).map { repo.find(id: $0) }
                let results = try EventLoopFuture.whenAllSucceed(futures, on: repo.eventLoop).wait()
                #expect(results.count == capacity)
            }
        }
    }
}

// MARK: - Scale & property-based

@Suite("Scale & property-based")
struct Scale {
    @Test("10k-record round trip preserves every record")
    func tenThousandRoundTrip() throws {
        let capacity = 10_000
        let values = (0..<capacity).map { "String \($0)" }
        try withStringRepo(seed: values) { repo, _ in
            let count = try repo.count().wait()
            #expect(count == capacity)
            let all = try repo.find(from: 0, through: capacity - 1).wait()
            #expect(all.count == capacity)
            #expect(all.map(\.value) == values)
        }
    }

    @Test("deterministic random-access fuzz agrees with an in-memory model")
    func randomAccessFuzz() throws {
        let capacity = 1000
        let model = (0..<capacity).map { "String \($0)" }
        try withStringRepo(seed: model) { repo, _ in
            var rng = LCG(seed: 0x5EED_F11E)
            for _ in 0..<1000 {
                let id = rng.int(capacity)
                let record = try repo.find(id: id).wait()
                #expect(record.id == id)
                #expect(record.value == model[id])
            }
        }
    }

    @Test("append-grow then full read-back at moderate scale")
    func appendGrow() throws {
        try withStringRepo(seed: []) { repo, _ in
            let batch = (0..<500).map { StringRepo.Model(id: $0, value: "String \($0)") }
            try repo.append(batch).wait()
            try repo.sync().wait()
            let count = try repo.count().wait()
            #expect(count == 500)
            let all = try repo.find(from: 0, through: 499).wait()
            #expect(all.map(\.value) == batch.map(\.value))
        }
    }

    @Test("operations work across a range of record sizes", arguments: [8, 32, 64, 256, 4096])
    func variousRecordSizes(recordSize: Int) throws {
        let capacity = 200
        let values = (0..<capacity).map { "r\($0)" }     // all < 8 bytes, fits every size
        try withStringRepo(recordSize: recordSize, seed: values) { repo, _ in
            let count = try repo.count().wait()
            #expect(count == capacity)
            let middle = try repo.find(id: 123).wait()
            #expect(middle.value == "r123")
            let all = try repo.find(from: 0, through: capacity - 1).wait()
            #expect(all.count == capacity)
        }
    }
}

// MARK: - Header repo heights

@Suite("Header repo heights")
struct HeaderHeights {
    @Test("heights() reports the inclusive (lower, upper) logical height bounds")
    func heightsWithOffset() throws {
        let base = 800_000
        let capacity = 50
        let values = (0..<capacity).map { "h\(base + $0)" }
        let raw = encodeRecords(values, recordSize: 100)
        let fixture = try FileRepoFixture(seed: raw)
        defer { fixture.shutdown() }
        let repo = HeaderRepo(nioFileHandle: fixture.fileHandle,
                              nonBlockingFileIO: fixture.client,
                              eventLoop: fixture.eventLoop,
                              recordSize: 100,
                              offset: base)
        let heights = try repo.heights().wait()
        #expect(heights.lowerHeight == base)
        #expect(heights.upperHeight == base + capacity - 1)
    }
}
