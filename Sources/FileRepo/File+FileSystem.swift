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
import NIOFileSystem

public extension File {
    static func rename(file: String, to: String) async throws {
        _ = try? await FileSystem.shared.removeItem(at: FilePath(to))
        _ = try await FileSystem.shared.moveItem(at: FilePath(file), to: FilePath(to))
    }

    static func delete(file: String) async throws {
        _ = try await FileSystem.shared.removeItem(at: FilePath(file))
    }
}
