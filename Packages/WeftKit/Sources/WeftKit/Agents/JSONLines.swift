import Foundation

/// Byte-level helpers for JSON Lines logs. Agent logs run to tens of megabytes, mostly tool
/// output nobody here needs, so lines are inspected by prefix and only the few that matter
/// are decoded.
enum JSONLines {
    /// Calls `body` with each complete line and the file offset it starts at. A trailing line
    /// without a newline may still be being written, so it's left for next time.
    /// - Returns: how many bytes were consumed, up to and including the last newline.
    static func forEachLine(in data: Data, base: Int64, _ body: (UnsafeRawBufferPointer, Int64) -> Void) -> Int {
        data.withUnsafeBytes { buffer -> Int in
            guard let start = buffer.baseAddress else { return 0 }
            var position = 0
            while position < buffer.count {
                guard let newline = memchr(start + position, 0x0A, buffer.count - position) else { break }
                let end = start.distance(to: UnsafeRawPointer(newline))
                if end > position {
                    body(UnsafeRawBufferPointer(rebasing: buffer[position..<end]), base + Int64(position))
                }
                position = end + 1
            }
            return position
        }
    }

    static func hasPrefix(_ line: UnsafeRawBufferPointer, _ prefix: StaticString) -> Bool {
        let count = prefix.utf8CodeUnitCount
        guard line.count >= count, let base = line.baseAddress else { return false }
        return memcmp(base, prefix.utf8Start, count) == 0
    }

    /// Where `needle` first appears within the first `limit` bytes of `line`.
    static func find(_ needle: StaticString, in line: UnsafeRawBufferPointer, from: Int = 0, limit: Int = .max) -> Int? {
        let end = min(line.count, limit)
        guard from < end, let base = line.baseAddress else { return nil }
        guard let match = memmem(base + from, end - from, needle.utf8Start, needle.utf8CodeUnitCount) else { return nil }
        return base.distance(to: UnsafeRawPointer(match))
    }

    /// The string value of the first `"key":"…"` within `limit` bytes, without unescaping.
    /// Only for values that never contain quotes, like timestamps and ids.
    static func string(after key: StaticString, in line: UnsafeRawBufferPointer, limit: Int = .max) -> String? {
        guard let keyStart = find(key, in: line, limit: limit) else { return nil }
        let valueStart = keyStart + key.utf8CodeUnitCount
        var end = valueStart
        while end < line.count, line[end] != 0x22 { end += 1 }
        guard end < line.count else { return nil }
        return String(decoding: UnsafeRawBufferPointer(rebasing: line[valueStart..<end]), as: UTF8.self)
    }
}

/// Parses the fixed `2026-10-28T11:43:41.691Z` form agents write, falling back to Foundation
/// for anything else. Hand-rolled because a big log has hundreds of thousands of these.
enum Timestamp {
    static func parse(_ text: String) -> Date? {
        var text = text
        return text.withUTF8 { fast($0) } ?? fallback(text)
    }

    private static func fast(_ bytes: UnsafeBufferPointer<UInt8>) -> Date? {
        // YYYY-MM-DDTHH:MM:SS[.fff…]Z
        guard bytes.count >= 20, bytes[4] == 0x2D, bytes[7] == 0x2D, bytes[10] == 0x54,
              bytes[13] == 0x3A, bytes[16] == 0x3A, bytes[bytes.count - 1] == 0x5A else { return nil }
        func number(_ from: Int, _ count: Int) -> Int? {
            var value = 0
            for index in from..<(from + count) {
                let digit = Int(bytes[index]) - 48
                guard (0...9).contains(digit) else { return nil }
                value = value * 10 + digit
            }
            return value
        }
        guard let year = number(0, 4), let month = number(5, 2), let day = number(8, 2),
              let hour = number(11, 2), let minute = number(14, 2), let second = number(17, 2),
              (1...12).contains(month), (1...31).contains(day) else { return nil }
        var fraction = 0.0
        if bytes.count > 20 {
            guard bytes[19] == 0x2E else { return nil }
            var scale = 0.1
            for index in 20..<(bytes.count - 1) {
                let digit = Int(bytes[index]) - 48
                guard (0...9).contains(digit) else { return nil }
                fraction += Double(digit) * scale
                scale /= 10
            }
        } else if bytes[19] != 0x5A {
            return nil
        }
        let days = daysFromCivil(year, month, day)
        let seconds = Double(days * 86400 + hour * 3600 + minute * 60 + second) + fraction
        return Date(timeIntervalSince1970: seconds)
    }

    /// Days since 1970-01-01 in the proleptic Gregorian calendar (Howard Hinnant's algorithm).
    private static func daysFromCivil(_ year: Int, _ month: Int, _ day: Int) -> Int {
        let y = month <= 2 ? year - 1 : year
        let era = (y >= 0 ? y : y - 399) / 400
        let yearOfEra = y - era * 400
        let dayOfYear = (153 * (month + (month > 2 ? -3 : 9)) + 2) / 5 + day - 1
        let dayOfEra = yearOfEra * 365 + yearOfEra / 4 - yearOfEra / 100 + dayOfYear
        return era * 146097 + dayOfEra - 719468
    }

    private static func fallback(_ text: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: text) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: text)
    }
}
