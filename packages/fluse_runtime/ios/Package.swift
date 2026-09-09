// swift-tools-version:5.9
import PackageDescription

/// CocoaPods は `fluse_runtime.podspec` を読み、SwiftPM はこの `Package.swift`
/// を読む。どちらも同じ `Classes/` のソースを見る形にしてあり、Xcode
/// プロジェクトを作らずに `swift test` で CI を回せるのが狙い。
///
/// `Classes/FluseRuntimePlugin.swift` は `import Flutter` を持つが、
/// `#if canImport(Flutter)` で囲ってある。Flutter フレームワークが
/// リンクされていないこのパッケージ単体のビルドでは中身が空になるため、
/// コンパイルエラーにはならない（CocoaPods 経由のビルドでは Flutter が
/// 解決されるので、そちらでは通常どおりプラグインとして登録される）。
let package = Package(
    name: "fluse_runtime",
    platforms: [
        .iOS(.v13),
        .macOS(.v11),
    ],
    products: [
        .library(name: "fluse_runtime", targets: ["fluse_runtime"])
    ],
    targets: [
        .target(
            name: "fluse_runtime",
            path: "Classes"
        ),
        .testTarget(
            name: "fluse_runtimeTests",
            dependencies: ["fluse_runtime"],
            path: "Tests/fluse_runtimeTests"
        ),
    ]
)
