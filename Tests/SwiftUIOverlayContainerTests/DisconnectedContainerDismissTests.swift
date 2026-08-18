//
//  DisconnectedContainerDismissTests.swift
//  SwiftUIOverlayContainerTests
//
//  Created by Yang Xu on 2026/6/22
//  Copyright © 2026 Yang Xu. All rights reserved.
//
//  Follow me on Twitter: @fatbobman
//  My Blog: https://www.fatbobman.com
//

@testable import SwiftUIOverlayContainer
import SwiftUI
import XCTest

/// A container that is torn down while overlays are queued keeps its handler and, when the scene is
/// not active, its queue state. Until now every dismiss sent in that window was dropped, because the
/// manager reaches a container only through a publisher it has already removed. These cover the
/// dismiss arriving anyway, and still arriving exactly once when the container is connected.
@MainActor
class DisconnectedContainerDismissTests: XCTestCase {
    let manager = ContainerManager.share
    let containerName = "disconnectedContainer"
    var handler: ContainerQueueHandler!

    @MainActor override func setUp() {
        manager.publishers.removeAll()
        manager.preservedQueueStates.removeAll()
        manager.queueHandlers.removeAll()
        handler = makeHandler(queueType: .multiple)
    }

    @MainActor override func tearDown() {
        handler = nil
        manager.publishers.removeAll()
        manager.preservedQueueStates.removeAll()
        manager.queueHandlers.removeAll()
    }

    func makeHandler(queueType: ContainerViewQueueType) -> ContainerQueueHandler {
        ContainerQueueHandler(
            container: containerName,
            containerManager: manager,
            queueType: queueType,
            animation: nil,
            delayForShowingNext: 0,
            displayOrder: .ascending
        )
    }

    func makeView() -> IdentifiableContainerView {
        let view = MessageView()
        return IdentifiableContainerView(id: UUID(), view: view, viewConfiguration: view, isPresented: nil)
    }

    /// Let the main queue drain, so the manager's direct delivery hop runs.
    func drainMainQueue() {
        let drained = expectation(description: "main queue drained")
        DispatchQueue.main.async { drained.fulfill() }
        wait(for: [drained], timeout: 1)
    }

    // MARK: - Dismiss reaches a disconnected container

    func testDismissViewReachesDisconnectedHandler() throws {
        // given a connected container holding a view, torn down with its queue preserved
        handler.connect()
        let identifiableView = makeView()
        handler.mainQueue.push(identifiableView, with: nil)
        handler.disconnect(preservingQueue: true)
        XCTAssertNil(manager.publishers[containerName])
        XCTAssertEqual(handler.mainQueue.count, 1)

        // when
        manager.dismiss(view: identifiableView.id, in: containerName, animated: false)
        drainMainQueue()

        // then
        XCTAssertEqual(handler.mainQueue.count, 0)
    }

    func testDismissAllReachesDisconnectedHandler() throws {
        // given
        handler.connect()
        handler.mainQueue.push(makeView(), with: nil)
        handler.mainQueue.push(makeView(), with: nil)
        handler.disconnect(preservingQueue: true)

        // when
        manager.dismissAllView(in: [containerName], animated: false)
        drainMainQueue()

        // then
        XCTAssertEqual(handler.mainQueue.count, 0)
    }

    /// The reason the bug survived a dismiss: the preserved copy put the view back on reconnect.
    func testDismissedViewIsNotRestoredOnReconnect() throws {
        // given
        handler.connect()
        let identifiableView = makeView()
        handler.mainQueue.push(identifiableView, with: nil)
        handler.disconnect(preservingQueue: true)
        XCTAssertNotNil(manager.preservedQueueStates[containerName])

        // when the view is dismissed while disconnected, and a fresh container takes over
        manager.dismiss(view: identifiableView.id, in: containerName, animated: false)
        drainMainQueue()
        let replacement = makeHandler(queueType: .multiple)
        replacement.connect()

        // then
        XCTAssertEqual(replacement.mainQueue.count, 0)
        XCTAssertNil(manager.preservedQueueStates[containerName])
    }

    func testDismissAllDiscardsEveryPreservedView() throws {
        // given
        handler.connect()
        handler.mainQueue.push(makeView(), with: nil)
        handler.disconnect(preservingQueue: true)

        // when
        manager.dismissAllView(in: [containerName], animated: false)
        drainMainQueue()
        let replacement = makeHandler(queueType: .multiple)
        replacement.connect()

        // then
        XCTAssertEqual(replacement.mainQueue.count, 0)
    }

    /// A container torn down while the scene is active is not preserved, and must not be resurrected.
    func testDismissIsHarmlessWhenQueueWasNotPreserved() throws {
        // given
        handler.connect()
        let identifiableView = makeView()
        handler.mainQueue.push(identifiableView, with: nil)
        handler.disconnect(preservingQueue: false)
        XCTAssertEqual(handler.mainQueue.count, 0)

        // when
        manager.dismiss(view: identifiableView.id, in: containerName, animated: false)
        drainMainQueue()

        // then
        XCTAssertEqual(handler.mainQueue.count, 0)
        XCTAssertNil(manager.preservedQueueStates[containerName])
    }

    // MARK: - Connected containers are still reached exactly once

    func testConnectedContainerStillDismissesThroughPublisher() throws {
        // given
        handler.connect()
        let identifiableView = makeView()
        handler.mainQueue.push(identifiableView, with: nil)

        // when
        manager.dismiss(view: identifiableView.id, in: containerName, animated: false)
        drainMainQueue()

        // then
        XCTAssertEqual(handler.mainQueue.count, 0)
    }

    /// `dismissTopmostView` is not idempotent, so a connected handler must not be reached twice.
    func testDismissTopmostViewIsAppliedOnceWhenConnected() throws {
        // given
        handler.connect()
        handler.mainQueue.push(makeView(), with: nil)
        handler.mainQueue.push(makeView(), with: nil)

        // when
        manager.dismissTopmostView(in: [containerName], animated: false)
        drainMainQueue()
        drainMainQueue()

        // then only the topmost view is gone
        XCTAssertEqual(handler.mainQueue.count, 1)
    }

    func testDismissTopmostViewReachesDisconnectedHandler() throws {
        // given
        handler.connect()
        handler.mainQueue.push(makeView(), with: nil)
        handler.mainQueue.push(makeView(), with: nil)
        handler.disconnect(preservingQueue: true)

        // when
        manager.dismissTopmostView(in: [containerName], animated: false)
        drainMainQueue()

        // then
        XCTAssertEqual(handler.mainQueue.count, 1)
    }

    /// Dismissing one view must not throw away the rest of a preserved queue.
    func testDismissingOneViewKeepsTheOtherPreserved() throws {
        // given
        handler.connect()
        let first = makeView()
        let second = makeView()
        handler.mainQueue.push(first, with: nil)
        handler.mainQueue.push(second, with: nil)
        handler.disconnect(preservingQueue: true)

        // when
        manager.dismiss(view: first.id, in: containerName, animated: false)
        drainMainQueue()
        let replacement = makeHandler(queueType: .multiple)
        replacement.connect()

        // then
        XCTAssertEqual(replacement.mainQueue.count, 1)
        XCTAssertEqual(replacement.mainQueue.first?.id, second.id)
    }

    // MARK: - Showing is unaffected

    func testShowStillRequiresARegisteredContainer() throws {
        // given a container that has been torn down
        handler.connect()
        handler.disconnect(preservingQueue: true)

        // when
        let id = manager.show(view: MessageView(), in: containerName, using: MessageView())
        drainMainQueue()

        // then showing is unchanged: it still needs a live publisher
        XCTAssertNil(id)
        XCTAssertEqual(handler.mainQueue.count, 0)
    }

    func testShowAndDismissRoundTripOnAReconnectedContainer() throws {
        // given
        handler.connect()

        // when
        let id = try XCTUnwrap(manager.show(view: MessageView(), in: containerName, using: MessageView()))
        drainMainQueue()
        XCTAssertEqual(handler.mainQueue.count, 1)

        manager.dismiss(view: id, in: containerName, animated: false)
        drainMainQueue()

        // then
        XCTAssertEqual(handler.mainQueue.count, 0)
    }

    // MARK: - Ordering against a show issued right after a dismiss

    /// A dismiss must never outlive the call that issued it and destroy a later view.
    func testDismissAllNotIncludeDoesNotSwallowALaterShow() throws {
        // given
        handler.connect()

        // when a dismiss-all is followed by a show in the same turn
        manager.dismissAllView(notInclude: [], animated: false)
        let id = manager.show(view: MessageView(), in: containerName, using: MessageView())
        XCTAssertNotNil(id)
        drainMainQueue()
        drainMainQueue()
        drainMainQueue()

        // then
        XCTAssertEqual(handler.mainQueue.count, 1, "a view shown after the dismiss must survive it")
    }

    func testConnectedContainerKeepsAViewShownRightAfterDismissAll() throws {
        // given
        handler.connect()

        // when
        manager.dismissAllView(in: [containerName], animated: false)
        let id = manager.show(view: MessageView(), in: containerName, using: MessageView())
        XCTAssertNotNil(id)
        drainMainQueue()
        drainMainQueue()

        // then
        XCTAssertEqual(handler.mainQueue.count, 1)
    }

    /// The topmost view is removed from the live handler, so it must leave the preserved copy too.
    func testTopmostDismissedWhileDisconnectedIsNotRestored() throws {
        // given
        handler.connect()
        handler.mainQueue.push(makeView(), with: nil)
        handler.mainQueue.push(makeView(), with: nil)
        handler.disconnect(preservingQueue: true)

        // when
        manager.dismissTopmostView(in: [containerName], animated: false)
        drainMainQueue()
        XCTAssertEqual(handler.mainQueue.count, 1)

        // then the scene becoming active again must not bring it back
        handler.connect()
        XCTAssertEqual(handler.mainQueue.count, 1, "the dismissed view must not come back")
    }

    /// The only coverage of a queue type where emptying the main queue has a side effect.
    func testDismissAllReachesADisconnectedOneByOneWaitFinishHandlerWithATempQueue() throws {
        // given
        let waitFinish = makeHandler(queueType: .oneByOneWaitFinish)
        waitFinish.connect()
        waitFinish.mainQueue.push(makeView(), with: nil)
        waitFinish.tempQueue.append(makeView())
        waitFinish.disconnect(preservingQueue: true)

        // when
        manager.dismissAllView(in: [containerName], animated: false)
        drainMainQueue()
        drainMainQueue()

        // then
        XCTAssertEqual(waitFinish.mainQueue.count, 0)
        XCTAssertEqual(waitFinish.tempQueue.count, 0, "dismissAll must empty the temp queue too")
        XCTAssertNil(manager.preservedQueueStates[containerName])
    }

    /// A handler that has gone must not keep the manager from serving its replacement.
    func testDeallocatedHandlerIsPrunedFromTheRegistry() throws {
        // given
        autoreleasepool {
            let temporary = makeHandler(queueType: .multiple)
            temporary.connect()
            temporary.disconnect(preservingQueue: false)
        }

        // when
        manager.dismissAllView(in: [containerName], animated: false)
        drainMainQueue()

        // then
        XCTAssertNil(manager.queueHandlers[containerName])
    }
}
