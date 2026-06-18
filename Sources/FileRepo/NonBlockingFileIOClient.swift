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
import NIOCore
import NIOPosix

public struct NonBlockingFileIOClient: Sendable {
    @usableFromInline
    let changeFileSize0: @Sendable (NIOFileHandle, Int64, EventLoop) -> EventLoopFuture<()>
    @usableFromInline
    let close0: @Sendable (NIOFileHandle, EventLoop) -> EventLoopFuture<()>
    @usableFromInline
    let openFile0: @Sendable (String, NIOFileHandle.Mode, NIOFileHandle.Flags, EventLoop) -> EventLoopFuture<NIOFileHandle>
    @usableFromInline
    let readChunkedFileHandle: @Sendable (NIOFileHandle,
                                          Int,
                                          Int,
                                          ByteBufferAllocator,
                                          EventLoop,
                                          @escaping @Sendable (ByteBuffer) -> EventLoopFuture<Void>) -> EventLoopFuture<Void>
    @usableFromInline
    let readChunkedFileOffset: @Sendable (NIOFileHandle,
                                          Int64,
                                          Int,
                                          Int,
                                          ByteBufferAllocator,
                                          EventLoop,
                                          @escaping @Sendable (ByteBuffer) -> EventLoopFuture<Void>) -> EventLoopFuture<Void>
    @usableFromInline
    let readChunkedFileRegion: @Sendable (FileRegion,
                                          Int,
                                          ByteBufferAllocator,
                                          EventLoop,
                                          @escaping @Sendable (ByteBuffer) -> EventLoopFuture<Void>) -> EventLoopFuture<Void>
    @usableFromInline
    let readFileHandle: @Sendable (NIOFileHandle, Int, ByteBufferAllocator, EventLoop) -> EventLoopFuture<ByteBuffer>
    @usableFromInline
    let readFileOffset: @Sendable (NIOFileHandle, Int64, Int, ByteBufferAllocator, EventLoop) -> EventLoopFuture<ByteBuffer>
    @usableFromInline
    let readFileRegion: @Sendable (FileRegion, ByteBufferAllocator, EventLoop) -> EventLoopFuture<ByteBuffer>
    @usableFromInline
    let readFileSize0: @Sendable (NIOFileHandle, EventLoop) -> EventLoopFuture<Int64>
    @usableFromInline
    let write0: @Sendable (NIOFileHandle, Int64, ByteBuffer, EventLoop) -> EventLoopFuture<()>
    @usableFromInline
    let sync0: @Sendable (NIOFileHandle, EventLoop) -> EventLoopFuture<Void>

    public init(changeFileSize0: @escaping @Sendable (NIOFileHandle, Int64, EventLoop) -> EventLoopFuture<()>,
                close0: @escaping @Sendable (NIOFileHandle, EventLoop) -> EventLoopFuture<()>,
                openFile0: @escaping @Sendable (String, NIOFileHandle.Mode, NIOFileHandle.Flags, EventLoop) -> EventLoopFuture<NIOFileHandle>,
                readChunkedFileHandle: @escaping @Sendable (NIOFileHandle, Int, Int, ByteBufferAllocator, EventLoop, @escaping @Sendable (ByteBuffer) -> EventLoopFuture<Void>) -> EventLoopFuture<Void>,
                readChunkedFileOffset: @escaping @Sendable (NIOFileHandle, Int64, Int, Int, ByteBufferAllocator, EventLoop, @escaping @Sendable (ByteBuffer) -> EventLoopFuture<Void>) -> EventLoopFuture<Void>,
                readChunkedFileRegion: @escaping @Sendable (FileRegion, Int, ByteBufferAllocator, EventLoop, @escaping @Sendable (ByteBuffer) -> EventLoopFuture<Void>) -> EventLoopFuture<Void>,
                readFileHandle: @escaping @Sendable (NIOFileHandle, Int, ByteBufferAllocator, EventLoop) -> EventLoopFuture<ByteBuffer>,
                readFileOffset: @escaping @Sendable (NIOFileHandle, Int64, Int, ByteBufferAllocator, EventLoop) -> EventLoopFuture<ByteBuffer>,
                readFileRegion: @escaping @Sendable (FileRegion, ByteBufferAllocator, EventLoop) -> EventLoopFuture<ByteBuffer>,
                readFileSize0: @escaping @Sendable (NIOFileHandle, EventLoop) -> EventLoopFuture<Int64>,
                write0: @escaping @Sendable (NIOFileHandle, Int64, ByteBuffer, EventLoop) -> EventLoopFuture<()>,
                sync0: @escaping @Sendable (NIOFileHandle, EventLoop) -> EventLoopFuture<Void>) {
        self.changeFileSize0 = changeFileSize0
        self.close0 = close0
        self.openFile0 = openFile0
        self.readChunkedFileHandle = readChunkedFileHandle
        self.readChunkedFileOffset = readChunkedFileOffset
        self.readChunkedFileRegion = readChunkedFileRegion
        self.readFileHandle = readFileHandle
        self.readFileOffset = readFileOffset
        self.readFileRegion = readFileRegion
        self.readFileSize0 = readFileSize0
        self.write0 = write0
        self.sync0 = sync0
    }
}

public extension NonBlockingFileIOClient {
    @inlinable
    func changeFileSize(fileHandle: NIOFileHandle,
                        size: Int64,
                        eventLoop: EventLoop) -> EventLoopFuture<()> {
        self.changeFileSize0(fileHandle, size, eventLoop)
    }

    @inlinable
    func close(fileHandle: NIOFileHandle, eventLoop: EventLoop) -> EventLoopFuture<()> {
        self.close0(fileHandle, eventLoop)
    }

    @inlinable
    func openFile(path: String,
                  mode: NIOFileHandle.Mode,
                  flags: NIOFileHandle.Flags,
                  eventLoop: EventLoop) -> EventLoopFuture<NIOFileHandle> {
        self.openFile0(path, mode, flags, eventLoop)
    }

    @inlinable
    func readChunked(fileHandle: NIOFileHandle,
                     byteCount: Int,
                     chunkSize: Int = NonBlockingFileIO.defaultChunkSize,
                     allocator: ByteBufferAllocator,
                     eventLoop: EventLoop,
                     chunkHandler: @escaping @Sendable (ByteBuffer) -> EventLoopFuture<Void>) -> EventLoopFuture<Void> {
        self.readChunkedFileHandle(fileHandle, byteCount, chunkSize, allocator, eventLoop, chunkHandler)
    }

    @inlinable
    func readChunked(fileHandle: NIOFileHandle,
                     fromOffset: Int64,
                     byteCount: Int,
                     chunkSize: Int = NonBlockingFileIO.defaultChunkSize,
                     allocator: ByteBufferAllocator,
                     eventLoop: EventLoop,
                     chunkHandler: @escaping @Sendable (ByteBuffer) -> EventLoopFuture<Void>) -> EventLoopFuture<Void> {
        self.readChunkedFileOffset(fileHandle, fromOffset, byteCount, chunkSize, allocator, eventLoop, chunkHandler)
    }

    @inlinable
    func readChunked(fileRegion: FileRegion,
                     chunkSize: Int = NonBlockingFileIO.defaultChunkSize,
                     allocator: ByteBufferAllocator,
                     eventLoop: EventLoop,
                     chunkHandler: @escaping @Sendable (ByteBuffer) -> EventLoopFuture<Void>) -> EventLoopFuture<Void> {
        self.readChunkedFileRegion(fileRegion, chunkSize, allocator, eventLoop, chunkHandler)
    }

    @inlinable
    func read(fileHandle: NIOFileHandle,
              byteCount: Int,
              allocator: ByteBufferAllocator,
              eventLoop: EventLoop) -> EventLoopFuture<ByteBuffer> {
        self.readFileHandle(fileHandle, byteCount, allocator, eventLoop)
    }

    @inlinable
    func read(fileHandle: NIOFileHandle,
              fromOffset fileOffset: Int64,
              byteCount: Int,
              allocator: ByteBufferAllocator,
              eventLoop: EventLoop) -> EventLoopFuture<ByteBuffer> {
        self.readFileOffset(fileHandle, fileOffset, byteCount, allocator, eventLoop)
    }

    @inlinable
    func read(fileRegion: FileRegion,
              allocator: ByteBufferAllocator,
              eventLoop: EventLoop) -> EventLoopFuture<ByteBuffer> {
        self.readFileRegion(fileRegion, allocator, eventLoop)
    }

    @inlinable
    func readFileSize(fileHandle: NIOFileHandle,
                      eventLoop: EventLoop) -> EventLoopFuture<Int64> {
        self.readFileSize0(fileHandle, eventLoop)
    }

    @inlinable
    func write(fileHandle: NIOFileHandle,
               toOffset: Int64,
               buffer: ByteBuffer,
               eventLoop: EventLoop) -> EventLoopFuture<()> {
        self.write0(fileHandle, toOffset, buffer, eventLoop)
    }

    @inlinable
    func sync(fileHandle: NIOFileHandle, eventLoop: EventLoop) -> EventLoopFuture<Void> {
        self.sync0(fileHandle, eventLoop)
    }
}

// MARK: Live
public extension NonBlockingFileIOClient {
    @inlinable
    static func live(_ threadPool: NIOThreadPool) -> Self {
        let io = NonBlockingFileIO(threadPool: threadPool)

        return NonBlockingFileIOClient(
            changeFileSize0: io.changeFileSize(fileHandle:size:eventLoop:),
            close0: { nioFileHandle, eventLoop in
                threadPool.runIfActive(eventLoop: eventLoop) {
                    try nioFileHandle.withUnsafeFileDescriptor {
                        _ = fsync($0)
                    }
                    try nioFileHandle.close()
                }
            },
            openFile0: io.openFile(path:mode:flags:eventLoop:),
            readChunkedFileHandle: io.readChunked(fileHandle:byteCount:chunkSize:allocator:eventLoop:chunkHandler:),
            readChunkedFileOffset: io.readChunked(fileHandle:fromOffset:byteCount:chunkSize:allocator:eventLoop:chunkHandler:),
            readChunkedFileRegion: io.readChunked(fileRegion:chunkSize:allocator:eventLoop:chunkHandler:),
            readFileHandle: io.read(fileHandle:byteCount:allocator:eventLoop:),
            readFileOffset: io.read(fileHandle:fromOffset:byteCount:allocator:eventLoop:),
            readFileRegion: io.read(fileRegion:allocator:eventLoop:),
            readFileSize0: io.readFileSize(fileHandle:eventLoop:),
            write0: io.write(fileHandle:toOffset:buffer:eventLoop:),
            sync0: { fileHandle, eventLoop in
                threadPool.runIfActive(eventLoop: eventLoop) {
                    try fileHandle.withUnsafeFileDescriptor { fd in
                        for _ in (0..<100) {
                            if fsync(fd) > 0 {
                                usleep(1)
                                continue
                            } else {
                                break
                            }
                        }
                    }
                }
            }
        )
    }
}
