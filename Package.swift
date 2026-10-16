// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Jotvella",
    platforms: [.macOS(.v13)],
    products: [.executable(name: "Jotvella", targets: ["Jotvella"])],
    targets: [.executableTarget(name: "Jotvella", resources: [.copy("Resources/jotvella-one-importer")])]
)
