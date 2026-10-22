/// UTF-8 text from bytes of unknown quality: an invalid sequence becomes U+FFFD, and nothing fails.
func lossyText<Bytes: Collection<UInt8>>(_ bytes: Bytes) -> String {
    String(decoding: bytes, as: UTF8.self)  // swiftlint:disable:this optional_data_string_conversion
}
