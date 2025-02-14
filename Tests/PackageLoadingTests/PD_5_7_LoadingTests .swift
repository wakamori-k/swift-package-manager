/*
 This source file is part of the Swift.org open source project

 Copyright (c) 2021 - 2022 Apple Inc. and the Swift project authors
 Licensed under Apache License v2.0 with Runtime Library Exception

 See http://swift.org/LICENSE.txt for license information
 See http://swift.org/CONTRIBUTORS.txt for Swift project authors
*/

import Basics
import PackageModel
import SPMTestSupport
import XCTest

class PackageDescription5_7LoadingTests: PackageDescriptionLoadingTests {
    override var toolsVersion: ToolsVersion {
        .v5_7
    }
}
