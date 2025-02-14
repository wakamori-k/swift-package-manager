/*
 This source file is part of the Swift.org open source project

 Copyright (c) 2021 Apple Inc. and the Swift project authors
 Licensed under Apache License v2.0 with Runtime Library Exception

 See http://swift.org/LICENSE.txt for license information
 See http://swift.org/CONTRIBUTORS.txt for Swift project authors
*/

import Basics
import Dispatch
import PackageGraph
import PackageLoading
import PackageModel
import PackageRegistry
import TSCBasic

public class RegistryPackageContainer: PackageContainer {
    public let package: PackageReference

    private let registryClient: RegistryClient
    private let identityResolver: IdentityResolver
    private let manifestLoader: ManifestLoaderProtocol
    private let toolsVersionLoader: ToolsVersionLoaderProtocol
    private let currentToolsVersion: ToolsVersion
    private let observabilityScope: ObservabilityScope

    private var knownVersionsCache = ThreadSafeBox<[Version]>()
    private var toolsVersionsCache = ThreadSafeKeyValueStore<Version, ToolsVersion>()
    private var validToolsVersionsCache = ThreadSafeKeyValueStore<Version, Bool>()
    private var manifestsCache = ThreadSafeKeyValueStore<Version, Manifest>()
    private var availableManifestsCache = ThreadSafeKeyValueStore<Version, (manifests: [String: (toolsVersion: ToolsVersion, content: String?)], fileSystem: FileSystem)>()

    public init(
        package: PackageReference,
        identityResolver: IdentityResolver,
        registryClient: RegistryClient,
        manifestLoader: ManifestLoaderProtocol,
        toolsVersionLoader: ToolsVersionLoaderProtocol,
        currentToolsVersion: ToolsVersion,
        observabilityScope: ObservabilityScope
    ) {
        self.package = package
        self.identityResolver = identityResolver
        self.registryClient = registryClient
        self.manifestLoader = manifestLoader
        self.toolsVersionLoader = toolsVersionLoader
        self.currentToolsVersion = currentToolsVersion
        self.observabilityScope = observabilityScope
    }

    // MARK: - PackageContainer

    public func isToolsVersionCompatible(at version: Version) -> Bool {
        self.validToolsVersionsCache.memoize(version) {
            do {
                let toolsVersion = try self.toolsVersion(for: version)
                try toolsVersion.validateToolsVersion(currentToolsVersion, packageIdentity: package.identity)
                return true
            } catch {
                return false
            }
        }
    }

    public func toolsVersion(for version: Version) throws -> ToolsVersion {
        try self.toolsVersionsCache.memoize(version) {
            let result = try temp_await {
                self.getAvailableManifestsFilesystem(version: version, completion: $0)
            }
            return try self.toolsVersionLoader.load(at: .root, fileSystem: result.fileSystem)
        }
    }

    public func versionsDescending() throws -> [Version] {
        try self.knownVersionsCache.memoize {
            let versions = try temp_await {
                self.registryClient.fetchVersions(
                    package: self.package.identity,
                    observabilityScope: self.observabilityScope,
                    callbackQueue: .sharedConcurrent,
                    completion: $0
                )
            }
            return versions.sorted(by: >)
        }
    }

    public func versionsAscending() throws -> [Version] {
        try self.versionsDescending().reversed()
    }

    public func toolsVersionsAppropriateVersionsDescending() throws -> [Version] {
        try self.versionsDescending().filter(self.isToolsVersionCompatible(at:))
    }

    public func getDependencies(at version: Version, productFilter: ProductFilter) throws -> [PackageContainerConstraint] {
        let manifest = try self.loadManifest(version: version)
        return try manifest.dependencyConstraints(productFilter: productFilter)
    }

    public func getDependencies(at revision: String, productFilter: ProductFilter) throws -> [PackageContainerConstraint] {
        throw InternalError("getDependencies for revision not supported by RegistryPackageContainer")
    }

    public func getUnversionedDependencies(productFilter: ProductFilter) throws -> [PackageContainerConstraint] {
        throw InternalError("getUnversionedDependencies not supported by RegistryPackageContainer")
    }

    public func loadPackageReference(at boundVersion: BoundVersion) throws -> PackageReference {
        return self.package
    }

    // internal for testing
    internal func loadManifest(version: Version) throws -> Manifest {
        return try self.manifestsCache.memoize(version) {
            try temp_await {
                self.loadManifest(version: version, completion: $0)
            }
        }
    }

    private func loadManifest(version: Version,  completion: @escaping (Result<Manifest, Error>) -> Void) {
        self.getAvailableManifestsFilesystem(version: version) { result in
                switch result {
                case .failure(let error):
                    return completion(.failure(error))
                case .success(let result):
                    do {
                        let manifests = result.manifests
                        let fileSystem = result.fileSystem

                        // first, decide the tools-version we should use
                        let preferredToolsVersion = try self.toolsVersionLoader.load(at: .root, fileSystem: fileSystem)
                        // validate preferred the tools version is compatible with the current toolchain
                        try preferredToolsVersion.validateToolsVersion(
                            self.currentToolsVersion,
                            packageIdentity: self.package.identity
                        )
                        // load the manifest content
                        guard let defaultManifestToolsVersion = manifests.first(where: { $0.key == Manifest.filename })?.value.toolsVersion else {
                            throw StringError("Could not find the '\(Manifest.filename)' file for '\(self.package.identity)' '\(version)'")
                        }
                        if preferredToolsVersion == defaultManifestToolsVersion {
                            // default tools version - we already have the content on disk from getAvailableManifestsFileSystem()
                            self.manifestLoader.load(
                                at: .root,
                                packageIdentity: self.package.identity,
                                packageKind: self.package.kind,
                                packageLocation: self.package.locationString,
                                version: version,
                                revision: nil,
                                toolsVersion: preferredToolsVersion,
                                identityResolver: self.identityResolver,
                                fileSystem: result.fileSystem,
                                observabilityScope: self.observabilityScope,
                                on: .sharedConcurrent,
                                completion: completion
                            )
                        } else {
                            // custom tools-version, we need to fetch the content from the server
                            self.registryClient.getManifestContent(
                                package: self.package.identity,
                                version: version,
                                customToolsVersion: preferredToolsVersion,
                                observabilityScope: self.observabilityScope,
                                callbackQueue: .sharedConcurrent
                            ) { result in
                                    switch result {
                                    case .failure(let error):
                                        return completion(.failure(error))
                                    case .success(let manifestContent):
                                        do {
                                            // replace the fake manifest with the real manifest content
                                            let manifestPath = AbsolutePath.root.appending(component: Manifest.basename + "@swift-\(preferredToolsVersion).swift")
                                            try fileSystem.removeFileTree(manifestPath)
                                            try fileSystem.writeFileContents(manifestPath, string: manifestContent)
                                            // finally, load the manifest
                                            self.manifestLoader.load(
                                                at: .root,
                                                packageIdentity: self.package.identity,
                                                packageKind: self.package.kind,
                                                packageLocation: self.package.locationString,
                                                version: version,
                                                revision: nil,
                                                toolsVersion: preferredToolsVersion,
                                                identityResolver: self.identityResolver,
                                                fileSystem: fileSystem,
                                                observabilityScope: self.observabilityScope,
                                                on: .sharedConcurrent,
                                                completion: completion
                                            )
                                        } catch {
                                            return completion(.failure(error))
                                        }
                                    }
                            }
                        }
                    } catch {
                        return completion(.failure(error))
                    }
                }
        }
    }

    private func getAvailableManifestsFilesystem(version: Version, completion: @escaping (Result<(manifests: [String: (toolsVersion: ToolsVersion, content: String?)], fileSystem: FileSystem), Error>) -> Void) {
        // try cached first
        if let availableManifests = self.availableManifestsCache[version] {
            return completion(.success(availableManifests))
        }
        // get from server
        self.registryClient.getAvailableManifests(
            package: self.package.identity,
            version: version,
            observabilityScope: self.observabilityScope,
            callbackQueue: .sharedConcurrent
        ) { result in
            completion(result.tryMap { manifests in
                // ToolsVersionLoader is designed to scan files to decide which is the best tools-version
                // as such, this writes a fake manifest based on the information returned by the registry
                // with only the header line which is all that is needed by ToolsVersionLoader
                let fileSystem = InMemoryFileSystem()
                for manifest in manifests {
                    let content = manifest.value.content ?? "// swift-tools-version:\(manifest.value.toolsVersion)"
                    try fileSystem.writeFileContents(AbsolutePath.root.appending(component: manifest.key), string: content)
                }
                self.availableManifestsCache[version] = (manifests: manifests, fileSystem: fileSystem)
                return (manifests: manifests, fileSystem: fileSystem)
            })
        }
    }
}

// MARK: - CustomStringConvertible

extension RegistryPackageContainer: CustomStringConvertible {
    public var description: String {
        return "RegistryPackageContainer(\(package.identity))"
    }
}
