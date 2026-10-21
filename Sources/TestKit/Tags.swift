// `public import`: this file extends Swift Testing's `Tag` with a public static member.
public import Testing

extension Tag {
    /// Concurrency and async-coordination suites, so a CI lane can select or exclude them.
    @Tag public static var concurrency: Self
}
