// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

public enum UsageFormat {
    /// "3d 4h", "2h 5m", "12m", "40s", or "now".
    public static func resetsIn(_ date: Date?, now: Date = Date()) -> String? {
        guard let date else { return nil }
        let seconds = Int(date.timeIntervalSince(now))
        guard seconds > 0 else { return "now" }
        return duration(seconds)
    }

    public static func duration(_ seconds: Int) -> String {
        let minutes = seconds / 60, hours = minutes / 60, days = hours / 24
        if days > 0 { return hours % 24 > 0 ? "\(days)d \(hours % 24)h" : "\(days)d" }
        if hours > 0 { return minutes % 60 > 0 ? "\(hours)h \(minutes % 60)m" : "\(hours)h" }
        if minutes > 0 { return "\(minutes)m" }
        return "\(seconds)s"
    }

    /// ISO 8601 (with or without fractions), a plain YYYY-MM-DD, or a Unix
    /// timestamp in seconds or milliseconds.
    public static func parseDate(_ value: Any?) -> Date? {
        if let number = value as? Double { return fromEpoch(number) }
        if let number = value as? Int { return fromEpoch(Double(number)) }
        guard let string = (value as? String)?.trimmingCharacters(in: .whitespaces), !string.isEmpty else { return nil }
        for options: ISO8601DateFormatter.Options in [[.withInternetDateTime, .withFractionalSeconds], [.withInternetDateTime], [.withFullDate]] {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = options
            if let date = formatter.date(from: string) { return date }
        }
        return Double(string).flatMap(fromEpoch)
    }

    private static func fromEpoch(_ value: Double) -> Date? {
        guard value.isFinite, value > 0 else { return nil }
        return Date(timeIntervalSince1970: value > 1_000_000_000_000 ? value / 1000 : value)
    }

    public static func clampPercent(_ value: Double) -> Int {
        guard value.isFinite else { return 0 }
        return Int(max(0, min(100, value.rounded())))
    }

    /// "1,234.5" without trailing zeros.
    public static func amount(_ value: Double) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.maximumFractionDigits = 2
        return formatter.string(from: NSNumber(value: value)) ?? "\(value)"
    }
}

/// Loose JSON access, for payloads whose shape isn't guaranteed.
enum JSON {
    static func object(_ data: Data) -> [String: Any]? {
        (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    static func number(_ value: Any?) -> Double? {
        if let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() { return number.doubleValue }
        if let string = value as? String, let number = Double(string.trimmingCharacters(in: .whitespaces)), number.isFinite {
            return number
        }
        return nil
    }

    static func string(_ value: Any?) -> String? {
        guard let string = (value as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !string.isEmpty else { return nil }
        return string
    }
}

/// Decodes a JWT's payload without verifying it.
func decodeJWTPayload(_ token: String) -> [String: Any]? {
    let parts = token.split(separator: ".")
    guard parts.count == 3, let data = base64URLDecode(String(parts[1])) else { return nil }
    return JSON.object(data)
}

func base64URLDecode(_ value: String) -> Data? {
    var base64 = value.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
    if base64.count % 4 != 0 { base64 += String(repeating: "=", count: 4 - base64.count % 4) }
    return Data(base64Encoded: base64)
}
