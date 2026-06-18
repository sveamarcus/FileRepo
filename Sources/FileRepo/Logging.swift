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

/// Package-wide logger. FileRepo never bootstraps the logging system (that is the
/// host application's responsibility); it logs to whatever `LogHandler` is installed
/// — swift-log's default is `stderr` at the `.info` level. Failures are logged at
/// `.error`; operational lifecycle events at `.debug` (off by default). Message
/// arguments are `@autoclosure`, so the interpolations below cost nothing when the
/// level is filtered out.
///
/// `@usableFromInline internal` (rather than `public`) so the `@inlinable` repository
/// methods that log can reference it across the module boundary. `Logging.Logger` is
/// `Sendable`, so this module-level `let` is data-race-safe under Swift 6.
@usableFromInline
let fileRepoLog = Logger(label: "com.fltrwallet.filerepo")
