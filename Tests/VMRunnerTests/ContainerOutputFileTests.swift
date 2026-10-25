import Foundation
import Testing

@testable import VMRunner

/// A scratch folder with the two paths of a container output file.
private struct Folder {
    let url: URL
    var current: URL { url.appending(path: "container-output.log") }
    var previous: URL { url.appending(path: "container-output.1.log") }

    init() throws { url = try scratchDirectory() }

    func remove() { try? FileManager.default.removeItem(at: url) }

    func file(limit: Int = ContainerOutputFile.defaultLimit, pendingLimit: Int = ContainerOutputFile.defaultLimit)
        -> ContainerOutputFile
    {
        ContainerOutputFile(current: current, previous: previous, limit: limit, pendingLimit: pendingLimit)
    }

    func text(_ file: URL) -> String? { (try? Data(contentsOf: file)).flatMap { String(bytes: $0, encoding: .utf8) } }

    func mode(_ file: URL) throws -> Int {
        try #require(FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? Int)
    }

    /// Makes a file as it would be if something else made it.
    func plant(_ text: String, at file: URL, mode: Int = 0o600) throws {
        try Data(text.utf8).write(to: file)
        try FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: file.path)
    }

    func names() throws -> [String] { try FileManager.default.contentsOfDirectory(atPath: url.path).sorted() }
}

private func bytes(_ text: String) -> [UInt8] { Array(text.utf8) }

/// The file that keeps a container's output: written off the main actor, bounded, private, and never through a link.
struct ContainerOutputFileTests {
    @Test func theFileIsCreatedPrivate() async throws {
        let folder = try Folder()
        defer { folder.remove() }
        let file = folder.file()

        file.append(bytes("hello\n"))
        await file.drained()

        #expect(folder.text(folder.current) == "hello\n")
        #expect(try folder.mode(folder.current) == 0o600)
        #expect(try folder.names() == ["container-output.log"])
    }

    @Test func aSecondRunAppendsToWhatTheFirstLeft() async throws {
        let folder = try Folder()
        defer { folder.remove() }
        let first = folder.file()
        first.append(bytes("one\n"))
        await first.drained()

        let second = folder.file()
        second.append(bytes("two\n"))
        second.append(bytes("three\n"))
        await second.drained()

        #expect(folder.text(folder.current) == "one\ntwo\nthree\n")
        #expect(try folder.mode(folder.current) == 0o600)
    }

    @Test func rotationKeepsExactlyOnePreviousFile() async throws {
        let folder = try Folder()
        defer { folder.remove() }
        let file = folder.file(limit: 20)

        file.append(bytes("aaaaaaaaaa\n"))
        await file.drained()
        #expect(try folder.names() == ["container-output.log"], "11 bytes fit in 20")
        file.append(bytes("bbbbbbbbbb\n"))
        await file.drained()
        #expect(folder.text(folder.previous) == "aaaaaaaaaa\n" && folder.text(folder.current) == "bbbbbbbbbb\n")

        file.append(bytes("cccccccccc\n"))
        await file.drained()
        #expect(try folder.names() == ["container-output.1.log", "container-output.log"])
        #expect(folder.text(folder.previous) == "bbbbbbbbbb\n")
        #expect(folder.text(folder.current) == "cccccccccc\n")
        #expect(try folder.mode(folder.previous) == 0o600 && folder.mode(folder.current) == 0o600)
    }

    @Test func aLinkAtThePathIsRefusedAndItsTargetIsLeftAlone() async throws {
        let folder = try Folder()
        defer { folder.remove() }
        let target = folder.url.appending(path: "target.txt")
        try folder.plant("keep\n", at: target)
        try FileManager.default.createSymbolicLink(at: folder.current, withDestinationURL: target)
        let file = folder.file()

        file.append(bytes("written\n"))
        await file.drained()

        #expect(folder.text(target) == "keep\n")
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: folder.current.path) == target.path)
    }

    @Test func aLinkWhereTheOldFileGoesIsReplacedNotFollowed() async throws {
        let folder = try Folder()
        defer { folder.remove() }
        let missing = folder.url.appending(path: "absent.txt")
        try FileManager.default.createSymbolicLink(at: folder.previous, withDestinationURL: missing)
        try folder.plant("12345678", at: folder.current)
        let file = folder.file(limit: 10)

        file.append(bytes("abcdef"))
        await file.drained()

        #expect(folder.text(folder.previous) == "12345678")
        #expect(folder.text(folder.current) == "abcdef")
        #expect(!FileManager.default.fileExists(atPath: missing.path), "the link's target was never created")
    }

    @Test func aFileOpenToOthersIsRefusedAndUnchanged() async throws {
        let folder = try Folder()
        defer { folder.remove() }
        try folder.plant("old\n", at: folder.current, mode: 0o644)
        let file = folder.file()

        file.append(bytes("new\n"))
        await file.drained()

        #expect(folder.text(folder.current) == "old\n")
        #expect(try folder.mode(folder.current) == 0o644)
    }

    @Test func aFileWithASecondNameIsRefusedAndUnchanged() async throws {
        let folder = try Folder()
        defer { folder.remove() }
        try folder.plant("old\n", at: folder.current)
        let other = folder.url.appending(path: "other-name")
        try FileManager.default.linkItem(at: folder.current, to: other)
        let file = folder.file()

        file.append(bytes("new\n"))
        await file.drained()

        #expect(folder.text(folder.current) == "old\n")
        #expect(folder.text(other) == "old\n")
    }

    @Test func oneAppendBiggerThanTheLimitKeepsItsLastBytesFromACharacterBoundary() async throws {
        let folder = try Folder()
        defer { folder.remove() }
        let file = folder.file(limit: 9)

        // 22 bytes; the last 9 start inside a character, so the cut moves forward to the next one: 8 bytes.
        file.append(bytes("ab" + String(repeating: "é", count: 10)))
        await file.drained()

        #expect(folder.text(folder.current) == "éééé")
    }

    @Test func pastThePendingLimitNewBytesAreDroppedAndTheNextDrainSaysHowMany() async throws {
        let folder = try Folder()
        defer { folder.remove() }
        // A held queue decides when the drains run, so what is pending does not depend on timing.
        let queue = DispatchQueue(label: "output-file-test")  // swiftlint:disable:this no_dispatch_queue
        queue.suspend()
        let file = ContainerOutputFile(current: folder.current, previous: folder.previous, pendingLimit: 5, queue: queue)

        file.append(bytes("12345"))
        file.append(bytes("6789"))
        file.append(bytes("abc"))
        queue.resume()
        await file.drained()

        #expect(folder.text(folder.current) == "[dropped 7 bytes: the disk was slower than the container]\n12345")
        file.append(bytes("more\n"))
        await file.drained()
        #expect(folder.text(folder.current)?.hasSuffix("12345more\n") == true)
    }

    @Test func theDroppedNoteSurvivesTheDefaultLimits() async throws {
        let folder = try Folder()
        defer { folder.remove() }
        let queue = DispatchQueue(label: "output-file-test")  // swiftlint:disable:this no_dispatch_queue
        queue.suspend()
        let file = ContainerOutputFile(current: folder.current, previous: folder.previous, queue: queue)

        // The first append fills what may wait; the line after it is dropped, and the note must lead what is written.
        let limit = ContainerOutputFile.defaultLimit
        file.append(bytes(String(repeating: "a", count: limit)))
        file.append(bytes("last line\n"))
        queue.resume()
        await file.drained()

        let kept = try #require(folder.text(folder.current))
        #expect(kept.hasPrefix("[dropped "))
        let note = kept.prefix { $0 != "\n" }
        let count = try #require(Int(note.dropFirst("[dropped ".count).prefix { $0.isNumber }))
        #expect(kept.utf8.count <= limit)
        #expect(count + kept.utf8.count - note.utf8.count - 1 == limit + 10, "every byte is either kept or counted")
    }

    @Test func twoRunsWritingAtOnceLoseNothingAcrossARotation() async throws {
        for _ in 0..<25 {
            let folder = try Folder()
            defer { folder.remove() }
            let older = folder.file(limit: 15)
            let newer = folder.file(limit: 15)

            // Each batch fills the file, so the second one rotates it: the drains of two file objects must not overlap.
            older.append(bytes("aaaaaaaaaa\n"))
            newer.append(bytes("bbbbbbbbbb\n"))
            await newer.drained()

            #expect(folder.text(folder.previous) == "aaaaaaaaaa\n")
            #expect(folder.text(folder.current) == "bbbbbbbbbb\n")
        }
    }

    @Test func filesOnTheSamePathsWriteInTheOrderTheyWereAppendedTo() async throws {
        let folder = try Folder()
        defer { folder.remove() }
        let queue = DispatchQueue(label: "output-file-test")  // swiftlint:disable:this no_dispatch_queue
        queue.suspend()
        let older = ContainerOutputFile(current: folder.current, previous: folder.previous, limit: 40, queue: queue)
        let newer = ContainerOutputFile(current: folder.current, previous: folder.previous, limit: 40, queue: queue)

        older.append(bytes("a1 first run\n"))
        older.append(bytes("a2 first run\n"))
        newer.append(bytes("b1 second run\n"))
        newer.append(bytes("b2 second run\n"))
        queue.resume()
        await older.drained()
        await newer.drained()

        let all = (folder.text(folder.previous) ?? "") + (folder.text(folder.current) ?? "")
        #expect(all == "a1 first run\na2 first run\nb1 second run\nb2 second run\n")
        #expect(folder.text(folder.previous) != nil, "the second run rotated the first's output")
    }

    @Test func aPipeAtThePathIsLeftAloneAndNeverHoldsTheWriter() async throws {
        let folder = try Folder()
        defer { folder.remove() }
        let made = unsafe mkfifo(folder.current.path, 0o600)
        #expect(made == 0)
        let file = folder.file()

        file.append(bytes("written\n"))
        await file.drained()

        var status = stat()
        let looked = unsafe lstat(folder.current.path, &status)
        #expect(looked == 0 && status.st_mode & S_IFMT == S_IFIFO)
        #expect(try folder.names() == ["container-output.log"])
    }

    // MARK: Reading the tail

    @Test func filesThatAreMissingReadAsEmpty() {
        let nowhere = URL(filePath: "/nonexistent-\(UUID().uuidString)")
        let tail = ContainerOutputFile.tail(current: nowhere, previous: nowhere, limit: 100)
        #expect(tail.text.isEmpty && !tail.truncated)
    }

    @Test func theTailIsAtMostTheLimitAndSaysWhenThereWasMore() throws {
        let folder = try Folder()
        defer { folder.remove() }
        try folder.plant("0123456789", at: folder.current)

        let short = ContainerOutputFile.tail(current: folder.current, previous: folder.previous, limit: 4)
        #expect(short.text == "6789" && short.truncated)
        let exact = ContainerOutputFile.tail(current: folder.current, previous: folder.previous, limit: 10)
        #expect(exact.text == "0123456789" && !exact.truncated)
        let roomy = ContainerOutputFile.tail(current: folder.current, previous: folder.previous, limit: 100)
        #expect(roomy.text == "0123456789" && !roomy.truncated)
    }

    @Test func theTailCrossesIntoThePreviousFile() throws {
        let folder = try Folder()
        defer { folder.remove() }
        try folder.plant("abcdef", at: folder.previous)
        try folder.plant("ghij", at: folder.current)

        let part = ContainerOutputFile.tail(current: folder.current, previous: folder.previous, limit: 7)
        #expect(part.text == "defghij" && part.truncated)
        let all = ContainerOutputFile.tail(current: folder.current, previous: folder.previous, limit: 10)
        #expect(all.text == "abcdefghij" && !all.truncated)
    }

    @Test func theTailStartsAtACharacter() throws {
        let folder = try Folder()
        defer { folder.remove() }
        try folder.plant("xéé", at: folder.current)

        // The last 3 bytes begin in the middle of the first é; the tail starts at the second one.
        let tail = ContainerOutputFile.tail(current: folder.current, previous: folder.previous, limit: 3)
        #expect(tail.text == "é" && tail.truncated)
    }

    @Test func aFileThatFailsTheChecksReadsAsEmpty() throws {
        let folder = try Folder()
        defer { folder.remove() }
        try folder.plant("secret\n", at: folder.current, mode: 0o644)
        let target = folder.url.appending(path: "target.txt")
        try folder.plant("linked\n", at: target)
        try FileManager.default.createSymbolicLink(at: folder.previous, withDestinationURL: target)

        let tail = ContainerOutputFile.tail(current: folder.current, previous: folder.previous, limit: 100)
        #expect(tail.text.isEmpty && !tail.truncated)
    }

    @Test func aHugeFileIsReadOnlyAsFarAsTheLimit() throws {
        let folder = try Folder()
        defer { folder.remove() }
        try folder.plant("", at: folder.current)
        let handle = try FileHandle(forWritingTo: folder.current)
        try handle.truncate(atOffset: 256 << 20)
        try handle.seek(toOffset: (256 << 20) - 5)
        try handle.write(contentsOf: Data("end!\n".utf8))
        try handle.close()

        let tail = ContainerOutputFile.tail(current: folder.current, previous: folder.previous, limit: 16)
        #expect(tail.text.utf8.count == 16 && tail.text.hasSuffix("end!\n") && tail.truncated)
    }

    @Test func aPipeAtThePathReadsAsEmptyWithoutWaiting() throws {
        let folder = try Folder()
        defer { folder.remove() }
        let made = unsafe mkfifo(folder.current.path, 0o600)
        #expect(made == 0)
        try folder.plant("old\n", at: folder.previous)

        let tail = ContainerOutputFile.tail(current: folder.current, previous: folder.previous, limit: 100)
        #expect(tail.text == "old\n" && !tail.truncated)
    }

    // MARK: Through the log

    @MainActor
    @Test func aLogWithAFileKeepsTheFilteredTextAndTheMarkers() async throws {
        let folder = try Folder()
        defer { folder.remove() }
        let file = folder.file()
        let log = ContainerLog(file: file)

        log.apply(.phase(name: "boot", seconds: 1))
        log.apply(.output(stream: .stdout, text: "hi \u{1B}[31mred\u{1B}[0m\n"))
        log.appendDiagnostics(bytes("runner noise\n"))
        log.apply(.exited(status: 3))
        log.apply(.error(message: "boom\u{1B}[1m"))
        log.apply(.finished(status: 1))
        await file.drained()

        let content = try #require(folder.text(folder.current))
        let marker = content.prefix { $0 != "\n" }
        #expect(marker.hasPrefix("[run started 20") && marker.hasSuffix("Z]"))
        #expect(
            content.dropFirst(marker.count + 1)
                == "hi red\n[the container exited with status 3]\n[runner error] boom\n"
                + "[the container runner finished with status 1]\n")
        #expect(log.output.text == "hi red\n")
        #expect(!content.contains("noise"))
    }
}
