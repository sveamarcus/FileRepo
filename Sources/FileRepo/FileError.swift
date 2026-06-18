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
#if canImport(CoreFoundation)
import CoreFoundation
#endif

public extension File {
    enum Error: Swift.Error {
        case appendFailedIncorrectOrdering
        case compactHeaderMissing(id: Int)
        case fileClosedError
        case fileCorruptionError(event: StaticString)
        case illegalArgument
        case noDataFoundFileEmpty(String)
        case noMatchingPredicate(event: StaticString)
        case notFound(message: StaticString)
        case readError(message: String, event: StaticString)
        case seekError(message: String, event: StaticString)
    }

    struct NoExactMatchFound<T: Sendable>: Swift.Error {
        public let left: T
        public let right: T

        public init(left: T, right: T) {
            self.left = left
            self.right = right
        }
    }
    
    static var cError: String {
        #if canImport(CoreFoundation)
        String(cString: strerror(errno))
        #else
        String("C Error #\(errno)")
        #endif
    }
}

extension File.Error: CustomStringConvertible {
    public var errorDescription: String? {
        description
    }
    
    public var description: String {
        switch self {
        case .appendFailedIncorrectOrdering: return "File in invalid state for appending record, illegal sequence"
        case .compactHeaderMissing: return "Loading compact filter header resulted in empty/missing record"
        case .fileClosedError: return "File closed error"
        case .fileCorruptionError(let event): return "File corruption error during event \(event)"
        case .illegalArgument: return "Function called with an illegal or invalid argument"
        case .noMatchingPredicate(let event): return "No model record matches predicate during event \(event)"
        case .notFound(message: let event): return "File not found error during event \(event)"
        case .noDataFoundFileEmpty(let model): return "No data found, file empty for type \(model)"
        case .readError(message: let msg, event: let event): return "File read error (\(msg)) during event \(event)"
        case .seekError(message: let msg, event: let event): return "File seek error (\(msg)) during event \(event)"
        }
    }
}

#if canImport(Foundation)
import protocol Foundation.LocalizedError
extension File.Error: LocalizedError {}
#endif
