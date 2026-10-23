extension HelpCatalog {
    /// The control service for scripts and AI agents, and the switches that open it.
    static let automation: [HelpTopic: HelpEntry] = [
        .agentAccess: HelpEntry(
            area: .security,
            title: "Agent access",
            summary: "Lets scripts and AI agents with a control token see this machine and start or stop it. Off by default.",
            paragraphs: [
                "VMRunner can be driven by scripts and AI agents through its control service, a private local socket on your Mac "
                    + "that stays off until you turn it on in Settings. Each machine decides for itself: an agent sees and acts on "
                    + "a machine only while its **Allow agent access** switch is on.",
                "With it on, an agent that holds a control token can list the machine, read its state, and start or stop it, as "
                    + "far as its token allows. It cannot see the screen, type into the guest or run commands in it.",
                "The Isolated and Hardened profiles turn it off. While it is on, \"What this machine can reach\" says so.",
            ],
            advanced: [
                "An agent's start never asks you anything: if the machine uses folders or disks you have not approved in VMRunner, "
                    + "the start is refused. Start the machine once from the app to approve them."
            ],
            related: [.exposureSummary, .securityProfiles, .serialConsole]
        )
    ]
}
