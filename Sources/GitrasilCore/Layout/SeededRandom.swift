import Foundation

/// A tiny deterministic generator (SplitMix64): the same seed gives the same sequence on every run,
/// so seeded shapes and textures never reshuffle between redraws or launches.
public struct SeededRandom {
    private var state: UInt64

    public init(seed: UInt64) { state = seed }

    /// Seeded from a string and an index (a branch name and a step, say), stable across launches.
    public init(_ key: String, _ index: Int = 0) {
        state = Self.hash(key) ^ (UInt64(bitPattern: Int64(index)) &* 0x9E3779B97F4A7C15)
    }

    /// `key` reshuffled by a layout seed (`BackgroundSettings.layoutSeed`): `key` itself for 0, so
    /// shapes keep the seeds they've always had until reshuffled; another key for any other seed.
    public static func key(_ key: String, shuffle: Int) -> String {
        shuffle == 0 ? key : "\(key)\u{1F}\(shuffle)"
    }

    /// The next value in 0..<1.
    public mutating func next() -> Double {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        z ^= z >> 31
        return Double(z >> 11) / Double(UInt64(1) << 53)
    }

    /// The next value in `range`.
    public mutating func next(in range: ClosedRange<Double>) -> Double {
        range.lowerBound + next() * (range.upperBound - range.lowerBound)
    }

    /// A stable hash of a string (FNV-1a with a final mix, not Swift's per-launch seeded hash).
    public static func hash(_ key: String) -> UInt64 {
        var hash = key.utf8.reduce(UInt64(0xcbf29ce484222325)) { ($0 ^ UInt64($1)) &* 0x100000001b3 }
        hash ^= hash >> 33; hash &*= 0xff51afd7ed558ccd; hash ^= hash >> 33
        return hash
    }
}
