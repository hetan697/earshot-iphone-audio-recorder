import Foundation

/// How much to boost or cut each of the two tracks, in decibels. 0 dB leaves the recording untouched.
/// Saved next to the recording (`levels.json`) so the balance survives relaunches.
struct MixLevels: Codable, Equatable {
    var app: Double = 0      // the phone's own sound
    var mic: Double = 0      // the microphone

    static let neutral = MixLevels()
    static let range: ClosedRange<Double> = -24...12
    static let fileName = "levels.json"

    var isNeutral: Bool { app == 0 && mic == 0 }

    /// The linear factor AVFoundation wants for a decibel value (1 = unchanged).
    static func linear(_ db: Double) -> Float { Float(pow(10, db / 20)) }

    static func label(_ db: Double) -> String {
        db == 0 ? "0 dB" : String(format: "%+.0f dB", db)
    }

    static func load(_ dir: URL) -> MixLevels {
        guard let data = try? Data(contentsOf: dir.appendingPathComponent(fileName)),
              let levels = try? JSONDecoder().decode(MixLevels.self, from: data)
        else { return .neutral }
        return levels.clamped()
    }

    func save(to dir: URL) {
        guard let data = try? JSONEncoder().encode(clamped()) else { return }
        try? data.write(to: dir.appendingPathComponent(Self.fileName), options: .atomic)
    }

    func clamped() -> MixLevels {
        MixLevels(app: min(max(app, Self.range.lowerBound), Self.range.upperBound),
                  mic: min(max(mic, Self.range.lowerBound), Self.range.upperBound))
    }
}
