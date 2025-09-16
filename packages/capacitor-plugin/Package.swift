// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "CapacitorGeolocation",
    platforms: [.iOS(.v14)],
    products: [
        .library(
            name: "CapacitorGeolocation",
            targets: ["GeolocationPlugin"])
    ],
    dependencies: [
        .package(url: "https://github.com/ionic-team/capacitor-swift-pm.git", from: "7.0.0"),
        .package(url: "https://github.com/ionic-team/ion-ios-geolocation.git", from: "1.0.2")
    ],
    targets: [
        .target(
            name: "GeolocationPlugin",
            dependencies: [
                .product(name: "Capacitor", package: "capacitor-swift-pm"),
                .product(name: "Cordova", package: "capacitor-swift-pm"),
                .product(name: "IONGeolocationLib", package: "ion-ios-geolocation")
            ],
            path: "ios/Sources/GeolocationPlugin"),
        .testTarget(
            name: "GeolocationPluginTests",
            dependencies: ["GeolocationPlugin"],
            path: "ios/Tests/GeolocationTests")
    ]
)
