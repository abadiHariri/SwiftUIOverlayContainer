//
//  ContainerManager.swift
//  SwiftUIOverlayContainer
//
//  Created by Yang Xu on 2022/3/9
//  Copyright © 2022 Yang Xu. All rights reserved.
//
//  Follow me on Twitter: @fatbobman
//  My Blog: https://www.fatbobman.com
//

import Combine
import Foundation
import SwiftUI

struct PreservedContainerQueueState {
    let mainQueue: [IdentifiableContainerView]
    let tempQueue: [IdentifiableContainerView]

    var isEmpty: Bool {
        mainQueue.isEmpty && tempQueue.isEmpty
    }

    /// Drop a single view from both queues, for a view dismissed while its container is disconnected.
    func removingView(id: UUID) -> PreservedContainerQueueState {
        PreservedContainerQueueState(
            mainQueue: mainQueue.filter { $0.id != id },
            tempQueue: tempQueue.filter { $0.id != id }
        )
    }

    /// Drop the displayed queue only, for a `dismissShowing` received while disconnected.
    var removingMainQueue: PreservedContainerQueueState {
        PreservedContainerQueueState(mainQueue: [], tempQueue: tempQueue)
    }
}

/// A weak handle on a container's queue handler.
///
/// `publishers` is torn down every time a container disappears, but the handler owns the queues and
/// stays alive for as long as its container view does. Holding a weak handle lets a dismiss reach a
/// container that is not currently registered, instead of being dropped on the floor and leaving a
/// view on screen that nothing can take off.
struct WeakQueueHandler {
    weak var handler: ContainerQueueHandler?
}

/// The manager of all overlay containers that provides a bridge between containers and SwiftUI views.
///
/// In the SwiftUI view, it is better to call the Container Manager by accessing the environment value
///
///     struct ContentView: View {
///         @Environment(\.overlayContainerManager) var manager
///         var body: some View {
///             VStack{
///                 Button("push view by manager"){
///                     manager.show(view: Text("ab"), in: "container2", using: MessageView())
///                 }
///             }
///         }
///     }
///
/// Because the Container Manager adopts the singleton pattern, you can directly call public methods such as show and dismiss through code even if you are not in the SwiftUI view.
public final class ContainerManager: ContainerManagerLogger {
    var publishers: [String: ContainerViewPublisher] = [:]
    var preservedQueueStates: [String: PreservedContainerQueueState] = [:]
    var queueHandlers: [String: [WeakQueueHandler]] = [:]

    public init(logger: SwiftUIOverlayContainerLoggerProtocol? = nil, debugLevel: Int = 0) {
        if logger == nil {
            self.logger = SwiftUIOverlayContainerDefaultLogger()
        }
        self.debugLevel = debugLevel
    }

    public var logger: SwiftUIOverlayContainerLoggerProtocol?
    /// Debug Level for log output. 0 disable 1 basic 2 more detail
    public var debugLevel: Int

    /// Controlled method of writing to the log
    func sendMessage(type: SwiftUIOverlayContainerLogType, message: String, debugLevel: Int = 1) {
        if debugLevel <= self.debugLevel {
            self.logger?.log(type: type, message: message)
        }
    }

    /// Keep queued overlays across inactive-scene teardown so a recreated container can resume them.
    func preserveQueueState(_ state: PreservedContainerQueueState, for container: String) {
        if state.isEmpty {
            preservedQueueStates.removeValue(forKey: container)
        } else {
            preservedQueueStates[container] = state
        }
    }

    func restoreQueueState(for container: String) -> PreservedContainerQueueState? {
        preservedQueueStates.removeValue(forKey: container)
    }

    func removePreservedQueueState(for container: String) {
        preservedQueueStates.removeValue(forKey: container)
    }

    /// Keep a weak handle on a container's queue handler. Called by the container when it connects.
    func registerQueueHandler(_ handler: ContainerQueueHandler, for container: String) {
        var handles = queueHandlers[container, default: []].filter { $0.handler != nil }
        if !handles.contains(where: { $0.handler === handler }) {
            handles.append(WeakQueueHandler(handler: handler))
        }
        queueHandlers[container] = handles
    }

    /// The still-allocated handlers of a container, pruning the handles that have gone.
    func liveQueueHandlers(for container: String) -> [ContainerQueueHandler] {
        guard let handles = queueHandlers[container] else { return [] }
        let alive = handles.filter { $0.handler != nil }
        if alive.isEmpty {
            queueHandlers.removeValue(forKey: container)
        } else if alive.count != handles.count {
            queueHandlers[container] = alive
        }
        return alive.compactMap { $0.handler }
    }

    /// Every container name the manager knows anything about, including the ones that are torn down
    /// but still hold a preserved queue or a live handler.
    ///
    /// Read on the caller's thread, like `publishers` itself, so that a dismiss decides which
    /// containers it covers at the moment it is issued.
    var knownContainers: Set<String> {
        Set(publishers.keys).union(queueHandlers.keys).union(preservedQueueStates.keys)
    }

    /// What a dismiss request covers, so the same request can be applied to a preserved queue and
    /// to a handler the publisher could not reach.
    enum DismissScope {
        case view(UUID)
        case all
        case showing
        case topmost
    }

    /// Complete a dismiss for the parts of a container the publisher send cannot reach: the queue
    /// state preserved for a container that is currently torn down, and every live handler that is
    /// not subscribed to the publisher the send went to.
    ///
    /// The current publisher's identity is sampled now rather than when the hop runs. A container
    /// that reconnects in between would otherwise look reached and be skipped, even though nothing
    /// was ever sent to it. Handlers are matched by the identity of the publisher they subscribed
    /// to, NOT by whether they hold a subscription: a same-name container registering replaces the
    /// publisher (`checkForExist`) and leaves the previous handler subscribed to a dead share —
    /// still holding and rendering its queue, unreachable by any send, yet looking "connected".
    /// Matching on identity delivers to that orphan and still skips the handler the send did
    /// reach, so every handler is reached exactly once, which is what a non-idempotent action such
    /// as `dismissTopmostView` requires.
    ///
    /// Everything touching `queueHandlers` and `preservedQueueStates` runs inside the hop, so both
    /// are only ever mutated on the main queue, matching `connect` and `disconnect`.
    func completeDismiss(_ scope: DismissScope, in container: String, animated flag: Bool) {
        completeDismiss(scope, in: container, animated: flag, sentTo: publishers[container])
    }

    /// `sentPublisher` is captured strongly so the identity comparison inside the hop is always
    /// between live objects — a deallocated share's address can be reused by its replacement.
    func completeDismiss(_ scope: DismissScope, in container: String, animated flag: Bool, sentTo sentPublisher: ContainerViewPublisher?) {
        DispatchQueue.main.async { @MainActor [weak self] in
            guard let self = self else { return }

            // `.topmost` names a view only once a handler is in hand, so it is discarded per view
            // below instead of here.
            if case .topmost = scope {} else {
                self.discardPreserved(scope, for: container)
            }

            let unreached = self.liveQueueHandlers(for: container).filter { handler in
                guard let sentPublisher = sentPublisher else { return true }
                return handler.subscribedPublisher !== sentPublisher
            }
            guard !unreached.isEmpty else { return }

            self.sendMessage(
                type: .info,
                message: "dismiss delivered directly to \(unreached.count) unreached handler(s) of `\(container)`",
                debugLevel: 2
            )

            for handler in unreached {
                switch scope {
                case let .view(id):
                    handler.dismiss(id: id, animated: flag)
                case .all:
                    handler.dismissAll(animated: flag)
                case .showing:
                    handler.dismissMainQueue(animated: flag)
                case .topmost:
                    // Resolving the id here keeps the removal and the discard in agreement, so a
                    // reconnecting container cannot restore the view that was just dismissed.
                    guard let id = handler.topmostViewID else { continue }
                    handler.dismiss(id: id, animated: flag)
                    self.discardPreserved(.view(id), for: container)
                }
            }
        }
    }

    /// Drop the preserved views a dismiss covers, so a reconnecting container cannot resume them.
    private func discardPreserved(_ scope: DismissScope, for container: String) {
        guard let state = preservedQueueStates[container] else { return }
        switch scope {
        case let .view(id):
            preserveQueueState(state.removingView(id: id), for: container)
        case .all:
            preservedQueueStates.removeValue(forKey: container)
        case .showing:
            preserveQueueState(state.removingMainQueue, for: container)
        case .topmost:
            break
        }
    }
}

// MARK: - Container Management

extension ContainerManager: ContainerManagement {
    /// Register a container in the container manager
    ///
    /// Overlay containers will register themselves when they appear ( onAppear ), called by container
    func registerContainer(for container: String) -> ContainerViewPublisher {
        checkForExist(container: container)
        return createPublisher(for: container)
    }

    /// Remove a container from the container manager, called by container
    ///
    /// Overlay containers will remove themselves from manager when the disappear ( onDisappear ).
    func removeContainer(for container: String) {
        publishers.removeValue(forKey: container)
        sendMessage(type: .info, message: "`\(container)` has been removed from manager", debugLevel: 2)
    }

    /// Get  publisher of container action  for specific container from manager, called by container
    func getPublisher(for container: String) -> ContainerViewPublisher? {
        guard let publisher = publishers[container] else {
            sendMessage(
                type: .error,
                message: "Can't get view publisher for `\(container)`,The overlay container should be registered first."
            )
            return nil
        }
        return publisher
    }

    /// The count of registered containers
    var containerCount: Int {
        publishers.count
    }

    /// Check if the container has registered
    private func checkForExist(container: String) {
        guard publishers[container] != nil else { return }
        removeContainer(for: container)
        sendMessage(type: .error, message: "Container `\(container)` already exists. The new container will replace the old one.")
    }

    /// Create a publisher of action for specific container.
    private func createPublisher(for container: String) -> ContainerViewPublisher {
        // Convert to reference type to support dumping
        let publisher = PassthroughSubject<OverlayContainerAction, Never>().share()
        publishers[container] = publisher
        return publisher
    }
}

// MARK: - Container View Management

extension ContainerManager: ContainerViewManagementForViewModifier {
    /// Show a view in specific container.
    /// - Returns: the ID of view. you can use this ID to dismiss the view by code
    @discardableResult
    func _show<Content>(
        view: Content,
        with ID: UUID? = nil,
        in container: String,
        using configuration: ContainerViewConfigurationProtocol,
        isPresented: Binding<Bool>? = nil,
        animated: Bool = true
    ) -> UUID? where Content: View {
        guard let publisher = getPublisher(for: container) else {
            return nil
        }
        let viewID = ID ?? UUID() // If no specific ID is given, generate a new ID
        let identifiableContainerView = IdentifiableContainerView(
            id: viewID,
            view: view,
            viewConfiguration: configuration,
            isPresented: isPresented
        )
        publisher.upstream.send(.show(identifiableContainerView, animated))
        sendMessage(type: .info, message: "send view `\(type(of: view))` to container: `\(container)`", debugLevel: 2)
        return viewID
    }

    @discardableResult
    func _show<Content>(
        containerView: Content,
        in container: String,
        isPresented: Binding<Bool>? = nil
    ) -> UUID? where Content: ContainerView {
        _show(view: containerView, in: container, using: containerView, isPresented: isPresented)
    }
}

extension ContainerManager: ContainerViewManagementForEnvironment {
    /// Push ContainerView to specific overlay container
    ///
    /// Interface for environment key
    /// - Returns: container view ID
    @discardableResult
    public func show<Content>(
        view: Content,
        with ID: UUID? = nil,
        in container: String,
        using configuration: ContainerViewConfigurationProtocol,
        animated: Bool = true
    ) -> UUID? where Content: View {
        _show(view: view, with: ID, in: container, using: configuration, isPresented: nil, animated: animated)
    }

    /// Push ContainerView to specific overlay container
    ///
    /// Interface for environment key
    /// - Returns: container view ID
    @discardableResult
    public func show<Content>(
        containerView: Content,
        with ID: UUID? = nil,
        in container: String,
        animated: Bool = true
    ) -> UUID? where Content: ContainerView {
        _show(view: containerView, with: ID, in: container, using: containerView, isPresented: nil, animated: animated)
    }

    /// Dismiss a specific view in a specific container
    /// - Parameters:
    ///   - id: ID of the view ( IdentifiableView , the result of show method)
    ///   - container: The container to which the view has been pushed
    ///   - flag: Pass false, no animation when dismiss the view
    public func dismiss(view id: UUID, in container: String, animated flag: Bool) {
        if let publisher = publishers[container] {
            publisher.upstream.send(.dismiss(id, flag))
        }
        completeDismiss(.view(id), in: container, animated: flag)
    }

    /// Dismiss all views of all containers that has registered exclude  containers in the excludeContainers list.
    /// - Parameters:
    ///   - excludeContainers: Containers in excludeContainers list will not get dismiss action.
    ///   - onlyShowing: Only dismiss the view that is be displaying (in mainQueue). Applies only to oneByOneWaitFinish mode. after dismiss, the view in the tempQueue will be displayed.
    ///   - flag: Pass false, no animation when dismiss the view
    public func dismissAllView(notInclude excludeContainers: [String], onlyShowing: Bool = false, animated flag: Bool) {
        let scope: DismissScope = onlyShowing ? .showing : .all

        // Registered containers are still reached synchronously, exactly as before. Deferring the
        // send would let a `show` issued right after this call be delivered ahead of the dismiss
        // that precedes it, and destroy the view that was just presented.
        let registered = publishers.filter { !excludeContainers.contains($0.key) }
        for (container, publisher) in registered {
            publisher.upstream.send(onlyShowing ? .dismissShowing(flag) : .dismissAll(flag))
            completeDismiss(scope, in: container, animated: flag, sentTo: publisher)
        }

        // The containers that are torn down are sampled now rather than when the hop runs, so a
        // container that appears after this call is not dismissed by a request that predates it.
        // Nothing was sent to them, so `sentTo: nil` holds even if one reconnects first.
        let torndown = knownContainers
            .subtracting(excludeContainers)
            .subtracting(registered.keys)
        for container in torndown {
            completeDismiss(scope, in: container, animated: flag, sentTo: nil)
        }
    }

    /// Dismiss all view of the containers in containers list.
    /// - Parameters:
    ///   - containers: Dismissed only the views of the containers in the list.
    ///   - onlyShowing: Only dismiss the view that is be displaying (in mainQueue). Applies only to oneByOneWaitFinish mode. after dismiss, the view in the tempQueue will be displayed.
    ///   - flag: Pass false, no animation when dismiss the view
    public func dismissAllView(in containers: [String], onlyShowing: Bool = false, animated flag: Bool) {
        for container in containers {
            if let publisher = publishers[container] {
                if onlyShowing {
                    publisher.upstream.send(.dismissShowing(flag))
                } else {
                    publisher.upstream.send(.dismissAll(flag))
                }
            }
            completeDismiss(onlyShowing ? .showing : .all, in: container, animated: flag)
        }
    }

    /// Dismiss the top view in the containers
    /// - Parameters:
    ///   - containers: container names
    ///   - flag: Pass false, disable animation when dismiss the view
    public func dismissTopmostView(in containers: [String], animated flag: Bool) {
        for container in containers {
            if let publisher = publishers[container] {
                publisher.upstream.send(.dismissTopmostView(flag))
            }
            completeDismiss(.topmost, in: container, animated: flag)
        }
    }
}

public extension ContainerManager {
    static let share = ContainerManager()
}
