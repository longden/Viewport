import Foundation

/// Optional per-launch CPU and RAM overrides for Android emulators
/// (`-cores`, `-memory`). `nil` keeps the AVD's own `hw.cpu.ncore` /
/// `hw.ramSize`.
struct AndroidEmulatorResources: Equatable {
    static let coresUserDefaultsKey = "androidEmulatorCores"
    static let memoryUserDefaultsKey = "androidEmulatorMemoryMB"

    private static let coreChoices = [2, 4, 6, 8]
    private static let memoryChoicesMB = [2_048, 4_096, 6_144, 8_192]

    var cores: Int?
    var memoryMB: Int?

    init(cores: Int? = nil, memoryMB: Int? = nil) {
        self.cores = cores.flatMap { $0 > 0 ? $0 : nil }
        self.memoryMB = memoryMB.flatMap { $0 > 0 ? $0 : nil }
    }

    init(defaults: UserDefaults) {
        self.init(
            cores: defaults.integer(forKey: Self.coresUserDefaultsKey),
            memoryMB: defaults.integer(forKey: Self.memoryUserDefaultsKey)
        )
    }

    var hasOverrides: Bool {
        cores != nil || memoryMB != nil
    }

    var launchArguments: [String] {
        var arguments: [String] = []
        if let cores {
            arguments += ["-cores", String(cores)]
        }
        if let memoryMB {
            arguments += ["-memory", String(memoryMB)]
        }
        return arguments
    }

    func save(to defaults: UserDefaults) {
        defaults.set(cores ?? 0, forKey: Self.coresUserDefaultsKey)
        defaults.set(memoryMB ?? 0, forKey: Self.memoryUserDefaultsKey)
    }

    /// Leaves at least two host cores for macOS and Viewport.
    static func coreChoices(
        hostCores: Int = ProcessInfo.processInfo.activeProcessorCount,
        including current: Int? = nil
    ) -> [Int] {
        choices(coreChoices.filter { $0 <= hostCores - 2 }, including: current)
    }

    /// Caps each emulator at half of the Mac's RAM.
    static func memoryChoicesMB(
        hostMemoryBytes: UInt64 = ProcessInfo.processInfo.physicalMemory,
        including current: Int? = nil
    ) -> [Int] {
        let limitMB = Int(hostMemoryBytes / 1_048_576 / 2)
        return choices(memoryChoicesMB.filter { $0 <= limitMB }, including: current)
    }

    private static func choices(_ values: [Int], including current: Int?) -> [Int] {
        guard let current, !values.contains(current) else { return values }
        return (values + [current]).sorted()
    }
}
