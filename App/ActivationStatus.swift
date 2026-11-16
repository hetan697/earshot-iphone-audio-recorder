import Foundation

enum ActivationStatus {
    /// Development-signed iOS apps include their provisioning profile in the app bundle.
    static let expirationDate: Date? = {
        guard let url = Bundle.main.url(forResource: "embedded", withExtension: "mobileprovision"),
              let data = try? Data(contentsOf: url) else { return nil }
        guard let plistData = embeddedPlist(in: data),
              let profile = try? PropertyListSerialization.propertyList(from: plistData, format: nil) as? [String: Any]
        else { return nil }
        return profile["ExpirationDate"] as? Date
    }()

    static func remainingDays(at date: Date = Date()) -> Int? {
        guard let expirationDate else { return nil }
        return max(0, Int(ceil(expirationDate.timeIntervalSince(date) / 86_400)))
    }

    /// A provisioning profile is a DER-encoded CMS container whose payload is a plist.
    /// Walk constructed DER values and locate its embedded plist without relying on macOS-only tools.
    private static func embeddedPlist(in data: Data) -> Data? {
        let bytes = [UInt8](data)
        func isPlist(_ range: Range<Int>) -> Bool {
            let prefix = Array(bytes[range].prefix(8))
            return prefix.starts(with: Array("<?xml".utf8)) || prefix.starts(with: Array("bplist00".utf8))
        }
        func find(in range: Range<Int>) -> Data? {
            var cursor = range.lowerBound
            while cursor < range.upperBound {
                let tag = bytes[cursor]
                cursor += 1
                guard cursor < range.upperBound else { return nil }
                let firstLengthByte = bytes[cursor]
                cursor += 1
                let length: Int
                if firstLengthByte & 0x80 == 0 {
                    length = Int(firstLengthByte)
                } else {
                    let count = Int(firstLengthByte & 0x7f)
                    guard count > 0, count <= MemoryLayout<Int>.size,
                          cursor + count <= range.upperBound else { return nil }
                    var decoded = 0
                    for byte in bytes[cursor..<(cursor + count)] { decoded = (decoded << 8) | Int(byte) }
                    length = decoded
                    cursor += count
                }
                guard length >= 0, cursor + length <= range.upperBound else { return nil }
                let content = cursor..<(cursor + length)
                if tag == 0x04, isPlist(content) { return Data(bytes[content]) }
                if tag & 0x20 != 0 || tag == 0xa0, let result = find(in: content) { return result }
                cursor += length
            }
            return nil
        }
        return find(in: bytes.startIndex..<bytes.endIndex)
    }
}
