// SPDX-License-Identifier: MIT
import os

/// View with: log stream --predicate 'subsystem == "com.aliasviejo.mando"'
enum Log {
    private static let logger = Logger(subsystem: "com.aliasviejo.mando", category: "app")
    static func info(_ message: String) { logger.notice("\(message, privacy: .public)") }
}
