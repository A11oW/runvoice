// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "RunvoiceWhisperKitBenchmark",
    platforms: [.macOS("15.0")],
    products: [.executable(name: "WhisperKitBenchmark", targets: ["WhisperKitBenchmark"])],
    dependencies: [
        .package(url: "https://github.com/argmaxinc/argmax-oss-swift.git",
                 revision: "1bbc57cb7fe6410248a685b1c5a3c6d56adc2ed4")
    ],
    targets: [.executableTarget(name: "WhisperKitBenchmark",
                               dependencies: [.product(name: "WhisperKit", package: "argmax-oss-swift")])]
)
