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
import NIOFileSystem

public struct FileIOClient: Sendable {
    /// A single positional read. Performs one `pread`: it may return *fewer* than
    /// `byteCount` bytes when fewer remain before end-of-file, and an empty buffer
    /// (`readableBytes == 0`) at or past end-of-file.
    @usableFromInline
    let readChunk0: @Sendable (_ fromOffset: Int64, _ byteCount: Int) async throws -> ByteBuffer
    /// A positional write of every readable byte of `buffer` at the absolute offset.
    @usableFromInline
    let write0: @Sendable (_ buffer: ByteBuffer, _ toOffset: Int64) async throws -> Void
    /// The current size of the file in bytes.
    @usableFromInline
    let size0: @Sendable () async throws -> Int64
    /// Truncates or extends the file to `size` bytes (`ftruncate`).
    @usableFromInline
    let resize0: @Sendable (_ size: Int64) async throws -> Void
    /// Flushes buffered writes durably to disk (`fsync`).
    @usableFromInline
    let synchronize0: @Sendable () async throws -> Void
    /// Closes the underlying handle. Idempotent: a second call is a no-op.
    @usableFromInline
    let close0: @Sendable () async throws -> Void

    public init(
        readChunk0: @escaping @Sendable (_ fromOffset: Int64, _ byteCount: Int) async throws -> ByteBuffer,
        write0: @escaping @Sendable (_ buffer: ByteBuffer, _ toOffset: Int64) async throws -> Void,
        size0: @escaping @Sendable () async throws -> Int64,
        resize0: @escaping @Sendable (_ size: Int64) async throws -> Void,
        synchronize0: @escaping @Sendable () async throws -> Void,
        close0: @escaping @Sendable () async throws -> Void
    ) {
        self.readChunk0 = readChunk0
        self.write0 = write0
        self.size0 = size0
        self.resize0 = resize0
        self.synchronize0 = synchronize0
        self.close0 = close0
    }
}

// MARK: - Operations
public extension FileIOClient {
    /// One positional read (a single `pread`). May return fewer than `byteCount`
    /// bytes near end-of-file, and an empty buffer at/past end-of-file.
    @inlinable
    func readChunk(fromOffset offset: Int64, byteCount: Int) async throws -> ByteBuffer {
        try await self.readChunk0(offset, byteCount)
    }

    /// Reads up to `byteCount` bytes starting at `offset`, looping over `readChunk`
    /// to fill the request. Returns fewer than `byteCount` bytes **only** when
    /// end-of-file is reached first (and an empty buffer when `offset` is already
    /// at/past end-of-file) — the caller relies on that signal to detect EOF.
    @inlinable
    func read(fromOffset offset: Int64, byteCount: Int) async throws -> ByteBuffer {
        // Fast path: the common case is a single full `pread`, or an immediate EOF.
        var first = try await self.readChunk(fromOffset: offset, byteCount: byteCount)
        if first.readableBytes >= byteCount || first.readableBytes == 0 {
            return first
        }

        // Short read mid-file: assemble the remainder, stopping at a true EOF.
        var buffer = ByteBufferAllocator().buffer(capacity: byteCount)
        buffer.writeBuffer(&first)
        while buffer.readableBytes < byteCount {
            let read = buffer.readableBytes
            var chunk = try await self.readChunk(fromOffset: offset + Int64(read),
                                                 byteCount: byteCount - read)
            if chunk.readableBytes == 0 { break } // true end-of-file
            buffer.writeBuffer(&chunk)
        }
        return buffer
    }

    @inlinable
    func write(_ buffer: ByteBuffer, toOffset offset: Int64) async throws {
        try await self.write0(buffer, offset)
    }

    @inlinable
    func size() async throws -> Int64 {
        try await self.size0()
    }

    @inlinable
    func resize(to size: Int64) async throws {
        try await self.resize0(size)
    }

    @inlinable
    func synchronize() async throws {
        try await self.synchronize0()
    }

    @inlinable
    func close() async throws {
        try await self.close0()
    }
}

// MARK: - Live
public extension FileIOClient {
    /// Opens (or creates, mode `0o600`) the file at `path` for reading and writing
    /// via `NIOFileSystem` and returns a client backed by the resulting handle.
    static func live(path: String) async throws -> FileIOClient {
        let handle = try await FileSystem.shared.openFile(
            forReadingAndWritingAt: FilePath(path),
            options: .modifyFile(createIfNecessary: true,
                                 permissions: FilePermissions(rawValue: 0o600))
        )
        fileRepoLog.debug("📂 opened \(path)")

        return FileIOClient(
            readChunk0: { offset, byteCount in
                try await handle.readChunk(fromAbsoluteOffset: offset,
                                           length: .bytes(Int64(byteCount)))
            },
            write0: { buffer, offset in
                _ = try await handle.write(contentsOf: buffer, toAbsoluteOffset: offset)
            },
            size0: {
                try await handle.info().size
            },
            resize0: { size in
                try await handle.resize(to: .bytes(size))
            },
            synchronize0: {
                try await handle.synchronize()
            },
            close0: {
                try await handle.close()
                fileRepoLog.debug("💾 closed \(path)")
            }
        )
    }
}
