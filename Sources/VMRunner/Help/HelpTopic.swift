import Foundation

/// A grouping in the help window.
enum HelpArea: String, CaseIterable, Identifiable, Sendable {
    case start = "Getting started"
    case machines = "Machines"
    case compute = "CPU and memory"
    case storage = "Storage"
    case display = "Display and input"
    case network = "Network and sharing"
    case security = "Security"
    case macOS = "macOS guests"
    case snapshots = "Snapshots and copies"
    case app = "The app"

    var id: Self { self }
}

/// Everything the help system can explain. Each case has an entry in `HelpCatalog`; a test fails if one is missing.
enum HelpTopic: String, CaseIterable, Identifiable, Hashable, Sendable {
    // Getting started
    case overview, guestSystems, macRestoreImage, linuxImages, setup
    // Machines
    case controls, suspendResume, runtimeLimit, duplicateDelete, diskUsage
    // CPU and memory
    case cpuCores, memory, nestedVirtualization
    // Storage
    case diskSize, diskCaching, diskSync, extraDisks, installerISO
    // Display and input
    case graphics, resolution, pixelDensity, resizeWithWindow, pixelsPerPoint, linuxBootText, pointingDevice, captureKeys
    case inputResponsiveness, audio
    // Network and sharing
    case networkMode, macAddress, sharedFolders, clipboard, rosetta, hostInformation
    case networkPolicy, policyRules, policyLimits, guestVpn, killSwitch
    // Security
    case securityProfiles, disposable, secureBoot, exposureSummary, devices, memoryBalloon, entropy, vsock, serialConsole, guestIdentity
    case agentAccess
    // macOS guests
    case bootRecovery, firstBootAccount
    // Snapshots and copies
    case snapshots
    // The app
    case settings, shortcuts, fullScreen, launchArguments, limits, managedSettings
    case controlService, controlTokens

    var id: Self { self }
    var entry: HelpEntry { HelpCatalog.entry(for: self) }
    var title: String { entry.title }
    var summary: String { entry.summary }
    var area: HelpArea { entry.area }
}

/// The text for one topic. Written for someone who has never used a VM, with the details an experienced user wants
/// kept separate so a beginner can stop reading after the first paragraphs.
struct HelpEntry: Sendable {
    var area: HelpArea
    var title: String
    /// One plain sentence, short enough for a tooltip.
    var summary: String
    /// What it is, when to use it, and what to watch out for. A paragraph starting with "• " is a list item.
    var paragraphs: [String]
    /// Extra detail for experienced users: exact behaviour, limits, commands.
    var advanced: [String] = []
    var related: [HelpTopic] = []
}

enum HelpCatalog {
    static let entries: [HelpTopic: HelpEntry] = [
        machines, hardware, networkAndSecurity, filteredNetwork, snapshotsAndApp, automation,
    ].reduce(into: [:]) { $0.merge($1) { first, _ in first } }

    static func entry(for topic: HelpTopic) -> HelpEntry {
        entries[topic]
            ?? HelpEntry(area: .app, title: topic.rawValue, summary: "No help text yet.", paragraphs: ["No help text yet."])
    }

    /// Each topic's searchable text (title, summary and every paragraph, lowercased), built once rather than per query.
    static let searchIndex: [(topic: HelpTopic, haystack: String)] = HelpTopic.allCases.map { topic in
        let entry = topic.entry
        return (topic, ([entry.title, entry.summary] + entry.paragraphs + entry.advanced).joined(separator: " ").lowercased())
    }

    /// Topics whose title, summary, or text contains every word of `query` (case-insensitive).
    static func search(_ query: String) -> [HelpTopic] {
        let words = query.lowercased().split(separator: " ").map(String.init)
        guard !words.isEmpty else { return HelpTopic.allCases }
        return searchIndex.filter { entry in words.allSatisfy(entry.haystack.contains) }.map(\.topic)
    }
}
