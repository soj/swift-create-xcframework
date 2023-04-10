//
//  Command.swift
//  swift-create-xcframework
//
//  Created by Rob Amos on 7/5/20.
//

import ArgumentParser
import Foundation
import PackageLoading
import PackageModel
import TSCBasic
import Workspace
import Xcodeproj

struct Command: ParsableCommand {

    // MARK: - Configuration

    static var configuration = CommandConfiguration (
        abstract: "Creates an XCFramework out of a Swift Package using xcodebuild",
        discussion:
            """
            Note that Swift Binary Frameworks (XCFramework) support is only available in Swift 5.1
            or newer, and so it is only supported by recent versions of Xcode and the *OS SDKs. Likewise,
            only Apple platforms are supported.

            Supported platforms: \(TargetPlatform.allCases.map({ $0.rawValue }).joined(separator: ", "))
            """,
        version: "2.3.0"
    )


    // MARK: - Arguments

    @OptionGroup()
    var options: Options


    // MARK: - Execution

    // swiftlint:disable:next function_body_length
    func run() throws {

        // load all/validate of the package info
        let package = try PackageInfo(options: self.options)

        // validate that package to make sure we can generate it
        let validation = package.validationErrors()
        if validation.isEmpty == false {
            for error in validation {
                print((error.isFatal ? "Error:" : "Warning:"), error.errorDescription!)
            }
            if validation.contains(where: { $0.isFatal }) {
                Darwin.exit(1)
            }
        }

        // generate the Xcode project file
        let generator = ProjectGenerator(package: package)

        let platforms = try package.supportedPlatforms()

        // get what we're building
        try generator.writeDistributionXcconfig()
        let project = try generator.generate()

        // printing packages?
        if self.options.listProducts {
            package.printAllProducts(project: project)
            Darwin.exit(0)
        }

        // get valid packages and their SDKs
        let productNames = try package.validProductNames(project: project)
        let sdks = platforms.flatMap { $0.sdks }

        // we've applied the xcconfig to everything, but some dependencies (*cough* swift-nio)
        // have build errors, so we remove it from targets we're not building
        if self.options.stackEvolution == false {
            try project.enableDistribution(targets: productNames, xcconfig: AbsolutePath(package.distributionBuildXcconfig.path).relative(to: AbsolutePath(package.rootDirectory.path)))
        }

        // save the project
        try project.save(to: generator.projectPath)

        // start building
        let builder = XcodeBuilder(project: project, projectPath: generator.projectPath, package: package, options: self.options)

        // clean first
        if self.options.clean {
            try builder.clean()
        }

        // all of our targets for each platform, then group the resulting .frameworks by target
        var frameworkFiles: [String: [XcodeBuilder.BuildResult]] = [:]

        for sdk in sdks {
            try builder.build(targets: productNames, sdk: sdk)
                .forEach { pair in
                    if frameworkFiles[pair.key] == nil {
                        frameworkFiles[pair.key] = []
                    }
                    frameworkFiles[pair.key]?.append(pair.value)
                }
        }

        var xcframeworkFiles: [(String, Foundation.URL)] = []

        // then we merge the resulting frameworks
        try frameworkFiles
            .forEach { pair in
                xcframeworkFiles.append((pair.key, try builder.merge(target: pair.key, buildResults: pair.value)))
            }

        // zip it up if thats what they want
        if self.options.zip {
            let zipper = Zipper(package: package)
            let zipped = try xcframeworkFiles
                .flatMap { pair -> [Foundation.URL] in
                    let zip = try zipper.zip(target: pair.0, version: self.options.zipVersion, file: pair.1)
                    let checksum = try zipper.checksum(file: zip)
                    //try zipper.clean(file: pair.1)

                    return [ zip, checksum ]
                }

            // notify the action if we have one
            if self.options.githubAction {
                let zips = zipped.map({ $0.path }).joined(separator: "\n")
                let data = Data(zips.utf8)
                let url = Foundation.URL(fileURLWithPath: self.options.buildPath).appendingPathComponent("xcframework-zipfile.url")
                try data.write(to: url)
            }

        }
    }
}


// MARK: - Errors

private enum Error: Swift.Error, LocalizedError {
    case noProducts

    var errorDescription: String? {
        switch self {
        case .noProducts:           return ""
        }
    }
}
