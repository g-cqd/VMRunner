struct Checksum: Codable, Hashable, Sendable {
    enum Algorithm: String, Codable, Sendable { case sha1, sha256 }
    var algorithm: Algorithm
    var value: String
}
