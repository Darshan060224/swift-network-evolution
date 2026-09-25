//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift open source project
//
// Copyright (c) 2026 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.txt for the list of Swift project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

#if !NETWORK_NO_SWIFT_QUIC

import XCTest

#if canImport(SwiftNetwork)
@_spi(Essentials) @_spi(ProtocolProvider) @testable import SwiftNetwork
#elseif canImport(Network)
@_spi(Essentials) @_spi(ProtocolProvider) @testable import Network
#endif

#if canImport(SwiftNetworkTestHarness)
@_spi(TestHarness) @_spi(Essentials) @_spi(ProtocolProvider) import SwiftNetworkTestHarness
#endif

@available(Network 0.1.0, *)
let connectionIDRotationTestsLogPrefixer: LogPrefixer = LogPrefixer("[ConnectionIDRotationTests]")

@available(Network 0.1.0, *)
final class ConnectionIDRotationTests: XCTestCase {
    var connection = QUICConnection(context: .implicitContext)
    // The base linkages are storage-backed, so lower harnesses have to come from storage
    // rather than being wrapped in a bare linkage.
    let storage = TestNetworkProtocolStorage(context: .implicitContext)

    override func setUp() {
        let expectation = XCTestExpectation()
        connection.context.async {
            try? self.connection.setup(remote: nil, local: nil, parameters: nil, path: nil)
            self.connection.recovery = Recovery(logPrefixer: connectionIDRotationTestsLogPrefixer)
            self.connection.recovery.connection = self.connection
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 5.0)
    }

    override func tearDown() {
        self.connection.currentPath = nil
        // The paths built by `makePath` outlive the test body, so release them.
        self.connection.context.onQueue {
            for path in self.connection.multiplexingPaths.values {
                path.destroyFromExternalTest()
            }
        }
        self.connection.multiplexingPaths.removeAll()
    }

    // Builds a path that is open for sending, backed by a lower harness, with its DCID
    // registered in `remoteCIDs` so it mirrors an active path using that CID. The path is
    // registered in `multiplexingPaths` so `tearDown` releases it.
    private func makePath(dcid: QUICConnectionID, sequenceNumber: UInt64, used: Bool) -> QUICPath {
        let (lower, lowerLinkage) = storage.createDatagramLowerHarness(
            identifier: "\(sequenceNumber)",
            context: .implicitContext
        )
        lower.fromExternal { eventContext in
            lower.connect(in: &eventContext)
        }
        // Every caller builds its paths from inside `context.async`, so this runs on the context.
        var path = QUICPath.makeFromExternalTest(parent: self.connection)
        path.set(interface: nil, priority: 1, isInitial: true)  // -> .routeEstablished
        path.assignDCID(dcid)  // -> .cidAssigned (open for sending)
        // The path is a framework protocol, so it is bound through the base form of the
        // harness's linkage.
        _ = try? path.attachLowerProtocol(lowerLinkage.base)
        try? lowerLinkage.base.invokeAttachUpperProtocol(
            path.asUpperLinkage(),
            remote: nil,
            local: nil,
            parameters: nil,
            path: nil
        )
        try? connection.remoteCIDs.insert(
            sequenceNumber: sequenceNumber,
            connectionID: dcid,
            token: QUICStatelessResetToken(),
            used: used
        )
        connection.multiplexingPaths[path.pathIdentifier] = path
        return path
    }

    // The peer issues seq 1-3, but loss drops those NEW_CONNECTION_ID frames, so remoteCIDs holds
    // only the in-use seq 0 when the rotation frame (seq=4, retirePriorTo=1) arrives. Retiring
    // seq 0 leaves only the CID carried by that frame, so the path has to move to it instead of
    // the connection closing for lack of a DCID.
    func testStarvedPoolRotationUsesReplacementFromSameFrame() {
        let expectation = XCTestExpectation()
        connection.context.async {
            let oldCID = QUICConnectionID([0xA1, 0xA2, 0xA3, 0xA4])!
            let newCID = QUICConnectionID([0xB1, 0xB2, 0xB3, 0xB4])!

            let path = self.makePath(dcid: oldCID, sequenceNumber: 0, used: true)
            self.connection.currentPath = path

            XCTAssertEqual(
                self.connection.remoteCIDs.count,
                1,
                "Pool should start starved down to just the in-use CID"
            )

            let frame = FrameNewConnectionID(
                sequence: 4,
                retirePriorToSequence: 1,
                connectionID: newCID,
                statelessResetToken: QUICStatelessResetToken()
            )
            self.connection.fromExternal { eventContext in
                _ = self.connection.processNewConnectionIDFrame(frame, in: &eventContext)
            }

            XCTAssertNil(
                self.connection.closeError,
                "Connection fatally closed instead of using the CID its own frame supplied"
            )
            XCTAssertEqual(
                self.connection.currentPath?.dcid,
                newCID,
                "Path should be re-pointed to the new CID"
            )
            XCTAssertEqual(
                self.connection.remoteCIDs.count,
                1,
                "Pool should hold exactly the new CID after rotation"
            )

            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 5.0)
    }
}

#endif
