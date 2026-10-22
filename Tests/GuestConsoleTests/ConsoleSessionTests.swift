import Testing

@testable import GuestConsole

/// The session against a scripted console on a virtual clock: nothing here waits in real time.
struct ConsoleSessionTests {
    private func session(_ transport: ScriptedTransport, nonce: String = "n1") -> ConsoleSession {
        ConsoleSession(transport: transport, nonce: { nonce })
    }

    /// Answers a typed exec line the way a shell on a terminal does, `delay` after it was typed.
    private func shell(
        _ transport: ScriptedTransport, delay: Duration = .milliseconds(10), answer: @escaping (String) -> (output: String, status: Int)
    ) {
        transport.onWrite = { transport, bytes in
            if let reply = TerminalShell.reply(to: lossyText(bytes), run: answer) {
                transport.arrive(reply, after: delay)
            }
        }
    }

    // MARK: Prompts

    @Test
    func aPromptAlreadyShownIsFoundAtOnce() throws {
        let transport = ScriptedTransport()
        transport.arrive("Welcome\r\nlocalhost login: ")
        #expect(try session(transport).waitForPrompt(timeout: .seconds(5)) == .login)
        #expect(transport.written.isEmpty)
    }

    @Test
    func aQuietConsoleIsNudgedWithANewlineAndAnswersWithItsPrompt() throws {
        let transport = ScriptedTransport()
        transport.arrive("booted\r\n")
        transport.onWrite = { transport, _ in transport.arrive("localhost login: ", after: .milliseconds(5)) }
        #expect(try session(transport).waitForPrompt(timeout: .seconds(30)) == .login)
        #expect(transport.written == [[0x0A]])
    }

    @Test
    func aConsoleThatStaysQuietTimesOutNamingWhatItWaitedFor() {
        let transport = ScriptedTransport()
        transport.arrive("still booting\r\n")
        #expect(
            throws: ConsoleError.timedOut(waitingFor: "a prompt", tail: "still booting")
        ) { try session(transport).waitForPrompt(timeout: .seconds(10)) }
        // The nudges are spaced out: a newline every two seconds at most.
        #expect(transport.written.count <= 5)
        #expect(transport.clock >= .seconds(10))
    }

    @Test
    func aConsoleThatClosesEndsTheWaitWithTheLastOutput() {
        let transport = ScriptedTransport()
        transport.arrive("kernel panic\r\n")
        transport.arriveEnd(after: .milliseconds(1))
        #expect(throws: ConsoleError.closed(lastOutput: "kernel panic")) { try session(transport).waitForPrompt(timeout: .seconds(5)) }
    }

    @Test
    func aConsoleThatAlreadyHasAClientSaysSoAndCloses() {
        let transport = ScriptedTransport()
        transport.arrive(ConsoleBridge.busyMessage)
        transport.arriveEnd()
        #expect(throws: ConsoleError.busy) { try session(transport).waitForPrompt(timeout: .seconds(5)) }
    }

    // MARK: Login

    @Test
    func loggingInAsRootWithoutAPasswordTypesTheUserAndStops() throws {
        let transport = ScriptedTransport()
        transport.arrive("localhost login: ")
        transport.onWrite = { transport, bytes in
            if lossyText(bytes) == "root\n" { transport.arrive("root\r\nWelcome to Alpine!\r\nlocalhost:~# ") }
        }
        try session(transport).login(user: "root", timeout: .seconds(10))
        #expect(transport.writtenText == ["root\n"])
    }

    @Test
    func aPasswordPromptIsAnsweredWithTheGivenPasswordOrAnEmptyLine() throws {
        for (password, expected) in [("", "\n"), ("secret", "secret\n")] {
            let transport = ScriptedTransport()
            transport.arrive("host login: ")
            transport.onWrite = { transport, bytes in
                switch lossyText(bytes) {
                case "root\n": transport.arrive("root\r\nPassword: ")
                case expected: transport.arrive("\r\nhost:~# ")
                default: break
                }
            }
            try session(transport).login(user: "root", password: password, timeout: .seconds(10))
            #expect(transport.writtenText == ["root\n", expected])
        }
    }

    @Test
    func aPromptThatWasWaitedForIsNotWaitedForAgainBeforeAnythingIsTyped() throws {
        let transport = ScriptedTransport()
        transport.arrive("host login: ")
        transport.onWrite = { transport, bytes in
            if lossyText(bytes) == "root\n" { transport.arrive("root\r\nhost:~# ") }
        }
        let console = session(transport)
        #expect(try console.waitForPrompt(timeout: .seconds(5)) == .login)
        #expect(try console.waitForPrompt(timeout: .seconds(5)) == .login)
        try console.login(user: "root", timeout: .seconds(5))
        // No newline was sent to coax a prompt that was already there.
        #expect(transport.writtenText == ["root\n"])
    }

    @Test
    func loggingInWhenAShellIsShownAlreadyTypesNothing() throws {
        let transport = ScriptedTransport()
        transport.arrive("host:~# ")
        try session(transport).login(user: "root", timeout: .seconds(10))
        #expect(transport.written.isEmpty)
    }

    @Test
    func aConsoleThatKeepsAskingForALoginIsGivenUpOn() {
        let transport = ScriptedTransport()
        transport.arrive("host login: ")
        transport.onWrite = { transport, _ in transport.arrive("Login incorrect\r\n\r\nhost login: ", after: .milliseconds(5)) }
        #expect(throws: ConsoleError.loginFailed("the console keeps asking for a login")) {
            try session(transport).login(user: "nobody", timeout: .seconds(60))
        }
    }

    @Test
    func aUserNameThatIsNotOneLineIsRefusedBeforeAnythingIsSent() {
        let transport = ScriptedTransport()
        #expect(throws: ConsoleError.self) { try session(transport).login(user: "a\nb", timeout: .seconds(1)) }
        #expect(transport.written.isEmpty)
    }

    // MARK: Commands

    @Test
    func aCommandReturnsItsOutputAndStatus() throws {
        let transport = ScriptedTransport()
        shell(transport) { command in command == "uname -a" ? ("Linux localhost 6.12 aarch64\n", 0) : ("", 127) }
        let result = try session(transport, nonce: "k7").run("uname -a", timeout: .seconds(5))
        #expect(result == ExecResult(output: "Linux localhost 6.12 aarch64\n", status: 0))
        #expect(transport.writtenText == ["echo MARK_S_k7; uname -a; echo MARK_E_k7_$?\n"])
    }

    @Test
    func aFailingCommandReturnsItsStatusAndNotAnError() throws {
        let transport = ScriptedTransport()
        shell(transport) { _ in ("sh: nope: not found\n", 127) }
        #expect(try session(transport).run("nope", timeout: .seconds(5)) == ExecResult(output: "sh: nope: not found\n", status: 127))
    }

    @Test
    func theAnswerMayArriveInPiecesWithTheEchoAndNoiseMixedIn() throws {
        let transport = ScriptedTransport()
        transport.onWrite = { transport, _ in
            let pieces = [
                "echo MARK_S_n1; id; echo MARK_E_n1_$?\r\n[ 99.0] noise\r\nMARK_", "S_n1\r", "\nuid=0(root)\r\nMARK_E_n", "1_0\r",
                "\nhost:~# ",
            ]
            for (index, piece) in pieces.enumerated() { transport.arrive(piece, after: .milliseconds(10 * (index + 1))) }
        }
        #expect(try session(transport).run("id", timeout: .seconds(5)) == ExecResult(output: "uid=0(root)\n", status: 0))
    }

    @Test
    func aCommandThatOutlivesItsTimeoutGetsCtrlCAndTheCallFailsClearly() {
        let transport = ScriptedTransport()
        transport.onWrite = { transport, bytes in
            if bytes.count > 1 {
                transport.arrive("echo MARK_S_n1; sleep 99; echo MARK_E_n1_$?\r\nMARK_S_n1\r\n", after: .milliseconds(10))
            }
        }
        #expect(
            throws: ConsoleError.timedOut(
                waitingFor: "the command to finish", tail: "echo MARK_S_n1; sleep 99; echo MARK_E_n1_$?\nMARK_S_n1")
        ) {
            try session(transport).run("sleep 99", timeout: .seconds(2))
        }
        #expect(transport.written.last == [0x03])
        #expect(transport.clock >= .seconds(2))
    }

    @Test
    func theConsoleEndingMidCommandIsReportedWithWhatItSent() {
        let transport = ScriptedTransport()
        transport.onWrite = { transport, _ in
            transport.arrive("reboot: Power down\r\n", after: .milliseconds(10))
            transport.arriveEnd(after: .milliseconds(20))
        }
        #expect(throws: ConsoleError.closed(lastOutput: "reboot: Power down")) {
            try session(transport).run("poweroff", timeout: .seconds(5))
        }
    }

    @Test
    func aCommandThatPrintsTooMuchFailsInsteadOfFillingTheMemory() {
        let transport = ScriptedTransport()
        transport.onWrite = { transport, _ in
            transport.arrive("MARK_S_n1\r\n", after: .milliseconds(1))
            for index in 0..<50 { transport.arrive(String(repeating: "x", count: 100), after: .milliseconds(2 + index)) }
        }
        let small = ConsoleSession(transport: transport, outputLimit: 1_000, nonce: { "n1" })
        #expect(throws: ConsoleError.outputTooLarge(limit: 1_000)) { try small.run("yes", timeout: .seconds(5)) }
    }

    @Test
    func aCommandThatCannotBeTypedAsOneLineIsRefusedBeforeAnythingIsSent() {
        let transport = ScriptedTransport()
        let console = session(transport)
        #expect(throws: ConsoleError.self) { try console.run("echo a\necho b", timeout: .seconds(1)) }
        #expect(throws: ConsoleError.self) {
            try console.run(String(repeating: "a", count: ConsoleSession.commandLimit), timeout: .seconds(1))
        }
        #expect(transport.written.isEmpty)
    }

    @Test
    func consecutiveCommandsDoNotSeeEachOthersOutput() throws {
        let transport = ScriptedTransport()
        var counter = 0
        let console = ConsoleSession(
            transport: transport,
            nonce: {
                counter += 1
                return "n\(counter)"
            })
        shell(transport) { command in ("out of \(command)\n", command == "bad" ? 1 : 0) }
        #expect(try console.run("one", timeout: .seconds(5)) == ExecResult(output: "out of one\n", status: 0))
        #expect(try console.run("bad", timeout: .seconds(5)) == ExecResult(output: "out of bad\n", status: 1))
        #expect(try console.run("two", timeout: .seconds(5)) == ExecResult(output: "out of two\n", status: 0))
    }
}
