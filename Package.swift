// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Tendedero",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/scinfu/SwiftSoup.git", exact: "2.14.3")
    ],
    targets: [
        .testTarget(name: "LineIntegrationTests", dependencies: ["Tendedero"], path: "Tests/LineIntegrationTests"),
        .target(name: "NotesCore", path: "Sources/NotesCore"),
        .testTarget(name: "NotesCoreTests", dependencies: ["NotesCore"], path: "Tests/NotesCoreTests"),
        // Resources holds the translations. scripts/build-app.sh copies them
        // into the app, so SwiftPM leaves them alone.
        .executableTarget(name: "Tendedero", dependencies: ["NotesCore", .product(name: "SwiftSoup", package: "SwiftSoup")], path: "Sources/Tendedero", exclude: ["Resources"])
    ]
)
