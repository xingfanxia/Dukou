// swift-tools-version: 6.0
import PackageDescription

// Dukou ships two signed Mach-O binaries in one bundle: the resident menu bar
// app and the `com.apple.share-services` extension inside it. SwiftPM has no
// notion of an `.appex`, so both are plain executables here and
// `Scripts/make-app.sh` assembles and signs the bundle around them.
let package = Package(
    name: "Dukou",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Dukou", targets: ["DukouApp"]),
        .executable(name: "DukouShare", targets: ["DukouShare"]),
        .executable(name: "DukouShareTargetsHost", targets: ["DukouShareTargetsHost"]),
        .library(name: "DukouCore", targets: ["DukouCore"]),
    ],
    dependencies: [
        // Only the app links it. The extensions never update anything, and a
        // framework inside an appex would be a second copy to sign and notarise.
        .package(url: "https://github.com/sparkle-project/Sparkle.git", exact: "2.9.6"),
    ],
    targets: [
        // Built with `-application-extension` on purpose: the shared inbox code
        // runs inside the share extension, and the compiler is the only thing
        // that reliably catches an API that is unavailable there.
        .target(
            name: "DukouCore",
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .unsafeFlags(["-application-extension"]),
            ]
        ),
        // Reading voice transcripts out of WeChat's own message database, an
        // opt-in of the app's (`WeChatDatabase`). Apart from DukouCore so the
        // share extensions link neither SQLite nor the zstd decoder.
        .target(
            name: "DukouWeChatDatabase",
            dependencies: ["DukouCore", "CZstd"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        // zstd's own single-file decoder, generated from facebook/zstd v1.5.7
        // with its build/single_file_libs/combine.sh (THIRD-PARTY-NOTICES.md).
        // WeChat compresses long texts and every XML payload in its message
        // database with zstd, and the shipped app must not lean on a library
        // installed beside it.
        .target(
            name: "CZstd",
            exclude: ["LICENSE"]
        ),
        .executableTarget(
            name: "DukouApp",
            dependencies: [
                "DukouCore",
                "DukouWeChatDatabase",
                .product(name: "Sparkle", package: "Sparkle"),
            ],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        // An app extension has no `main`: dyld enters at `NSExtensionMain`,
        // which reads `NSExtensionPrincipalClass` from the appex Info.plist.
        // Xcode expresses this as `-e _NSExtensionMain`; SwiftPM needs the same
        // flag spelled out, plus an (empty) main.swift so the target still
        // satisfies SwiftPM's executable rule.
        .executableTarget(
            name: "DukouShare",
            dependencies: ["DukouCore"],
            swiftSettings: [
                .swiftLanguageMode(.v5),
                .unsafeFlags(["-application-extension"]),
            ],
            linkerSettings: [
                .unsafeFlags([
                    "-Xlinker", "-e", "-Xlinker", "_NSExtensionMain",
                    "-Xlinker", "-application_extension",
                ])
            ]
        ),
        // The placeholder executable of each generated 「发给 <app>」 entry:
        // the Share menu draws an entry with its containing app's icon, so
        // every entry needs an app of its own. Never launched; it exits at once
        // if someone opens it.
        .executableTarget(
            name: "DukouShareTargetsHost",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "DukouCoreTests",
            dependencies: ["DukouCore", "DukouWeChatDatabase"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
