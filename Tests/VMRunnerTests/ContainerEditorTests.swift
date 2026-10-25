import Foundation
import Testing

@testable import VMRunner

/// Which sections of the settings form a machine shows: a container only what applies to it.
struct EditorSectionTests {
    private func container(agentAccess: Bool = false) -> VMConfig {
        var config = VMConfig.newContainer(name: "box")
        config.agentAccess = agentAccess
        return config
    }

    @Test func aContainerShowsItsGeneralSectionItsSettingsAndAgentAccessOnly() {
        #expect(EditorSection.visible(for: container()) == [.general, .container, .agentAccess])
    }

    @Test func aContainerShowsNothingThatIsAboutVirtualMachineHardware() {
        let vmOnly: Set<EditorSection> = Set(EditorSection.allCases).subtracting([.general, .container, .agentAccess])
        #expect(vmOnly.count == 16)
        #expect(Set(EditorSection.visible(for: container())).isDisjoint(with: vmOnly))
    }

    @Test func aLinuxMachineShowsEverySectionItAlwaysDid() {
        var config = VMConfig.new(name: "vm", guest: .linux)
        config.networkMode = .nat
        #expect(
            EditorSection.visible(for: config) == [
                .general, .security, .compute, .storage, .installer, .provisioning, .display, .input, .audio, .network,
                .identity, .sharing, .hostInfo, .devices, .agentAccess, .snapshots,
            ])
    }

    @Test func aMacOSMachineShowsItsBootSectionAndNoInstallerOrProvisioning() {
        var config = VMConfig.new(name: "vm", guest: .macOS)
        config.networkMode = .nat
        let sections = EditorSection.visible(for: config)
        #expect(sections.contains(.boot))
        #expect(!sections.contains(.installer) && !sections.contains(.provisioning) && !sections.contains(.container))
    }

    @Test func theNetworkPolicyIsShownOnlyForFilteredNetworking() {
        var config = VMConfig.new(name: "vm", guest: .linux)
        for mode in [NetworkMode.nat, .none] {
            config.networkMode = mode
            #expect(!EditorSection.visible(for: config).contains(.networkPolicy))
        }
        config.networkMode = .filtered
        #expect(EditorSection.visible(for: config).contains(.networkPolicy))
    }

    @Test func aContainerWithFilteredNetworkingStoredStillShowsNoNetworkSections() {
        var config = container()
        config.networkMode = .filtered
        let sections = EditorSection.visible(for: config)
        #expect(!sections.contains(.network) && !sections.contains(.networkPolicy))
    }
}

/// The container's command and environment as text, and the same refusals the New Machine sheet gives.
struct ContainerDraftTests {
    @Test func aCommandIsWrittenAsALineThatReadsBackTheSame() throws {
        let command = ["/bin/sh", "-c", "echo hi  there", "", "plain", "tab\tsep"]
        let line = ContainerInput.line(from: command)
        #expect(line == "/bin/sh -c \"echo hi  there\" \"\" plain \"tab\tsep\"")
        #expect(try ContainerInput.arguments(from: line) == command)
        #expect(ContainerInput.line(from: []).isEmpty)
    }

    @Test func anEnvironmentIsWrittenOnePerLineAndReadsBackTheSame() throws {
        let entries = [
            ContainerEnvironmentEntry(name: "ZED", value: "last"), ContainerEnvironmentEntry(name: "URL", value: "https://x.test/?a=b"),
            ContainerEnvironmentEntry(name: "EMPTY", value: ""),
        ]
        let text = ContainerInput.text(from: entries)
        #expect(text == "ZED=last\nURL=https://x.test/?a=b\nEMPTY=")
        #expect(try ContainerInput.environment(from: text) == entries)
    }

    @Test func aStoredSpecIsShownAsTextAndEditable() {
        let spec = ContainerSpec(
            command: ["echo", "a b"], environment: [ContainerEnvironmentEntry(name: "MODE", value: "test")], cpus: 4, memoryMiB: 1024)
        let draft = ContainerDraft(spec)
        #expect(draft.commandLine == #"echo "a b""#)
        #expect(draft.environmentText == "MODE=test")
        #expect(draft.textIsEditable)
    }

    @Test func aCommandThatHoldsADoubleQuoteCannotBeEditedAsTextAndIsKept() throws {
        let spec = ContainerSpec(command: ["sh", "-c", #"echo "hi""#])
        var draft = ContainerDraft(spec)
        #expect(!draft.textIsEditable)
        draft.spec.cpus = 3
        draft.commandLine = "something else"
        let machine = try draft.applied(to: VMConfig.newContainer(name: "box", container: spec))
        #expect(machine.container?.command == spec.command, "the text is not read when it cannot stand for the stored command")
        #expect(machine.container?.cpus == 3)
    }

    @Test func anEditedDraftChangesTheSettingsAndTrimsTheImage() throws {
        var draft = ContainerDraft(ContainerSpec())
        draft.spec.image = "  ghcr.io/example/tool:2 \n"
        draft.commandLine = #"/bin/sh -c "echo hi""#
        draft.environmentText = "A=1\nB=2"
        draft.spec.network = .loopback
        let machine = try draft.applied(to: VMConfig.newContainer(name: "box"))
        let spec = try #require(machine.container)
        #expect(spec.image == "ghcr.io/example/tool:2")
        #expect(spec.command == ["/bin/sh", "-c", "echo hi"])
        #expect(spec.environment.map(\.name) == ["A", "B"])
        #expect(spec.network == .loopback)
        #expect(machine.workload == .container)
    }

    @Test func aDraftTheConfigurationRefusesSaysWhy() throws {
        var draft = ContainerDraft(ContainerSpec())
        draft.environmentText = "A=1\nA=2"
        let config = VMConfig.newContainer(name: "box")
        let error = try #require(throws: (any Error).self) { try draft.applied(to: config) }
        #expect(VMConfig.reason(for: error) == "container.environment must not name A twice")

        draft.environmentText = ""
        draft.commandLine = #"echo "open"#
        let quote = try #require(throws: (any Error).self) { try draft.applied(to: config) }
        #expect(VMConfig.reason(for: quote).contains("double quote"))

        draft.commandLine = ""
        draft.spec.image = "has space"
        let image = try #require(throws: (any Error).self) { try draft.applied(to: config) }
        #expect(VMConfig.reason(for: image).contains("container.image"))
    }

    @Test func theDraftLeavesTheRestOfTheConfigurationAlone() throws {
        var config = VMConfig.newContainer(name: "box")
        config.agentAccess = true
        let draft = ContainerDraft(config.container ?? ContainerSpec())
        #expect(try draft.applied(to: config) == config)
    }
}

/// What the exposure summary says about a container, and that a container takes no security profile.
struct ContainerExposureTests {
    private func lines(_ config: VMConfig) -> [String] { config.exposures.map(\.text) }

    @Test func aContainerListsTheHelperTheImageAndWhatDoesNotApply() throws {
        let config = VMConfig.newContainer(name: "box", container: ContainerSpec(image: "ghcr.io/example/tool:1"))
        let helper = try #require(config.exposures.first { $0.text.contains("ContainerRunner") })
        #expect(helper.level == .medium)
        for phrase in ["own lightweight Linux virtual machine", "not sandboxed", "virtualization entitlement only"] {
            #expect(helper.text.contains(phrase), "missing: \(phrase)")
        }
        let image = try #require(config.exposures.first { $0.text.hasPrefix("Image:") })
        #expect(image.level == .medium)
        #expect(image.text.contains("ghcr.io/example/tool:1") && image.text.contains("registry") && image.text.contains("trust"))
        let notApplicable = try #require(config.exposures.first { $0.text.contains("do not apply") })
        #expect(
            notApplicable.text
                == "This app's network policy, filtered network, shared folders and security profiles do not apply to a container.")
    }

    @Test func aContainerListsNoVirtualMachineChannel() {
        var config = VMConfig.newContainer(name: "box")
        config.sharedFolders = [SharedFolder(path: "/tmp/a")]
        config.audioInput = true
        config.networkMode = .nat
        let text = lines(config).joined(separator: "\n")
        for absent in ["NAT", "can reach the internet", "/tmp/a", "microphone", "Suspending", "Persistent", "Secure Boot", "Clipboard"] {
            #expect(!text.contains(absent), "a container does not have: \(absent)")
        }
        #expect(config.exposures.count == 4)
    }

    @Test func theNetworkLineFollowsTheContainersNetwork() throws {
        let none = VMConfig.newContainer(name: "box", container: ContainerSpec(network: .none))
        let loopback = VMConfig.newContainer(name: "box", container: ContainerSpec(network: .loopback))
        let noneLine = try #require(none.exposures.first { $0.text.hasPrefix("Network:") })
        let loopbackLine = try #require(loopback.exposures.first { $0.text.hasPrefix("Network:") })
        #expect(noneLine.level == .none && noneLine.text.contains("none"))
        #expect(loopbackLine.level == .low && loopbackLine.text.contains("loopback only"))
        #expect(loopbackLine.text.contains("cannot reach your network or the internet"))
    }

    @Test func agentAccessIsListedOnlyWhenOn() {
        var config = VMConfig.newContainer(name: "box")
        #expect(!lines(config).contains { $0.hasPrefix("Agent access") })
        config.agentAccess = true
        #expect(config.exposures.filter { $0.text.hasPrefix("Agent access") }.count == 1)
        #expect(config.exposures.contains { $0.text == config.agentAccessExposure.text })
    }

    @Test func noLineClaimsAContainerIsAsIsolatedAsAVirtualMachine() {
        let text = lines(VMConfig.newContainer(name: "box")).joined(separator: " ")
        #expect(text.contains("Do not treat it as equal to a virtual machine"))
        #expect(!text.contains("as isolated") && !text.contains("fully isolated") && !text.contains("sandboxed by"))
    }

    @Test(arguments: SecurityProfile.allCases)
    func aContainerMatchesNoProfileAndTakesNone(profile: SecurityProfile) {
        let config = VMConfig.newContainer(name: "box")
        #expect(config.detectedProfile == nil)
        #expect(config.applying(profile) == config)
    }

    @Test func aVirtualMachinesProfilesAreUnchanged() {
        let config = VMConfig.new(name: "vm", guest: .linux)
        #expect(config.detectedProfile == .standard)
        #expect(config.applying(.isolated).detectedProfile == .isolated)
        #expect(config.applying(.isolated) != config)
        #expect(config.exposures.contains { $0.text.hasPrefix("Network:") && $0.text.contains("internet") })
    }
}

/// `AllowContainers`: parsed like the other Allow keys, and a start is refused while it is off.
@MainActor
struct AllowContainersTests {
    private func forced(_ values: [String: Any]) -> ManagedPreferences {
        ManagedPreferences(forcedValue: { values[$0] })
    }

    @Test func theKeyIsNamedAsAdministratorsWriteIt() {
        #expect(ManagedKey.allowContainers.rawValue == "AllowContainers")
    }

    @Test func nothingForcedAllowsContainers() {
        let policy = ManagedPreferences(forcedValue: { _ in nil })
        #expect(!policy.isLocked(.allowContainers))
        #expect(policy.offeredWorkloads == [.vm, .container])
    }

    @Test func forcedTrueAllowsContainers() {
        let policy = forced(["AllowContainers": true])
        #expect(!policy.isLocked(.allowContainers))
        #expect(policy.offeredWorkloads == [.vm, .container])
    }

    @Test func anythingButTrueDeniesContainers() {
        let values: [Any] = [false, 0, 1, "true", "yes", "false"]
        for value in values {
            let policy = forced(["AllowContainers": value])
            #expect(policy.isLocked(.allowContainers), "\(value)")
            #expect(policy.offeredWorkloads == [.vm], "\(value)")
        }
    }

    @Test func denyingContainersChangesNoOtherKeyAndNoMachine() {
        let policy = forced(["AllowContainers": false])
        #expect(!policy.isLocked(.allowSharedFolders) && !policy.isLocked(.allowControlService))
        let config = VMConfig.newContainer(name: "box")
        #expect(policy.clamp(config) == config, "the machine stays; only its start is refused")
    }

    @Test func aDeniedContainerStartIsRefusedBeforeTheRunnerIsLookedFor() async throws {
        let directory = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let denied = forced(["AllowContainers": false])
        let factory = ContainerMachineFactory(runner: directory.appending(path: "absent"), policy: { denied })
        await #expect(throws: ContainerProcessError(reason: ManagedPreferences.containersDeniedMessage)) {
            _ = try await factory.prepare(
                VMConfig.newContainer(name: "box"), bundle: VMBundle(url: directory), display: (1280, 800), suspendAllowed: false)
        }
    }

    @Test func anAllowedContainerStartGoesOnToTheRunnerCheck() async throws {
        let directory = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let allowed = forced(["AllowContainers": true])
        let factory = ContainerMachineFactory(runner: directory.appending(path: "absent"), policy: { allowed })
        await #expect(throws: ContainerProcessError(reason: ContainerMachineFactory.missingRunnerMessage)) {
            _ = try await factory.prepare(
                VMConfig.newContainer(name: "box"), bundle: VMBundle(url: directory), display: (1280, 800), suspendAllowed: false)
        }
    }

    @Test func theControllerReportsTheRefusalAndStaysStopped() async throws {
        let directory = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let library = VMLibrary(machinesDirectory: directory)
        let config = VMConfig.newContainer(name: "box")
        try library.add(config)
        let denied = forced(["AllowContainers": false])
        let router = RoutingMachineFactory(
            virtualMachines: FakeFactory(),
            containers: ContainerMachineFactory(runner: directory.appending(path: "absent"), policy: { denied }))
        let controller = VMController(factory: router, latency: LatencyActivity(host: ProcessInfo.processInfo, isEnabled: false))

        await controller.start(config, bundle: library.bundle(config.id), library: library)

        #expect(controller.errorMessage == ManagedPreferences.containersDeniedMessage)
        #expect(controller.state == .stopped && controller.guest == nil)
    }
}

/// The words a machine is called in alerts and tooltips.
@MainActor
struct MachineWordingTests {
    @Test func aVirtualMachineKeepsItsWording() {
        #expect(MachineWording.errorTitle(for: .vm) == "Virtual Machine Error")
        #expect(MachineWording.startHelp(for: .vm, hasSavedState: false) == "Start the virtual machine")
        #expect(MachineWording.startHelp(for: .vm, hasSavedState: true) == "Resume from suspended state")
        #expect(MachineWording.deleteDetail(for: .vm) == "The virtual disk and all its contents are permanently removed.")
        let report = "The virtual machine stopped: the GPU hung"
        #expect(MachineWording.report(report, for: .vm) == report)
    }

    @Test func aContainerIsCalledAContainer() {
        #expect(MachineWording.errorTitle(for: .container) == "Container Error")
        #expect(MachineWording.startHelp(for: .container, hasSavedState: false) == "Start the container")
        #expect(MachineWording.startHelp(for: .container, hasSavedState: true) == "Start the container")
        #expect(!MachineWording.deleteDetail(for: .container).contains("virtual disk"))
        #expect(
            MachineWording.report("The virtual machine stopped: it ended", for: .container) == "The container stopped: it ended")
    }

    @Test func aReportThatNamesNoMachineIsLeftAlone() {
        for message in ["Couldn't suspend: x", ContainerMachineFactory.missingRunnerMessage, ManagedPreferences.containersDeniedMessage] {
            #expect(MachineWording.report(message, for: .container) == message)
        }
    }

    @Test func theStateMachineStillReportsWithTheSharedPrefix() {
        let moved = MachineState.running.transition(on: .stoppedWithError("e"))
        #expect(moved == .moved(.stopped, [.release, .report(MachineWording.virtualMachineStoppedPrefix + "e")]))
    }

    @Test func theQuitAlertCountsEachKindInItsOwnWords() {
        #expect(MachineWording.quitTitle(virtualMachines: 1, containers: 0) == "1 virtual machine is still running.")
        #expect(MachineWording.quitTitle(virtualMachines: 2, containers: 0) == "2 virtual machines are still running.")
        #expect(MachineWording.quitTitle(virtualMachines: 0, containers: 1) == "1 container is still running.")
        #expect(MachineWording.quitTitle(virtualMachines: 0, containers: 3) == "3 containers are still running.")
        #expect(MachineWording.quitTitle(virtualMachines: 1, containers: 1) == "2 machines are still running.")
    }

    @Test func theQuitDetailSaysWhatQuittingDoesToEachKind() {
        let virtualMachines = MachineWording.quitDetail(virtualMachines: 2, containers: 0)
        #expect(
            virtualMachines == "Quitting force-stops them, like pulling the power cord. Suspend or shut them down first to avoid data loss."
        )
        let containers = MachineWording.quitDetail(virtualMachines: 0, containers: 2)
        #expect(containers.contains("asks each container to stop") && !containers.contains("power cord"))
        let both = MachineWording.quitDetail(virtualMachines: 1, containers: 1)
        #expect(both.contains("force-stops the virtual machines") && both.contains("asks each container to stop"))
    }

    @Test func theMachineModelUsesTheWordingOfItsKind() throws {
        let directory = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let library = VMLibrary(machinesDirectory: directory)
        let box = VMConfig.newContainer(name: "box")
        var vm = VMConfig.new(name: "vm", guest: .linux)
        vm.isProvisioned = true
        try library.add(box)
        try library.add(vm)

        let boxModel = library.model(for: box.id)
        boxModel.errorMessage = "The virtual machine stopped: gone"
        #expect(boxModel.workload == .container && boxModel.startHelp == "Start the container")
        #expect(boxModel.errorMessage == "The container stopped: gone")

        let vmModel = library.model(for: vm.id)
        vmModel.errorMessage = "The virtual machine stopped: gone"
        #expect(vmModel.workload == .vm && vmModel.startHelp == "Start the virtual machine")
        #expect(vmModel.errorMessage == "The virtual machine stopped: gone")
    }
}

/// The help for containers says what the code does.
@MainActor
struct ContainersHelpTests {
    private var text: String {
        let entry = HelpTopic.containers.entry
        return (entry.paragraphs + entry.advanced).joined(separator: " ")
    }

    @Test func theTopicIsInTheMachinesAreaAndFoundBySearch() {
        #expect(HelpTopic.containers.area == .machines)
        #expect(HelpCatalog.search("ContainerRunner").contains(.containers))
        #expect(HelpTopic.guestSystems.entry.related.contains(.containers))
    }

    @Test func theTopicStatesTheIsolationTheImageTheNetworkTheFolderAndTheOutput() {
        for phrase in [
            "own lightweight Linux virtual machine", "separate helper process", "ContainerRunner", "virtualization entitlement only",
            "not sandboxed", "pulls the image from its registry over the network", "container-scratch", "kernel and the image cache",
            "not removed automatically", "None, or loopback only", "no outside network yet", "filtered before it is shown", "bounded",
            "network policy, filtered network, shared folders and security profiles do not apply",
        ] {
            #expect(text.contains(phrase), "missing: \(phrase)")
        }
    }

    @Test func theStopWordingMatchesTheGraceTimes() {
        let timing = ContainerProcess.Timing()
        #expect(timing.stopGrace == .seconds(10) && timing.terminateGrace == .seconds(5))
        for phrase in [
            "sends the helper a stop line", "after 10 seconds it gets SIGTERM", "after 5 more seconds SIGKILL",
            "Quitting the app stops every running container",
        ] {
            #expect(text.contains(phrase), "missing: \(phrase)")
        }
    }

    @Test func theLimitsInTheTextAreTheLimitsOfTheCode() {
        #expect(ContainerLimits.maxImageBytes == 255 && ContainerLimits.cpus == 1...16 && ContainerLimits.memoryMiB == 128...16384)
        #expect(ContainerLimits.maxCommandElements == 64 && ContainerLimits.maxCommandElementBytes == 4096)
        #expect(ContainerLimits.maxEnvironmentEntries == 64 && ContainerLog.defaultLimit == 1024 * 1024)
        for phrase in ["255 bytes", "1 to 16 CPU cores", "128 to 16384 MiB", "64 command words of up to 4096 bytes", "recent 1 MiB"] {
            #expect(text.contains(phrase), "missing: \(phrase)")
        }
    }

    @Test func theManagedSettingsTopicNamesTheNewKey() {
        let managed = HelpTopic.managedSettings.entry.paragraphs.joined(separator: " ")
        #expect(managed.contains("`AllowContainers`"))
        #expect(text.contains("`AllowContainers`"))
    }
}
