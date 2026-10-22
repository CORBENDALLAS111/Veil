// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "VeilNeural",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "VeilNeuralSmoke", targets: ["VeilNeuralSmoke"])],
    dependencies: [.package(url: "https://github.com/apple-aiml-research/ml-stable-diffusion.git",
                            revision: "ea2805dc1945be20561c77e5f6d1d9a5a637cda2")],
    targets: [
        .executableTarget(name: "VeilNeuralSmoke", dependencies: [.product(name: "StableDiffusion", package: "ml-stable-diffusion")],
                          path: ".", exclude: ["Tests", "UITests", "docs", "scripts", "Sources/Assets.xcassets", "Sources/Processing",
                                               "Sources/StudioModel.swift", "Sources/StudioView.swift", "Sources/VeilApp.swift",
                                               "Sources/Design.swift", "Sources/ComparisonView.swift", "Sources/PrivacyInfo.xcprivacy",
                                               "README.md", "project.yml", "Sources/Licenses", "build"],
                          sources: ["Sources/Neural/NeuralModelStore.swift", "Sources/Neural/NeuralRegenerator.swift", "Tools/NeuralSmoke.swift"],
                          resources: [.copy("Sources/Neural/NeuralManifest.json"), .copy("Sources/Neural/BundledVAE")])
    ]
)
