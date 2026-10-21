/// Ranges and steps shared by the editor controls and the help text, so the two can't disagree.
enum EditorLimits {
    static let maxDiskGiB = 4096
    static let diskStepGiB = 8
    static let newDiskGiB = 16...2048
    static let memoryStepMiB = 512
    static let newMemoryStepMiB = 1024
    static let displayWidth = 640...7680
    static let displayHeight = 480...4320
    static let displayWidthStep = 80
    static let displayHeightStep = 50
    static let pixelsPerInch = 72...326
    static let pixelsPerInchStep = 2
    static let runtimeMinutes = 0...1440
    static let runtimeStepMinutes = 15
}
