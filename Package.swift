// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "EmailCalendarCore",
    platforms: [.macOS(.v15)],
    products: [.library(name: "EmailCalendarCore", targets: ["EmailCalendarCore"])],
    targets: [
        .systemLibrary(name: "CSQLite", path: "CSQLite", pkgConfig: "sqlite3",
                       providers: [.apt(["libsqlite3-dev"]), .brew(["sqlite3"])]),
        .target(name: "EmailCalendarCore", dependencies: ["CSQLite"], path: "EmailCalendar",
                exclude: ["App", "Auth", "UI", "Overlay", "Resources"],
                sources: ["Models", "Data", "Services", "Google"]),
        .testTarget(name: "EmailCalendarCoreTests", dependencies: ["EmailCalendarCore"], path: "Tests")
    ]
)
