import Foundation

/// Numbered-argument string expansion. Keys are written in Chinese directly.
public func CWL(_ key: String, _ arguments: [String] = []) -> String {
    guard !arguments.isEmpty else { return key }
    var result = key
    // replace {1} {2} ... in one pass, later indexes first to keep ranges valid
    for index in stride(from: arguments.count, through: 1, by: -1) {
        result = result.replacingOccurrences(of: "{\(index)}", with: arguments[index - 1])
    }
    return result
}
