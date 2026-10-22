import NetStack

extension HelpCatalog {
    /// The stack's defaults, so the limits the help states are the limits it enforces.
    private static let limits = UserNetConfig()

    static let filteredNetwork: [HelpTopic: HelpEntry] = [
        .networkPolicy: HelpEntry(
            area: .network,
            title: "Filtered network and policy",
            summary: "Lets you decide which places the guest may connect to, and see what it tried.",
            paragraphs: [
                "With **Filtered (user-mode)** networking, VMRunner itself stands between the guest and the internet. Every "
                    + "connection the guest opens is checked against your rules before it is made. Blocked ones never leave your Mac.",
                "• **Block list**: everything is allowed except what you block. A good start for a guest that needs the internet "
                    + "but should not reach certain places.",
                "• **Allow list**: everything is blocked except what you allow. Best for a guest that only needs a few services. "
                    + "Until you allow something, the guest has no network. The guest can also only look up the names you allow; "
                    + "any other lookup is refused.",
                "• **A block rule always wins** over an allow rule.",
                "• **Block my Mac and local networks** (on by default) keeps the guest away from your router and the other devices "
                    + "on your network, and from your Mac under its network address. Turn it off only if the guest must reach them.",
                "• **Your Mac's own addresses are always blocked**, whatever you set: loopback (`127.0.0.1`), `0.0.0.0`, "
                    + "link-local addresses including the cloud metadata address `169.254.169.254`, and the virtual networks' own "
                    + "ranges. An allow rule cannot open them.",
                "• **When a connection is blocked**: *refuse* tells the guest at once; *ignore* says nothing, so programs wait "
                    + "until they time out.",
                "• **Reset connections when my Mac changes network**: after Wi-Fi, Ethernet or a VPN changes, open connections "
                    + "are reset so the guest reconnects over the new path.",
                "Rules are read when the machine starts. While it runs, the toolbar's network button shows recent connections, "
                    + "allowed and blocked, with the reason, and the VPN indicators. Blocked attempts to the same place, and the "
                    + "same DNS answer, repeated within a few seconds, are one line with a count (\"× 40\").",
                "Filtered networking is new and has not been validated against every guest. If something does not work, "
                    + "switch the machine back to NAT.",
            ],
            advanced: [
                "The guest gets a virtio network card connected to a user-mode TCP/IP stack in this app. The guest lives on "
                    + "`198.18.0.0/24` (gateway and DNS `198.18.0.1`, guest `198.18.0.2`, assigned by a built-in DHCP server). "
                    + "Connections are relayed with ordinary Mac sockets, so they leave through whatever network your Mac uses "
                    + "right now, including a VPN's default route.",
                "Evaluation order: malformed destinations, blocked ports, blocked domains, blocked connections, then the "
                    + "always-blocked ranges, the private-range switch and the blocked-address checks on every address involved. "
                    + "In allow-list mode the destination must then match an allowed connection, or an allowed domain or address "
                    + "(and an allowed port when ports are listed).",
                "One thread handles all of the guest's traffic, so very fast transfers can be slower than NAT. Suspend may be "
                    + "unavailable with this mode; the Suspend button explains if so, and changing the network mode discards a "
                    + "suspended state.",
            ],
            related: [.policyRules, .policyLimits, .guestVpn, .networkMode, .exposureSummary]
        ),
        .policyRules: HelpEntry(
            area: .network,
            title: "Network rules",
            summary: "What each list in the network policy matches, with examples.",
            paragraphs: [
                "Type a rule and press Return or **Add**. A rule that cannot be understood is explained under the field and is not "
                    + "added. Each list holds up to \(EditorLimits.maxRulesPerList) rules of up to "
                    + "\(EditorLimits.maxRuleLength) characters.",
                "• **Domains**: `example.com` is exactly that name. `*.example.com` is every subdomain (`a.example.com`, "
                    + "`a.b.example.com`) but not `example.com` itself; add both to cover both.",
                "• **IP addresses**: one address (`203.0.113.7`) or a block in CIDR form (`203.0.113.0/24`).",
                "• **Ports**: one port (`443`) or a range (`8000-8100`). In the allow list, once you list ports, a destination "
                    + "must use one of them.",
                "• **Connections**: a destination plus ports, for example `github.com:443` or `10.0.0.0/8:22,80`. In the allow "
                    + "list this means \"only HTTPS to GitHub\"; in the block list, \"no SSH to that network\". No ports means all "
                    + "ports.",
                "• **URL prefixes**: plain `http://` addresses, matched by path (`http://example.com/downloads`). Encrypted "
                    + "`https://` paths cannot be seen, so they are not accepted here: block the domain instead. These rules are "
                    + "saved but **not applied to traffic yet**: the filter decides per connection and does not read requests, "
                    + "so a path rule changes nothing today (see \"What filtering can and cannot do\").",
                "Block rules apply in both modes. Allow rules only matter in allow-list mode.",
            ],
            advanced: [
                "Names are lower-cased, a trailing dot is ignored, and internationalized names must be written in `xn--` form. "
                    + "A name that is really an address in disguise (`127.1`, `2130706433`) is refused as a domain; add it as an "
                    + "IP address. IPv6 rules are accepted, but the guest is not given IPv6 today.",
                "URL prefixes match on path segments (`/admin` covers `/admin/x` but not `/administrator`), after decoding and "
                    + "resolving `..`. Query strings, fragments and credentials are not allowed in a rule.",
                "A connection rule with an address target blocks when any address involved is inside it, and allows only when "
                    + "every address involved is inside it.",
            ],
            related: [.networkPolicy, .policyLimits]
        ),
        .policyLimits: HelpEntry(
            area: .network,
            title: "What filtering can and cannot do",
            summary: "Where the rules are strong, where they are only a hint, and what gets through.",
            paragraphs: [
                "• **Address and port rules are firm.** VMRunner connects only to the exact address it checked.",
                "• **URL prefix rules do nothing yet.** The filter judges each connection by its name, its address and its port; "
                    + "it does not read the request inside it, so a rule for one path of a site leaves the whole site reachable "
                    + "(checked on a real guest). To keep a site out, block its domain or its addresses.",
                "• **Domain rules are advisory.** VMRunner learns names from the guest's DNS questions. When several names share "
                    + "one address (common with content networks), a rule for one name can affect the others, and a guest that "
                    + "already knows an address can connect without asking DNS. A rule for a name on some ports "
                    + "(`example.com:22`) keeps holding for the addresses VMRunner gave the guest for that name after the answer "
                    + "expires. A block rule for a name on some ports stops applying to an address 12 hours after the guest last "
                    + "resolved it. Use address rules when it must hold.",
                "• **Encrypted DNS is not intercepted.** Ordinary DNS (port 53) is always answered by VMRunner, even if the guest "
                    + "asks another server. DNS over HTTPS, DNS over TLS and DNS over QUIC look like normal encrypted traffic, so "
                    + "domain rules can be dodged that way. Block those servers by address or port (853).",
                "• **DNS answers only what a guest needs.** Your Mac's resolver can reach more than the guest could (company "
                    + "zones behind a VPN, `.local` names on your network), so VMRunner does not pass every question on. It "
                    + "answers address, alias (CNAME) and reverse (PTR) lookups; other record types (TXT, MX, SRV, HTTPS) get "
                    + "\"not implemented\". Names ending in `.local` or `.arpa` are refused, except the reverse lookup of an "
                    + "address your rules allow. Addresses your rules would block (your Mac, local networks) are removed from "
                    + "answers, and a name left with none is refused. Lookups never use your Mac's search domains. A refused "
                    + "name still tells the guest something (its refusal differs from a name that does not exist), so keep "
                    + "secrets out of names.",
                "• **Limits on a busy guest.** At most \(limits.maxTCPFlows) connections and \(limits.maxUDPFlows) UDP or ping flows "
                    + "are open at once (the longest idle UDP and ping flows are closed to make room), \(limits.maxDNSTCPFlows) of "
                    + "the connections can be DNS lookups over TCP, and a guest can start \(limits.datagramFlowBurst) new UDP or ping "
                    + "flows at once, then \(Int(limits.datagramFlowsPerSecond)) a second. Anything beyond is refused as too many "
                    + "connections.",
                "• **No IPv6.** The guest is given IPv4 only, and IPv6 traffic is dropped.",
                "• **IPsec and PPTP cannot pass.** Tunnels that need protocols other than TCP, UDP and ping (ESP, AH, GRE) do "
                    + "not work through this network. VMRunner detects them; see VPN indicators.",
                "• **Other unsupported traffic**: IP fragments from the guest, multicast and broadcast (mDNS, SSDP, NetBIOS) are "
                    + "dropped, and there is no traceroute.",
                "• **Not covered by the network rules**: shared folders, the clipboard and other devices. Check the security "
                    + "summary for those.",
                "This is a young implementation and has not been validated against every guest. It narrows what the guest can "
                    + "reach; it is not a guarantee against software designed to evade it.",
            ],
            advanced: [
                "Whether a name or an address was judged: a connection to an address is checked as that address and, if DNS gave "
                    + "the guest the address, also under each name that led to it. Any block verdict wins; otherwise one allow is "
                    + "enough.",
                "UDP replies are accepted only from the destination the guest first sent to. TCP has no SACK, timestamps or "
                    + "congestion control. The guest's addresses are fixed, so two filtered machines do not see each other.",
            ],
            related: [.networkPolicy, .policyRules, .guestVpn]
        ),
        .guestVpn: HelpEntry(
            area: .network,
            title: "VPN indicators",
            summary: "Shows whether your Mac, or the guest itself, seems to be using a VPN. A hint, not proof.",
            paragraphs: [
                "The network button in the toolbar shows two separate signals:",
                "• **Mac VPN**: a VPN connection is up on your Mac. Guest traffic leaves through your Mac's network, so it "
                    + "usually goes through that VPN too, but a VPN that only covers some destinations may not carry it.",
                "• **Guest VPN**: the guest's own traffic looks like a VPN starting up (WireGuard, OpenVPN, IPsec/IKE, L2TP or "
                    + "PPTP). Rules cannot see inside such a tunnel, so a guest with its own VPN can hide where its traffic goes. "
                    + "VMRunner only reports this; it does not block it.",
                "Confidence is **low** (worth a look), **medium** or **high** (a handshake was seen both ways). The reasons are "
                    + "listed under the indicator.",
                "Both are guesses. A tunnel inside normal HTTPS (many commercial VPNs and proxies), or one built to look like "
                    + "random data, will not be noticed, and an app that happens to speak a VPN protocol can trigger a false alarm.",
                "IPsec and PPTP tunnels started inside the guest cannot pass this network at all, but they are detected and "
                    + "shown here.",
            ],
            advanced: [
                "The Mac signal comes from the system's network path: any usable tunnel-style interface (`utun`, `ipsec`, `ppp`, "
                    + "`tun`, `tap`) counts, so Private Relay or a developer tool's tunnel can read as a VPN, and split tunneling "
                    + "can make it misleading either way.",
                "The guest signal scores fingerprints of handshakes and keepalives (WireGuard initiation packets, the OpenVPN "
                    + "reset opcode, IKE on ports 500 and 4500, ESP and GRE, and a few well-known VPN names in DNS). The "
                    + "indicators only inform; the kill switch (see *Kill switch*) is what acts on the Mac signal.",
            ],
            related: [.networkPolicy, .policyLimits, .networkMode, .killSwitch]
        ),
        .killSwitch: HelpEntry(
            area: .network,
            title: "Kill switch",
            summary: "Disconnects the guest's network while your Mac's VPN or connection breaks this machine's rule.",
            paragraphs: [
                "Two rules can cut the guest's network while the machine runs, with NAT or with the filtered network:",
                "• **VPN on this Mac**: **Required** cuts it while no VPN is up on your Mac; **Forbidden** cuts it while one "
                    + "is. Until VMRunner has read your Mac's network, a moment after the start, the VPN state is unknown and "
                    + "both rules cut, so the guest can start without a network for that moment.",
                "• **Cut the network on a metered or Low Data Mode connection**: cuts it while your Mac uses a connection macOS "
                    + "marks as expensive (a phone's hotspot, a cellular link) or has Low Data Mode on.",
                "The network comes back by itself when the rule is met again; open connections in the guest break and have to "
                    + "reconnect. While it is cut, the toolbar shows **Network cut**, and its tooltip says why.",
                "It watches your **Mac**, not the guest: a VPN on your Mac usually carries the guest's traffic, but one that "
                    + "covers only some destinations may not, and a VPN started inside the guest is not seen (see *VPN "
                    + "indicators*). Changes apply the next time the machine starts.",
            ],
            advanced: [
                "The switch takes the attachment off the guest's virtual network card and puts the same one back, like "
                    + "pulling and replugging a cable: the guest sees its link go down and come up. The Mac's VPN state is read "
                    + "from the system's network path, the same way as the Mac VPN indicator.",
                "If macOS keeps the card connected when the switch pulls it, VMRunner stops the machine and says why, rather "
                    + "than let the guest run with a network the toolbar calls cut.",
                "Not yet verified with a real guest: how quickly each guest notices that the link is back.",
            ],
            related: [.guestVpn, .networkMode, .networkPolicy]
        ),
    ]
}
