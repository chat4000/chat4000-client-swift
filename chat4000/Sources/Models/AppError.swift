import Foundation

/// Closed application error domain. Per the Swift production standard (Rule 2),
/// our own functions surface failures as values (`Result<T, AppError>` / `T?` /
/// `throws(AppError)`) rather than propagating arbitrary external `Error`s.
///
/// Each boundary `do/catch` that calls a throwing external (Foundation,
/// SwiftData, URLSession, the MatrixSDKCrypto FFI) converts:
///   - an EXPECTED failure → a specific domain case (or `nil`);
///   - an UNEXPECTED failure → `ErrorReporter.capture(...)` then
///     `.failure(.unexpected(error))`.
enum AppError: Error {
    /// A requested resource / value was not present where one was expected.
    case notFound

    /// Decoding (JSON / SwiftData / wire) failed for a classifiable reason.
    case decode(String)

    /// Encoding / serialization failed for a classifiable reason.
    case encode(String)

    /// A network / transport call failed in an expected, classifiable way.
    case network(String)

    /// A non-2xx response from the gateway or homeserver, with the status code.
    case httpStatus(Int)

    /// Persistence (Keychain / SwiftData / file IO) failed in an expected way.
    case storage(String)

    /// The crypto / Olm machine reported a classifiable failure.
    case crypto(String)

    /// Pairing / redeem failed in an expected, user-facing way.
    case pairing(String)

    /// An operation was attempted while not connected / not ready.
    case notReady

    /// A configuration / invariant value (URL, key) was invalid.
    case invalidConfiguration(String)

    /// Catch-all for an unclassified boundary failure. The wrapped `Error` is
    /// the original external error, never altered. Always paired with an
    /// `ErrorReporter.capture(...)` at the boundary that produced it.
    case unexpected(Error)
}

/// Build a `URL` from a hard-coded, compile-time-constant string. A nil here is
/// a programming error in the literal, not a runtime condition, so it trips a
/// message-bearing invariant (Rule 4) instead of a force-unwrap. Never pass
/// runtime/user input to this — parse those into an optional and handle nil.
func requireURL(_ string: String) -> URL {
    guard let url = URL(string: string) else {
        fatalError("hard-coded URL is invalid: \(string)")
    }
    return url
}

/// Encode a compile-time-constant string literal to UTF-8 `Data`. Swift
/// `String` is always UTF-8-encodable, so a nil is impossible for a literal;
/// the invariant documents that and avoids a force-unwrap (Rule 4).
func requireUTF8(_ string: String) -> Data {
    guard let data = string.data(using: .utf8) else {
        fatalError("string literal is not UTF-8 encodable: \(string)")
    }
    return data
}
