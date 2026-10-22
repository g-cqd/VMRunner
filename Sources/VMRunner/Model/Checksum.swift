struct Checksum: Codable, Hashable, Sendable {
    /// The hash a checksum was made with. Only SHA-256 can vouch for a file. Any other name a stored configuration holds
    /// (`sha1`, from before SHA-1 was refused) decodes as `refused` with that name, and is written back unchanged: the
    /// machine still loads, and fetching its image fails with `SetupError.weakChecksum` before any request.
    enum Algorithm: Hashable, Sendable, Codable {
        case sha256
        case refused(String)

        init(from decoder: any Decoder) throws {
            let name = try decoder.singleValueContainer().decode(String.self)
            self = name == "sha256" ? .sha256 : .refused(name)
        }

        func encode(to encoder: any Encoder) throws {
            var container = encoder.singleValueContainer()
            try container.encode(name)
        }

        /// The name a configuration stores.
        var name: String {
            switch self {
            case .sha256: "sha256"
            case .refused(let name): name
            }
        }
    }

    var algorithm: Algorithm
    var value: String
}
