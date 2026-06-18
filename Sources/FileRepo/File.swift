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

public enum File {}

public extension File {
    /// Opens (or creates, mode `0o600`) the file at `path` for reading and writing.
    /// Convenience alias for ``FileIOClient/live(path:)``.
    @inlinable
    static func open(path: String) async throws -> FileIOClient {
        try await FileIOClient.live(path: path)
    }

    /// Runs every close operation, logging — but not propagating — any error.
    @inlinable
    static func closeRecover(_ closes: @Sendable () async throws -> Void...) async {
        await self.closeRecover(closes)
    }

    @inlinable
    static func closeRecover(_ closes: [@Sendable () async throws -> Void]) async {
        do {
            try await self.close(closes)
        } catch {
            fileRepoLog.error("❌ close failed (recovered): \(error)")
        }
    }

    /// Runs every close operation, trapping on any error.
    @inlinable
    static func closeFail(_ closes: @Sendable () async throws -> Void...) async {
        await self.closeFail(closes)
    }

    @inlinable
    static func closeFail(_ closes: [@Sendable () async throws -> Void]) async {
        do {
            try await self.close(closes)
        } catch {
            preconditionFailure("\(error)")
        }
    }

    /// Runs every close operation, waiting for all to finish. Every operation is
    /// attempted even if an earlier one fails; if any fail, all failures are
    /// collected and rethrown together as a `CompoundError`.
    @inlinable
    static func close(_ closes: @Sendable () async throws -> Void...) async throws {
        try await self.close(closes)
    }

    @inlinable
    static func close(_ closes: [@Sendable () async throws -> Void]) async throws {
        var failures: [any Swift.Error] = []
        for close in closes {
            do {
                try await close()
            } catch {
                failures.append(error)
            }
        }

        if !failures.isEmpty {
            throw CompoundError(failures)
        }
    }
}

internal extension File {
    @usableFromInline
    struct CompoundError: Swift.Error, CustomStringConvertible {
        @usableFromInline
        let value: [any Swift.Error]

        @usableFromInline
        init(_ value: [any Swift.Error]) {
            precondition(!value.isEmpty)
            self.value = value
        }

        @usableFromInline
        var description: String {
            var str: [String] = [ "File.close(...) finished with errors:" ]
            for (i, e) in value.enumerated() {
                str.append("\n\t\(i):\t")
                str.append("\(e)")
            }

            return str.joined()
        }
    }
}
