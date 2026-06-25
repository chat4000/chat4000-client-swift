// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "MatrixSDKCrypto",
    platforms: [.iOS(.v16), .macOS(.v12)],
    products: [.library(name: "MatrixSDKCrypto", targets: ["MatrixSDKCrypto"])],
    targets: [
        .binaryTarget(name: "MatrixSDKCryptoFFI", path: "MatrixSDKCryptoFFI.xcframework"),
        .target(name: "MatrixSDKCrypto", dependencies: ["MatrixSDKCryptoFFI"], path: "Sources/MatrixSDKCrypto"),
    ]
)
