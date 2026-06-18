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
// file used as a linear database for Bitcoin blockchain storage. Migrated from the
// NIO `EventLoopFuture` API to `NIOFileSystem` + `async`/`await`. Beyond the
// happy-path coverage, these tests attack boundaries, corrupted files, offset
// arithmetic, the sorted-input precondition of binary search, mutation contracts,
// concurrency, and scale.
//
// RUN:  swift test
// The tests are now straight-line `async`/`await` (no blocking `.wait()`), so they
// no longer deadlock Swift Testing's cooperative pool and run safely in parallel.
// Each test owns an isolated temp file under /tmp. (Because the package lives on
// iCloud Drive, build/test into a /tmp scratch path — `swift test --scratch-path
// /tmp/FileRepo-test` — so `codesign` does not reject the .xctest bundle.)
//
// Honesty notes (verified by these tests):
//  * `append([])` is a no-op (it does not trap on an empty collection).
//  * `append`/`write` propagate I/O failures as thrown errors (not `preconditionFailure`).
//  * `binarySearch` requires the selected field to be sorted ascending; on unsorted
//    input it can fail to find a present value.
//  * `write` beyond end-of-file silently creates a zero-filled gap record.
//  * A single repo now serves concurrent reads (the old single-`NIOFileHandle`
//    EBUSY ceiling is gone with `NIOFileSystem`'s positional reads).
//
import FileRepo
import Foundation
import NIOCore
import Testing

// MARK: - Core round-trip & reads

@Suite("Core round-trip & reads")
struct CoreReads {
    @Test("count() returns the number of records", arguments: [0, 1, 100, 1000])
    func countReturnsRecordCount(capacity: Int) async throws {
        let values = (0..<capacity).map { "rec \($0)" }
        try await withStringRepo(seed: values) { repo, _ in
            let count = try await repo.count()
            #expect(count == capacity)
        }
    }

    @Test("find(id:) returns each record by id")
    func findEachRecord() async throws {
        let capacity = 500
        let values = (0..<capacity).map { "String \($0)" }
        try await withStringRepo(seed: values) { repo, _ in
            for i in 0..<capacity {
                let record = try await repo.find(id: i)
                #expect(record.id == i)
                #expect(record.value == "String \(i)")
            }
        }
    }

    @Test("find(from:) returns the tail of the file")
    func findFromTail() async throws {
        let capacity = 1000
        let values = (0..<capacity).map { "String \($0)" }
        try await withStringRepo(seed: values) { repo, _ in
            let records = try await repo.find(from: 1)
            #expect(records.count == capacity - 1)
            for i in 1..<capacity {
                #expect(records[i - 1].id == i)
                #expect(records[i - 1].value == "String \(i)")
            }
        }
    }

    @Test("range() returns [0, count)")
    func rangeBounds() async throws {
        try await withStringRepo(seed: (0..<250).map { "r\($0)" }) { repo, _ in
            let range = try await repo.range()
            #expect(range == 0..<250)
        }
    }

    @Test("find(from:through:) round-trips the whole file in order")
    func fullFileRoundTrip() async throws {
        let values = (0..<300).map { "String \($0)" }
        try await withStringRepo(seed: values) { repo, _ in
            let all = try await repo.find(from: 0, through: 299)
            #expect(all.map(\.value) == values)
            #expect(all.map(\.id) == Array(0..<300))
        }
    }
}

// MARK: - Corruption & integrity

@Suite("Corruption & integrity")
struct Corruption {
    @Test("count() throws fileCorruptionError when file size is not a multiple of recordSize")
    func misalignedFileSize() async throws {
        // 250 bytes with recordSize 100 = 2 whole records + a 50-byte fragment.
        try await withRawStringRepo(recordSize: 100, rawBytes: [UInt8](repeating: 0, count: 250)) { repo, _ in
            let e = await captureFileError { try await repo.count() }
            #expect(e?.isCorruption == true)
        }
    }

    @Test("count() is 0 and range() throws noDataFoundFileEmpty on an empty file")
    func emptyFile() async throws {
        try await withStringRepo(seed: []) { repo, _ in
            let count = try await repo.count()
            #expect(count == 0)
            let e = await captureFileError { try await repo.range() }
            #expect(e?.isEmptyFile == true)
        }
    }

    @Test("find(id:) surfaces a decode failure as readError on a record with no NUL terminator")
    func decodeFailureSurfaces() async throws {
        // A single 100-byte record full of 0xFF: no NUL terminator, so the string
        // decode returns nil and the repo throws readError.
        try await withRawStringRepo(recordSize: 100, rawBytes: [UInt8](repeating: 0xFF, count: 100)) { repo, _ in
            let count = try await repo.count()
            #expect(count == 1)
            let e = await captureFileError { _ = try await repo.find(id: 0) }
            #expect(e?.isRead == true)
        }
    }

    @Test("find(from:through:) propagates a mid-stream decode failure")
    func chunkedDecodeFailurePropagates() async throws {
        // 3 records: record 1 is corrupt (no terminator). find over the range must
        // fail with the decode error, not silently drop the record.
        var raw = [UInt8]()
        raw += encodeRecords(["alpha"], recordSize: 100)
        raw += [UInt8](repeating: 0xFF, count: 100)
        raw += encodeRecords(["gamma"], recordSize: 100)
        try await withRawStringRepo(recordSize: 100, rawBytes: raw) { repo, _ in
            let e = await captureFileError { _ = try await repo.find(from: 0, through: 2) }
            #expect(e?.isRead == true)
        }
    }
}

// MARK: - Offset arithmetic (Bitcoin height base)

@Suite("Offset arithmetic (Bitcoin height base)")
struct OffsetArithmetic {
    static let base = 500_000
    static let capacity = 100

    private func withHeightRepo(_ body: (StringRepo) async throws -> Void) async throws {
        let values = (0..<Self.capacity).map { "block \(Self.base + $0)" }
        try await withStringRepo(offset: Self.base, seed: values, { repo, _ in try await body(repo) })
    }

    @Test("find below the offset throws seekError citing the offset")
    func findBelowOffset() async throws {
        try await withHeightRepo { repo in
            let e = await captureFileError { _ = try await repo.find(id: Self.base - 1) }
            #expect(e?.isSeek == true)
            #expect(e?.seekMessage?.contains("Cannot read below offset [\(Self.base)]") == true)
        }
    }

    @Test("find at the offset (logical id 0) decodes the logical id, not the physical index")
    func findAtOffset() async throws {
        try await withHeightRepo { repo in
            let record = try await repo.find(id: Self.base)
            #expect(record.id == Self.base)
            #expect(record.value == "block \(Self.base)")
        }
    }

    @Test("find at offset+count-1 (file maximum) succeeds")
    func findAtFileMaximum() async throws {
        try await withHeightRepo { repo in
            let last = Self.base + Self.capacity - 1
            let record = try await repo.find(id: last)
            #expect(record.id == last)
        }
    }

    @Test("find beyond offset+count throws seekError with offset-adjusted message")
    func findBeyondFileMaximum() async throws {
        try await withHeightRepo { repo in
            let beyond = Self.base + Self.capacity        // 500100
            let e = await captureFileError { _ = try await repo.find(id: beyond) }
            #expect(e?.isSeek == true)
            // "Tried to seek record 500100 (file maximum 500099)"
            #expect(e?.seekMessage?.contains("seek record \(beyond)") == true)
            #expect(e?.seekMessage?.contains("file maximum \(Self.base + Self.capacity - 1)") == true)
        }
    }

    @Test("find(from:through:) decodes correct logical ids despite chunking")
    func rangeReadLogicalIds() async throws {
        try await withHeightRepo { repo in
            let from = Self.base + 10
            let through = Self.base + 19
            let records = try await repo.find(from: from, through: through)
            #expect(records.map(\.id) == Array(from...through))
            #expect(records.first?.value == "block \(from)")
            #expect(records.last?.value == "block \(through)")
        }
    }

    @Test("range() reports logical (height) bounds")
    func rangeWithOffset() async throws {
        try await withHeightRepo { repo in
            let range = try await repo.range()
            #expect(range == Self.base..<(Self.base + Self.capacity))
        }
    }

    @Test("write and delete below the offset throw seekError")
    func mutationBelowOffset() async throws {
        try await withHeightRepo { repo in
            let writeErr = await captureFileError {
                try await repo.write(.init(id: Self.base - 1, value: "x"))
            }
            #expect(writeErr?.isSeek == true)
            let deleteErr = await captureFileError { try await repo.delete(from: Self.base - 1) }
            #expect(deleteErr?.isSeek == true)
        }
    }
}

// MARK: - Boundary & seek errors

@Suite("Boundary & seek errors")
struct Boundaries {
    private func with1000(_ body: (StringRepo) async throws -> Void) async throws {
        try await withStringRepo(seed: (0..<1000).map { "String \($0)" }, { repo, _ in try await body(repo) })
    }

    @Test("find(id:) one past the end throws seekError")
    func findOffTheEnd() async throws {
        try await with1000 { repo in
            let e = await captureFileError { _ = try await repo.find(id: 1000) }
            #expect(e?.isSeek == true)
        }
    }

    @Test("find(from:through: .max) throws seekError")
    func findThroughMax() async throws {
        try await with1000 { repo in
            let e = await captureFileError { _ = try await repo.find(from: 1, through: .max) }
            #expect(e?.isSeek == true)
        }
    }

    @Test("find(from:through:) with through < from throws seekError mentioning 'below from'")
    func findThroughBelowFrom() async throws {
        try await with1000 { repo in
            let e = await captureFileError { _ = try await repo.find(from: 10, through: 9) }
            #expect(e?.isSeek == true)
            #expect(e?.seekMessage?.contains("below from") == true)
        }
    }

    @Test("find(from: .max) throws seekError")
    func findFromMax() async throws {
        try await with1000 { repo in
            let e = await captureFileError { _ = try await repo.find(from: .max) }
            #expect(e?.isSeek == true)
        }
    }
}

// MARK: - Binary search

@Suite("Binary search")
struct BinarySearch {
    /// `capacity` records whose value field is the zero-padded id — genuinely sorted.
    private func withSorted(_ capacity: Int, _ body: (StringRepo) async throws -> Void) async throws {
        try await withStringRepo(seed: (0..<capacity).map { sortedKey($0) }, { repo, _ in try await body(repo) })
    }

    @Test("finds a present key")
    func findsPresent() async throws {
        try await withSorted(1000) { repo in
            let hit = try await repo.binarySearch(comparable: sortedKey(232), left: 0, right: 999, selector: \.value)
            #expect(hit.id == 232)
            #expect(hit.value == sortedKey(232))
        }
    }

    @Test("target below all keys → NoExactMatchFound bracketed by the first record")
    func belowAll() async throws {
        try await withSorted(100) { repo in
            do {
                // The empty string sorts below every "0…"-padded key.
                _ = try await repo.binarySearch(comparable: "", left: 0, right: 99, selector: \.value)
                Issue.record("expected NoExactMatchFound")
            } catch let miss as File.NoExactMatchFound<StringRepo.Model> {
                #expect(miss.left.id == 0)
                #expect(miss.right.id == 0)
            }
        }
    }

    @Test("target above all keys → NoExactMatchFound bracketed by the last record")
    func aboveAll() async throws {
        try await withSorted(100) { repo in
            do {
                _ = try await repo.binarySearch(comparable: "zzzzzzzz", left: 0, right: 99, selector: \.value)
                Issue.record("expected NoExactMatchFound")
            } catch let miss as File.NoExactMatchFound<StringRepo.Model> {
                #expect(miss.left.id == 99)
                #expect(miss.right.id == 99)
            }
        }
    }

    @Test("target strictly between present keys → NoExactMatchFound brackets it")
    func between() async throws {
        // Values are even ids only, so any odd target is absent and lies between neighbors.
        try await withStringRepo(seed: (0..<100).map { sortedKey($0 * 2) }) { repo, _ in
            do {
                _ = try await repo.binarySearch(comparable: sortedKey(51), left: 0, right: 99, selector: \.value)
                Issue.record("expected NoExactMatchFound")
            } catch let miss as File.NoExactMatchFound<StringRepo.Model> {
                #expect(miss.left.value < sortedKey(51))
                #expect(miss.right.value > sortedKey(51))
            }
        }
    }

    @Test("duplicate keys: returns some record carrying the target value")
    func duplicateKeys() async throws {
        // ids 0..49 share key "00000010", ids 50..99 share "00000020".
        let values = (0..<100).map { $0 < 50 ? sortedKey(10) : sortedKey(20) }
        try await withStringRepo(seed: values) { repo, _ in
            let hit = try await repo.binarySearch(comparable: sortedKey(20), left: 0, right: 99, selector: \.value)
            #expect(hit.value == sortedKey(20))
            #expect(hit.id >= 50)
        }
    }

    @Test("UNSORTED input: binary search fails to find a value that IS present (sorted-input precondition)")
    func unsortedInputIsUnreliable() async throws {
        // Descending values violate the ascending-sorted precondition. Searching for
        // the maximum value (present at index 0) deterministically misses.
        try await withStringRepo(seed: (0..<10).map { sortedKey(9 - $0) }) { repo, _ in
            do {
                _ = try await repo.binarySearch(comparable: sortedKey(9), left: 0, right: 9, selector: \.value)
                Issue.record("unexpectedly found a value in unsorted data — precondition assumptions changed")
            } catch is File.NoExactMatchFound<StringRepo.Model> {
                // Expected: the present value is not located because the data is not sorted.
            }
        }
    }

    @Test("finds many present keys", arguments: [0, 1, 2, 499, 500, 501, 998, 999])
    func findsMany(target: Int) async throws {
        try await withSorted(1000) { repo in
            let hit = try await repo.binarySearch(comparable: sortedKey(target), left: 0, right: 999, selector: \.value)
            #expect(hit.id == target)
        }
    }
}

// MARK: - Mutation contracts

@Suite("Mutation contracts")
struct MutationContracts {
    @Test("overwrite a record then read back the new value")
    func overwrite() async throws {
        try await withStringRepo(seed: (0..<1000).map { "String \($0)" }) { repo, _ in
            try await repo.write(.init(id: 100, value: "Overwrite"))
            try await repo.sync()
            let updated = try await repo.find(id: 100)
            #expect(updated.value == "Overwrite")
            // Neighbours untouched.
            let before = try await repo.find(id: 99)
            let after = try await repo.find(id: 101)
            #expect(before.value == "String 99")
            #expect(after.value == "String 101")
        }
    }

    @Test("write with a fieldSelector updates only the field and preserves surrounding bytes")
    func fieldSelectorPartialUpdate() async throws {
        let recordSize = 20
        let field = 4...11                              // 8-byte indexed field
        // record: bytes 0..3 = 0xEE sentinel, field "AAAA\0...", bytes 12..19 = 0xEE.
        var raw = [UInt8](repeating: 0xEE, count: recordSize)
        for (j, b) in Array("AAAA".utf8).enumerated() { raw[field.lowerBound + j] = b }
        raw[field.lowerBound + 4] = 0                   // NUL terminator inside field

        try await withRawStringRepo(recordSize: recordSize, fieldSelector: field, rawBytes: raw) { repo, fix in
            let initial = try await repo.find(id: 0)
            #expect(initial.value == "AAAA")
            try await repo.write(.init(id: 0, value: "BB"))
            try await repo.sync()
            let updated = try await repo.find(id: 0)
            #expect(updated.value == "BB")

            // Read the raw record back and confirm the sentinel bytes survived.
            let rawBack = try await fix.io.read(fromOffset: 0, byteCount: recordSize)
            let bytes = try #require(rawBack.getBytes(at: 0, length: recordSize))
            #expect(Array(bytes[0..<4]) == [0xEE, 0xEE, 0xEE, 0xEE])
            #expect(Array(bytes[12..<20]) == [UInt8](repeating: 0xEE, count: 8))
        }
    }

    @Test("write beyond end-of-file silently creates a zero-filled gap record (documented sharp edge)")
    func writeBeyondEndOfFileCreatesGap() async throws {
        let capacity = 1000
        try await withStringRepo(seed: (0..<capacity).map { "String \($0)" }) { repo, _ in
            // Writing well past EOF zero-fills the intervening record(s).
            try await repo.write(.init(id: capacity + 1, value: "Skip"))
            try await repo.sync()
            // The gap record at `capacity` now exists and reads back empty.
            let gap = try await repo.find(id: capacity)
            #expect(gap.value.isEmpty)
            let skip = try await repo.find(id: capacity + 1)
            #expect(skip.value == "Skip")
        }
    }

    @Test("append a correctly-ordered record grows the file")
    func appendInOrder() async throws {
        let capacity = 1000
        try await withStringRepo(seed: (0..<capacity).map { "String \($0)" }) { repo, _ in
            try await repo.append([.init(id: capacity, value: "Append String")])
            try await repo.sync()
            let count = try await repo.count()
            #expect(count == capacity + 1)
            let appended = try await repo.find(id: capacity)
            #expect(appended.value == "Append String")
        }
    }

    @Test("append with the wrong id throws appendFailedIncorrectOrdering")
    func appendWrongOrder() async throws {
        try await withStringRepo(seed: (0..<1000).map { "String \($0)" }) { repo, _ in
            let e = await captureFileError { try await repo.append([.init(id: .max, value: "fail")]) }
            #expect(e?.isAppendOrdering == true)
        }
    }

    @Test("append([]) is a no-op (regression: previously trapped on rows.first!)")
    func emptyAppendIsNoOp() async throws {
        try await withStringRepo(seed: (0..<10).map { "String \($0)" }) { repo, _ in
            try await repo.append([])              // must not crash
            let count = try await repo.count()
            #expect(count == 10)                    // unchanged
        }
    }

    @Test("a write failure propagates as a thrown error (regression: previously preconditionFailure)")
    func writeFailurePropagates() async throws {
        try await withStringRepo(seed: (0..<10).map { "String \($0)" }) { _, fix in
            let faulty = StringRepo(io: faultyWriteClient(base: fix.io),
                                    recordSize: 100)
            // direct write surfaces the injected error rather than crashing
            await #expect(throws: InjectedWriteError.self) {
                try await faulty.write(.init(id: 0, value: "x"))
            }
            // append of a correctly-ordered row reaches the write stage and also propagates
            await #expect(throws: (any Error).self) {
                try await faulty.append([.init(id: 10, value: "x")])
            }
        }
    }

    @Test("delete truncates at the record boundary; deleted ids then seek-error")
    func deleteTruncates() async throws {
        try await withStringRepo(seed: (0..<1000).map { "String \($0)" }) { repo, _ in
            try await repo.delete(from: 100)
            let count = try await repo.count()
            #expect(count == 100)
            let survivor = try await repo.find(id: 99)
            #expect(survivor.value == "String 99")
            let e = await captureFileError { _ = try await repo.find(id: 100) }
            #expect(e?.isSeek == true)
        }
    }

    @Test("delete beyond end-of-file throws seekError")
    func deleteBeyondEnd() async throws {
        try await withStringRepo(seed: (0..<3).map { "String \($0)" }) { repo, _ in
            let e = await captureFileError { try await repo.delete(from: 5) }
            #expect(e?.isSeek == true)
            #expect(e?.seekMessage?.contains("Cannot seek beyond end of file") == true)
        }
    }
}

// MARK: - Concurrency, data-race safety & I/O seam

@Suite("Concurrency & data-race safety")
struct Concurrency {
    @Test("find(from:through:) spanning many chunks preserves order, count, and ids")
    func multiChunkOrdering() async throws {
        // recordSize 100 → ~655 records per chunk; 2000 records forces multiple chunks
        // and exercises the migrated local accumulator across chunk boundaries within a
        // single, internally-sequential call.
        let capacity = 2000
        try await withStringRepo(seed: (0..<capacity).map { "String \($0)" }) { repo, _ in
            let all = try await repo.find(from: 0, through: capacity - 1)
            #expect(all.count == capacity)
            #expect(all.map(\.id) == Array(0..<capacity))
            #expect(all.first?.value == "String 0")
            #expect(all.last?.value == "String \(capacity - 1)")
        }
    }

    @Test("sequential operations on one repo are reliable")
    func sequentialAccess() async throws {
        try await withStringRepo(seed: (0..<200).map { "String \($0)" }) { repo, _ in
            for i in 0..<200 {
                let r = try await repo.find(id: i)
                #expect(r.value == "String \(i)")
            }
        }
    }

    @Test("concurrent find fan-out on one repo returns correct results")
    func concurrentFanOut() async throws {
        // With NIOFileSystem the repo's single handle serves positional reads
        // concurrently — the old single-`NIOFileHandle` EBUSY ceiling (singular access
        // since NIO 2.77) is gone. A parallel fan-out over one repo must now succeed.
        let capacity = 200
        try await withStringRepo(seed: (0..<capacity).map { "String \($0)" }) { repo, _ in
            let results = try await withThrowingTaskGroup(of: (Int, String).self) { group in
                for i in 0..<capacity {
                    group.addTask {
                        let r = try await repo.find(id: i)
                        return (r.id, r.value)
                    }
                }
                var acc: [Int: String] = [:]
                for try await (id, value) in group { acc[id] = value }
                return acc
            }
            #expect(results.count == capacity)
            for i in 0..<capacity { #expect(results[i] == "String \(i)") }
        }
    }
}

// MARK: - I/O seam (FileIOClient)

@Suite("FileIOClient seam")
struct IOSeam {
    @Test("read() fill loop assembles short single-pread reads and stops at true EOF")
    func fillLoopAssemblesShortReads() async throws {
        // Seed 100 known bytes, then cap each readChunk at 16 bytes so a 100-byte read
        // must loop ~7 times. A read at/past EOF must return an empty buffer (not spin).
        let seed = (0..<100).map { UInt8($0) }
        try await withRawStringRepo(recordSize: 100, rawBytes: seed) { _, fix in
            let capped = cappedReadClient(base: fix.io, cap: 16)
            let full = try await capped.read(fromOffset: 0, byteCount: 100)
            #expect(full.readableBytes == 100)
            #expect(full.getBytes(at: 0, length: 100) == seed)

            let pastEOF = try await capped.read(fromOffset: 100, byteCount: 50)
            #expect(pastEOF.readableBytes == 0)

            // A read straddling EOF returns only the bytes that exist.
            let straddle = try await capped.read(fromOffset: 90, byteCount: 50)
            #expect(straddle.readableBytes == 10)
            #expect(straddle.getBytes(at: 0, length: 10) == Array(seed[90..<100]))
        }
    }

    @Test("opening a pre-existing file via .live preserves its records (no truncation)")
    func liveOpenPreservesExistingFile() async throws {
        let path = "/tmp/filerepo_persist_\(UUID().uuidString)"

        // Create, seed, and close.
        let io1 = try await FileIOClient.live(path: path)
        let repo1 = StringRepo(io: io1, recordSize: 100)
        try await repo1.append((0..<10).map { StringRepo.Model(id: $0, value: "String \($0)") })
        try await repo1.sync()
        try await io1.close()

        // Reopen the SAME path and confirm the records survived (modifyFile, not truncate).
        let io2 = try await FileIOClient.live(path: path)
        let repo2 = StringRepo(io: io2, recordSize: 100)
        let count = try await repo2.count()
        #expect(count == 10)
        let five = try await repo2.find(id: 5)
        #expect(five.value == "String 5")
        try await io2.close()

        try? await File.delete(file: path)
    }

    @Test("close() propagates a synchronize failure but still closes the handle (no leaked-fd trap)")
    func closePropagatesSyncFailureWithoutLeak() async throws {
        try await withStringRepo(seed: (0..<3).map { "r\($0)" }) { _, fix in
            // synchronize() throws; close delegates to the real handle, so it IS closed.
            let faulty = StringRepo(io: faultySyncClient(base: fix.io), recordSize: 100)
            await #expect(throws: InjectedSyncError.self) {
                try await faulty.close()
            }
            // The fixture's later idempotent close must not trap on a leaked descriptor.
        }
    }

    @Test("rename then delete round-trips through the filesystem helpers")
    func renameAndDelete() async throws {
        let from = "/tmp/filerepo_rename_a_\(UUID().uuidString)"
        let to = "/tmp/filerepo_rename_b_\(UUID().uuidString)"

        let io = try await FileIOClient.live(path: from)
        let repo = StringRepo(io: io, recordSize: 100)
        try await repo.append((0..<5).map { StringRepo.Model(id: $0, value: "String \($0)") })
        try await repo.sync()
        try await io.close()

        try await File.rename(file: from, to: to)

        let reopened = try await FileIOClient.live(path: to)
        let repo2 = StringRepo(io: reopened, recordSize: 100)
        #expect(try await repo2.count() == 5)
        try await reopened.close()

        try await File.delete(file: to)
        // The destination is now gone: reopening creates a fresh (empty) file.
        let fresh = try await FileIOClient.live(path: to)
        let repo3 = StringRepo(io: fresh, recordSize: 100)
        #expect(try await repo3.count() == 0)
        try await fresh.close()
        try? await File.delete(file: to)
    }
}

// MARK: - Scale & property-based

@Suite("Scale & property-based")
struct Scale {
    @Test("10k-record round trip preserves every record")
    func tenThousandRoundTrip() async throws {
        let capacity = 10_000
        let values = (0..<capacity).map { "String \($0)" }
        try await withStringRepo(seed: values) { repo, _ in
            let count = try await repo.count()
            #expect(count == capacity)
            let all = try await repo.find(from: 0, through: capacity - 1)
            #expect(all.count == capacity)
            #expect(all.map(\.value) == values)
        }
    }

    @Test("deterministic random-access fuzz agrees with an in-memory model")
    func randomAccessFuzz() async throws {
        let capacity = 1000
        let model = (0..<capacity).map { "String \($0)" }
        try await withStringRepo(seed: model) { repo, _ in
            var rng = LCG(seed: 0x5EED_F11E)
            for _ in 0..<1000 {
                let id = rng.int(capacity)
                let record = try await repo.find(id: id)
                #expect(record.id == id)
                #expect(record.value == model[id])
            }
        }
    }

    @Test("append-grow then full read-back at moderate scale")
    func appendGrow() async throws {
        try await withStringRepo(seed: []) { repo, _ in
            let batch = (0..<500).map { StringRepo.Model(id: $0, value: "String \($0)") }
            try await repo.append(batch)
            try await repo.sync()
            let count = try await repo.count()
            #expect(count == 500)
            let all = try await repo.find(from: 0, through: 499)
            #expect(all.map(\.value) == batch.map(\.value))
        }
    }

    @Test("operations work across a range of record sizes", arguments: [8, 32, 64, 256, 4096])
    func variousRecordSizes(recordSize: Int) async throws {
        let capacity = 200
        let values = (0..<capacity).map { "r\($0)" }     // all < 8 bytes, fits every size
        try await withStringRepo(recordSize: recordSize, seed: values) { repo, _ in
            let count = try await repo.count()
            #expect(count == capacity)
            let middle = try await repo.find(id: 123)
            #expect(middle.value == "r123")
            let all = try await repo.find(from: 0, through: capacity - 1)
            #expect(all.count == capacity)
        }
    }
}

// MARK: - Header repo heights

@Suite("Header repo heights")
struct HeaderHeights {
    @Test("heights() reports the inclusive (lower, upper) logical height bounds")
    func heightsWithOffset() async throws {
        let base = 800_000
        let capacity = 50
        let values = (0..<capacity).map { "h\(base + $0)" }
        let raw = encodeRecords(values, recordSize: 100)
        let fixture = try await FileRepoFixture(seed: raw)
        do {
            let repo = HeaderRepo(io: fixture.io,
                                  recordSize: 100,
                                  offset: base)
            let heights = try await repo.heights()
            #expect(heights.lowerHeight == base)
            #expect(heights.upperHeight == base + capacity - 1)
            await fixture.shutdown()
        } catch {
            await fixture.shutdown()
            throw error
        }
    }
}
