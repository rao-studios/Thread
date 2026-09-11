import Foundation

// MARK: - Debug Configuration

/// Global configuration for publisher debugging
public struct PublisherDebugConfig {
    /// Enable/disable all debug logging
    public nonisolated(unsafe) static var isEnabled = false

    /// Enable/disable specific component logging
    public nonisolated(unsafe) static var logAnyPublisher = true
    public nonisolated(unsafe) static var logAnySubscriber = true
    public nonisolated(unsafe) static var logSinkSubscriber = true
    public nonisolated(unsafe) static var logFlatMapSubscriber = true
    public nonisolated(unsafe) static var logJustPublisher = true
    public nonisolated(unsafe) static var logFuturePublisher = true
    public nonisolated(unsafe) static var logReceiveOnSubscriber = true
    public nonisolated(unsafe) static var logTryCatchSubscriber = true
    public nonisolated(unsafe) static var logSetFailureTypeSubscriber = true

    /// Log only values (reduces noise)
    public nonisolated(unsafe) static var logValues = true
    
    /// Helper to check if a specific log should print
    static func shouldLog(_ component: String) -> Bool {
        guard isEnabled else { return false }
        switch component {
        case "AnyPublisher": return logAnyPublisher
        case "AnySubscriber": return logAnySubscriber
        case "SinkSubscriber": return logSinkSubscriber
        case "FlatMapSubscriber": return logFlatMapSubscriber
        case "Just": return logJustPublisher
        case "Future": return logFuturePublisher
        case "ReceiveOn": return logReceiveOnSubscriber
        case "TryCatch": return logTryCatchSubscriber
        case "SetFailureType": return logSetFailureTypeSubscriber
        default: return true
        }
    }
}

private func debugLog(_ component: String, _ id: String, _ message: String) {
    guard PublisherDebugConfig.shouldLog(component) else { return }
    print("[\(component)-\(id)] \(message)")
}

// MARK: - Subscription Protocol

/// Protocol representing a subscription to a publisher
public protocol Subscription: AnyObject {
    func cancel()
}

// MARK: - Cancellable

/// Type-erased cancellable wrapper
public final class AnyCancellable: Subscription, @unchecked Sendable {
    private var cancellationHandler: (() -> Void)?
    
    public init(_ cancel: @escaping () -> Void) {
        self.cancellationHandler = cancel
    }
    
    public func cancel() {
        cancellationHandler?()
        cancellationHandler = nil
    }
    
    deinit {
        cancel()
    }
}

// MARK: - Subscriber Protocol

/// Protocol for types that can receive values from a publisher
public protocol Subscriber: AnyObject {
    associatedtype Input
    associatedtype Failure: Error
    
    func receive(subscription: Subscription)
    func receive(_ input: Input) -> Subscribers.Demand
    func receive(completion: Subscribers.Completion<Failure>)
}

// MARK: - Subscribers Namespace

public enum Subscribers {
    /// Demand for values
    public struct Demand: Equatable, Sendable {
        private let value: Int?
        
        private init(_ value: Int?) {
            self.value = value
        }
        
        public static let unlimited = Demand(nil)
        public static let none = Demand(0)
        
        public static func max(_ value: Int) -> Demand {
            return Demand(value)
        }
        
        // Helper to check if demand allows sending values
        public var isPositive: Bool {
            if let value = value {
                return value > 0
            }
            return true // unlimited is always positive
        }
    }
    
    /// Completion state
    public enum Completion<Failure: Error> {
        case finished
        case failure(Failure)
    }
}

// MARK: - Publisher Protocol

/// Protocol for types that can publish values over time
public protocol Publisher<Output, Failure> {
    associatedtype Output
    associatedtype Failure: Error
    
    func receive<S>(subscriber: S) where S: Subscriber, S.Input == Output, S.Failure == Failure
}

// MARK: - AnyPublisher

/// Type-erased publisher
public struct AnyPublisher<Output, Failure: Error>: Publisher {
    private let subscribeHandler: (AnySubscriber<Output, Failure>) -> Void
    private let debugID: String
    
    public init<P: Publisher>(_ publisher: P) where P.Output == Output, P.Failure == Failure {
        let id = String(UUID().uuidString.prefix(8))
        self.debugID = id
        self.subscribeHandler = { subscriber in
            debugLog("AnyPublisher", id, "Forwarding subscriber to wrapped publisher")
            publisher.receive(subscriber: subscriber)
        }
    }
    
    public init(_ subscribe: @escaping (AnySubscriber<Output, Failure>) -> Void) {
        self.debugID = String(UUID().uuidString.prefix(8))
        self.subscribeHandler = subscribe
    }
    
    public func receive<S>(subscriber: S) where S: Subscriber, S.Input == Output, S.Failure == Failure {
        debugLog("AnyPublisher", debugID, "Received subscriber: \(type(of: subscriber))")
        let anySubscriber = AnySubscriber(subscriber)
        subscribeHandler(anySubscriber)
    }
}

// MARK: - AnySubscriber

/// Type-erased subscriber
public final class AnySubscriber<Input, Failure: Error>: Subscriber {
    private let receiveSubscriptionHandler: (Subscription) -> Void
    private let receiveValueHandler: (Input) -> Subscribers.Demand
    private let receiveCompletionHandler: (Subscribers.Completion<Failure>) -> Void
    private let debugID = UUID().uuidString.prefix(8)
    
    public init<S: Subscriber>(_ subscriber: S) where S.Input == Input, S.Failure == Failure {
        debugLog("AnySubscriber", String(debugID), "Created for subscriber type: \(type(of: subscriber))")
        receiveSubscriptionHandler = subscriber.receive(subscription:)
        receiveValueHandler = subscriber.receive(_:)
        receiveCompletionHandler = subscriber.receive(completion:)
    }
    
    public func receive(subscription: Subscription) {
        debugLog("AnySubscriber", String(debugID), "Received subscription: \(type(of: subscription))")
        receiveSubscriptionHandler(subscription)
    }
    
    public func receive(_ input: Input) -> Subscribers.Demand {
        if PublisherDebugConfig.shouldLog("AnySubscriber") && PublisherDebugConfig.logValues {
            debugLog("AnySubscriber", String(debugID), "Received value: \(input)")
        }
        let demand = receiveValueHandler(input)
        if PublisherDebugConfig.shouldLog("AnySubscriber") {
            debugLog("AnySubscriber", String(debugID), "Returned demand: \(demand)")
        }
        return demand
    }
    
    public func receive(completion: Subscribers.Completion<Failure>) {
        if PublisherDebugConfig.shouldLog("AnySubscriber") {
            switch completion {
            case .finished:
                debugLog("AnySubscriber", String(debugID), "Received completion: .finished")
            case .failure(let error):
                debugLog("AnySubscriber", String(debugID), "Received completion: .failure(\(error))")
            }
        }
        receiveCompletionHandler(completion)
    }
}

// MARK: - Sink Subscriber

extension Publisher {
    /// Subscribes to the publisher with value and completion handlers
    public func sink(
        receiveCompletion: @escaping (Subscribers.Completion<Failure>) -> Void,
        receiveValue: @escaping (Output) -> Void
    ) -> AnyCancellable {
        let subscriber = SinkSubscriber(
            receiveCompletion: receiveCompletion,
            receiveValue: receiveValue
        )
        receive(subscriber: subscriber)
        return AnyCancellable {
            subscriber.cancel()
        }
    }
}

private final class SinkSubscriber<Input, Failure: Error>: Subscriber {
    private let receiveCompletionHandler: (Subscribers.Completion<Failure>) -> Void
    private let receiveValueHandler: (Input) -> Void
    private var subscription: Subscription?
    private let debugID = UUID().uuidString.prefix(8)
    
    init(
        receiveCompletion: @escaping (Subscribers.Completion<Failure>) -> Void,
        receiveValue: @escaping (Input) -> Void
    ) {
        debugLog("SinkSubscriber", String(debugID), "Created")
        self.receiveCompletionHandler = receiveCompletion
        self.receiveValueHandler = receiveValue
    }
    
    func receive(subscription: Subscription) {
        debugLog("SinkSubscriber", String(debugID), "Received subscription: \(type(of: subscription))")
        self.subscription = subscription
    }
    
    func receive(_ input: Input) -> Subscribers.Demand {
        debugLog("SinkSubscriber", String(debugID), "Received value: \(input)")
        receiveValueHandler(input)
        return .unlimited
    }
    
    func receive(completion: Subscribers.Completion<Failure>) {
        if PublisherDebugConfig.shouldLog("SinkSubscriber") {
            switch completion {
            case .finished:
                debugLog("SinkSubscriber", String(debugID), "Received completion: .finished")
            case .failure(let error):
                debugLog("SinkSubscriber", String(debugID), "Received completion: .failure(\(error))")
            }
        }
        receiveCompletionHandler(completion)
    }
    
    func cancel() {
        debugLog("SinkSubscriber", String(debugID), "Cancelled")
        subscription?.cancel()
        subscription = nil
    }
}

// MARK: - PassthroughSubject

/// A subject that broadcasts values to subscribers
public final class PassthroughSubject<Output, Failure: Error>: Publisher {
    private var subscribers: [AnySubscriber<Output, Failure>] = []
    private let lock = NSLock()
    private var isCompleted = false
    
    public init() {}
    
    public func receive<S>(subscriber: S) where S: Subscriber, S.Input == Output, S.Failure == Failure {
        lock.lock()
        defer { lock.unlock() }
        
        let anySubscriber = AnySubscriber(subscriber)
        subscribers.append(anySubscriber)
        
        let subscription = PassthroughSubscription { [weak self] in
            self?.removeSubscriber(anySubscriber)
        }
        
        anySubscriber.receive(subscription: subscription)
    }
    
    public func send(_ value: Output) {
        lock.lock()
        guard !isCompleted else {
            lock.unlock()
            return
        }
        let currentSubscribers = subscribers
        lock.unlock()
        
        for subscriber in currentSubscribers {
            _ = subscriber.receive(value)
        }
    }
    
    public func send(completion: Subscribers.Completion<Failure>) {
        lock.lock()
        let currentSubscribers = subscribers
        isCompleted = true
        subscribers.removeAll()
        lock.unlock()
        
        for subscriber in currentSubscribers {
            subscriber.receive(completion: completion)
        }
    }
    
    private func removeSubscriber(_ subscriber: AnySubscriber<Output, Failure>) {
        lock.lock()
        defer { lock.unlock() }
        subscribers.removeAll { $0 === subscriber }
    }
}

private final class PassthroughSubscription: Subscription {
    private var cancellationHandler: (() -> Void)?
    
    init(onCancel: @escaping () -> Void) {
        self.cancellationHandler = onCancel
    }
    
    func cancel() {
        cancellationHandler?()
        cancellationHandler = nil
    }
}

// MARK: - CurrentValueSubject

/// A subject that wraps a single value and publishes a new element whenever the value changes
public final class CurrentValueSubject<Output, Failure: Error>: Publisher {
    private var _value: Output
    private var subscribers: [AnySubscriber<Output, Failure>] = []
    private let lock = NSLock()
    private var isCompleted = false
    
    public var value: Output {
        get {
            lock.lock()
            defer { lock.unlock() }
            return _value
        }
        set {
            send(newValue)
        }
    }
    
    public init(_ value: Output) {
        self._value = value
    }
    
    public func receive<S>(subscriber: S) where S: Subscriber, S.Input == Output, S.Failure == Failure {
        lock.lock()
        defer { lock.unlock() }
        
        let anySubscriber = AnySubscriber(subscriber)
        subscribers.append(anySubscriber)
        
        let subscription = PassthroughSubscription { [weak self] in
            self?.removeSubscriber(anySubscriber)
        }
        
        anySubscriber.receive(subscription: subscription)
        _ = anySubscriber.receive(_value)
    }
    
    public func send(_ value: Output) {
        lock.lock()
        guard !isCompleted else {
            lock.unlock()
            return
        }
        _value = value
        let currentSubscribers = subscribers
        lock.unlock()
        
        for subscriber in currentSubscribers {
            _ = subscriber.receive(value)
        }
    }
    
    public func send(completion: Subscribers.Completion<Failure>) {
        lock.lock()
        let currentSubscribers = subscribers
        isCompleted = true
        subscribers.removeAll()
        lock.unlock()
        
        for subscriber in currentSubscribers {
            subscriber.receive(completion: completion)
        }
    }
    
    private func removeSubscriber(_ subscriber: AnySubscriber<Output, Failure>) {
        lock.lock()
        defer { lock.unlock() }
        subscribers.removeAll { $0 === subscriber }
    }
}

// MARK: - Operators

extension Publisher {
    /// Transforms all elements from the upstream publisher with a provided closure
    public func map<T>(_ transform: @escaping (Output) -> T) -> AnyPublisher<T, Failure> {
        return AnyPublisher { subscriber in
            let mapSubscriber = MapSubscriber(
                downstream: subscriber,
                transform: transform
            )
            self.receive(subscriber: mapSubscriber)
        }
    }
    
    /// Publishes only elements that match a predicate
    public func filter(_ isIncluded: @escaping (Output) -> Bool) -> AnyPublisher<Output, Failure> {
        return AnyPublisher { subscriber in
            let filterSubscriber = FilterSubscriber(
                downstream: subscriber,
                isIncluded: isIncluded
            )
            self.receive(subscriber: filterSubscriber)
        }
    }
    
    /// Transforms the publisher into type-erased AnyPublisher
    public func eraseToAnyPublisher() -> AnyPublisher<Output, Failure> {
        return AnyPublisher(self)
    }
    
    /// Changes the failure type of the publisher
    public func setFailureType<E: Error>(to failureType: E.Type) -> AnyPublisher<Output, E> {
        return AnyPublisher { subscriber in
            let setFailureSubscriber = SetFailureTypeSubscriber<Output, Failure, E>(downstream: subscriber)
            self.receive(subscriber: setFailureSubscriber)
        }
    }
    
    /// Transforms all elements from the upstream publisher into a new publisher
    public func flatMap<T, P: Publisher>(
        _ transform: @escaping (Output) -> P
    ) -> AnyPublisher<T, Failure> where P.Output == T, P.Failure == Failure {
        return AnyPublisher { subscriber in
            let flatMapSubscriber = FlatMapSubscriber<Output, T, Failure, P>(
                downstream: subscriber,
                transform: transform
            )
            self.receive(subscriber: flatMapSubscriber)
        }
    }
    
    /// Delays delivery of all output to the downstream receiver by a specified time interval
    public func delay(
        for interval: TimeInterval,
        queue: DispatchQueue = .main
    ) -> AnyPublisher<Output, Failure> {
        return AnyPublisher { subscriber in
            let delaySubscriber = DelaySubscriber<Output, Failure>(
                downstream: subscriber,
                delay: interval,
                queue: queue
            )
            self.receive(subscriber: delaySubscriber)
        }
    }
    
    /// Handles errors from the upstream publisher by replacing it with another publisher or throwing an error
    public func tryCatch<P: Publisher>(
        _ handler: @escaping (Failure) throws -> P
    ) -> AnyPublisher<Output, Error> where P.Output == Output, P.Failure == Error {
        return AnyPublisher { subscriber in
            let tryCatchSubscriber = TryCatchSubscriber<Output, Failure, P>(
                downstream: subscriber,
                handler: handler
            )
            self.receive(subscriber: tryCatchSubscriber)
        }
    }
    
    /// Specifies the scheduler on which to receive elements from the publisher
    public func receive(on queue: DispatchQueue) -> AnyPublisher<Output, Failure> {
        return AnyPublisher { subscriber in
            let receiveOnSubscriber = ReceiveOnSubscriber<Output, Failure>(
                downstream: subscriber,
                queue: queue
            )
            self.receive(subscriber: receiveOnSubscriber)
        }
    }
}

private final class MapSubscriber<Upstream, Downstream, Failure: Error>: Subscriber {
    typealias Input = Upstream
    
    private let downstream: AnySubscriber<Downstream, Failure>
    private let transform: (Upstream) -> Downstream
    
    init(downstream: AnySubscriber<Downstream, Failure>, transform: @escaping (Upstream) -> Downstream) {
        self.downstream = downstream
        self.transform = transform
    }
    
    func receive(subscription: Subscription) {
        downstream.receive(subscription: subscription)
    }
    
    func receive(_ input: Upstream) -> Subscribers.Demand {
        return downstream.receive(transform(input))
    }
    
    func receive(completion: Subscribers.Completion<Failure>) {
        downstream.receive(completion: completion)
    }
}

private final class FilterSubscriber<Input, Failure: Error>: Subscriber {
    private let downstream: AnySubscriber<Input, Failure>
    private let isIncluded: (Input) -> Bool
    
    init(downstream: AnySubscriber<Input, Failure>, isIncluded: @escaping (Input) -> Bool) {
        self.downstream = downstream
        self.isIncluded = isIncluded
    }
    
    func receive(subscription: Subscription) {
        downstream.receive(subscription: subscription)
    }
    
    func receive(_ input: Input) -> Subscribers.Demand {
        guard isIncluded(input) else {
            return .unlimited
        }
        return downstream.receive(input)
    }
    
    func receive(completion: Subscribers.Completion<Failure>) {
        downstream.receive(completion: completion)
    }
}

private final class SetFailureTypeSubscriber<Input, UpstreamFailure: Error, DownstreamFailure: Error>: Subscriber {
    typealias Failure = UpstreamFailure
    
    private let downstream: AnySubscriber<Input, DownstreamFailure>
    private let debugID = UUID().uuidString.prefix(8)
    
    init(downstream: AnySubscriber<Input, DownstreamFailure>) {
        debugLog("SetFailureType", String(debugID), "Created (UpstreamFailure: \(UpstreamFailure.self), DownstreamFailure: \(DownstreamFailure.self))")
        self.downstream = downstream
    }
    
    func receive(subscription: Subscription) {
        debugLog("SetFailureType", String(debugID), "Received subscription: \(type(of: subscription))")
        downstream.receive(subscription: subscription)
    }
    
    func receive(_ input: Input) -> Subscribers.Demand {
        debugLog("SetFailureType", String(debugID), "Received value: \(input)")
        return downstream.receive(input)
    }
    
    func receive(completion: Subscribers.Completion<UpstreamFailure>) {
        if PublisherDebugConfig.shouldLog("SetFailureType") {
            debugLog("SetFailureType", String(debugID), "Received completion: \(completion)")
        }
        switch completion {
        case .finished:
            debugLog("SetFailureType", String(debugID), "Forwarding .finished")
            downstream.receive(completion: .finished)
        case .failure(let error):
            debugLog("SetFailureType", String(debugID), "Converting error from \(type(of: error)) to \(DownstreamFailure.self)")
            // Cast the error to DownstreamFailure
            downstream.receive(completion: .failure(error as! DownstreamFailure))
        }
    }
}

private final class FlatMapSubscriber<Upstream, Downstream, Failure: Error, P: Publisher>: Subscriber where P.Output == Downstream, P.Failure == Failure {
    typealias Input = Upstream
    
    private let downstream: AnySubscriber<Downstream, Failure>
    private let transform: (Upstream) -> P
    private var subscription: Subscription?
    private var innerSubscriptions: [AnyCancellable] = []
    private var upstreamCompleted = false
    private let lock = NSLock()
    private let debugID = UUID().uuidString.prefix(8)
    
    init(downstream: AnySubscriber<Downstream, Failure>, transform: @escaping (Upstream) -> P) {
        if PublisherDebugConfig.shouldLog("FlatMapSubscriber") {
            debugLog("FlatMapSubscriber", String(debugID), "Created")
        }
        self.downstream = downstream
        self.transform = transform
    }
    
    func receive(subscription: Subscription) {
        if PublisherDebugConfig.shouldLog("FlatMapSubscriber") {
            debugLog("FlatMapSubscriber", String(debugID), "Received subscription: \(type(of: subscription))")
        }
        self.subscription = subscription
        downstream.receive(subscription: subscription)
    }
    
    func receive(_ input: Upstream) -> Subscribers.Demand {
        if PublisherDebugConfig.shouldLog("FlatMapSubscriber") {
            if PublisherDebugConfig.logValues {
                debugLog("FlatMapSubscriber", String(debugID), "Received input: \(input)")
            } else {
                debugLog("FlatMapSubscriber", String(debugID), "Received input")
            }
        }
        let innerPublisher = transform(input)
        
        lock.lock()
        if PublisherDebugConfig.shouldLog("FlatMapSubscriber") {
            debugLog("FlatMapSubscriber", String(debugID), "Creating inner publisher subscription")
        }
        var innerSub: AnyCancellable?
        innerSub = innerPublisher.eraseToAnyPublisher().sink(
            receiveCompletion: { [weak self] completion in
                guard let self = self else { return }
                
                if PublisherDebugConfig.shouldLog("FlatMapSubscriber") {
                    debugLog("FlatMapSubscriber", String(self.debugID), "Inner publisher completed: \(completion)")
                }
                
                self.lock.lock()
                // Remove this subscription from our tracking
                if let sub = innerSub {
                    self.innerSubscriptions.removeAll { $0 === sub }
                }
                let shouldComplete = self.upstreamCompleted && self.innerSubscriptions.isEmpty
                if PublisherDebugConfig.shouldLog("FlatMapSubscriber") {
                    debugLog("FlatMapSubscriber", String(self.debugID), "upstreamCompleted=\(self.upstreamCompleted), innerSubscriptions.count=\(self.innerSubscriptions.count), shouldComplete=\(shouldComplete)")
                }
                self.lock.unlock()
                
                switch completion {
                case .failure(let error):
                    if PublisherDebugConfig.shouldLog("FlatMapSubscriber") {
                        debugLog("FlatMapSubscriber", String(self.debugID), "Forwarding failure: \(error)")
                    }
                    self.downstream.receive(completion: .failure(error))
                case .finished:
                    if shouldComplete {
                        if PublisherDebugConfig.shouldLog("FlatMapSubscriber") {
                            debugLog("FlatMapSubscriber", String(self.debugID), "Forwarding completion to downstream")
                        }
                        self.downstream.receive(completion: .finished)
                    } else {
                        if PublisherDebugConfig.shouldLog("FlatMapSubscriber") {
                            debugLog("FlatMapSubscriber", String(self.debugID), "Not forwarding completion yet (waiting for upstream or other inner publishers)")
                        }
                    }
                }
            },
            receiveValue: { [weak self] value in
                guard let self = self else { return }
                if PublisherDebugConfig.shouldLog("FlatMapSubscriber") {
                    if PublisherDebugConfig.logValues {
                        debugLog("FlatMapSubscriber", String(self.debugID), "Inner publisher sent value: \(value)")
                    } else {
                        debugLog("FlatMapSubscriber", String(self.debugID), "Inner publisher sent value")
                    }
                }
                _ = self.downstream.receive(value)
            }
        )
        if let sub = innerSub {
            innerSubscriptions.append(sub)
            if PublisherDebugConfig.shouldLog("FlatMapSubscriber") {
                debugLog("FlatMapSubscriber", String(debugID), "Inner subscription added (total: \(innerSubscriptions.count))")
            }
        }
        lock.unlock()
        
        return .unlimited
    }
    
    func receive(completion: Subscribers.Completion<Failure>) {
        if PublisherDebugConfig.shouldLog("FlatMapSubscriber") {
            debugLog("FlatMapSubscriber", String(debugID), "Upstream completed: \(completion)")
        }
        
        lock.lock()
        upstreamCompleted = true
        let hasInnerSubscriptions = !innerSubscriptions.isEmpty
        if PublisherDebugConfig.shouldLog("FlatMapSubscriber") {
            debugLog("FlatMapSubscriber", String(debugID), "Setting upstreamCompleted=true, innerSubscriptions.count=\(innerSubscriptions.count)")
        }
        lock.unlock()
        
        switch completion {
        case .failure(let error):
            if PublisherDebugConfig.shouldLog("FlatMapSubscriber") {
                debugLog("FlatMapSubscriber", String(debugID), "Forwarding upstream failure: \(error)")
            }
            downstream.receive(completion: .failure(error))
        case .finished:
            if !hasInnerSubscriptions {
                if PublisherDebugConfig.shouldLog("FlatMapSubscriber") {
                    debugLog("FlatMapSubscriber", String(debugID), "No inner subscriptions, forwarding completion")
                }
                downstream.receive(completion: .finished)
            } else {
                if PublisherDebugConfig.shouldLog("FlatMapSubscriber") {
                    debugLog("FlatMapSubscriber", String(debugID), "Waiting for \(innerSubscriptions.count) inner subscriptions to complete")
                }
            }
        }
    }
}

private final class DelaySubscriber<Input, Failure: Error>: Subscriber, @unchecked Sendable {
    private let downstream: AnySubscriber<Input, Failure>
    private let delay: TimeInterval
    private let queue: DispatchQueue
    private let lock = NSLock()
    private var isCompleted = false
    
    init(downstream: AnySubscriber<Input, Failure>, delay: TimeInterval, queue: DispatchQueue) {
        self.downstream = downstream
        self.delay = delay
        self.queue = queue
    }
    
    func receive(subscription: Subscription) {
        downstream.receive(subscription: subscription)
    }
    
    func receive(_ input: Input) -> Subscribers.Demand {
        lock.lock()
        guard !isCompleted else {
            lock.unlock()
            return .none
        }
        lock.unlock()
        
        let sendableInput = SendableValue(input)
        queue.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self = self else { return }
            self.lock.lock()
            guard !self.isCompleted else {
                self.lock.unlock()
                return
            }
            self.lock.unlock()
            _ = self.downstream.receive(sendableInput.value)
        }
        return .unlimited
    }

    func receive(completion: Subscribers.Completion<Failure>) {
        lock.lock()
        guard !isCompleted else {
            lock.unlock()
            return
        }
        isCompleted = true
        lock.unlock()

        let sendableCompletion = SendableValue(completion)
        queue.asyncAfter(deadline: .now() + delay) { [weak self] in
            self?.downstream.receive(completion: sendableCompletion.value)
        }
    }
}

private final class TryCatchSubscriber<Input, UpstreamFailure: Error, P: Publisher>: Subscriber where P.Output == Input, P.Failure == Error {
    typealias Failure = UpstreamFailure
    
    private let downstream: AnySubscriber<Input, Error>
    private let handler: (UpstreamFailure) throws -> P
    private var subscription: Subscription?
    private var recoverySubscription: AnyCancellable?
    private let debugID = UUID().uuidString.prefix(8)
    
    init(downstream: AnySubscriber<Input, Error>, handler: @escaping (UpstreamFailure) throws -> P) {
        debugLog("TryCatch", String(debugID), "Created")
        self.downstream = downstream
        self.handler = handler
    }
    
    func receive(subscription: Subscription) {
        debugLog("TryCatch", String(debugID), "Received subscription: \(type(of: subscription))")
        self.subscription = subscription
        downstream.receive(subscription: subscription)
    }
    
    func receive(_ input: Input) -> Subscribers.Demand {
        debugLog("TryCatch", String(debugID), "Received value: \(input)")
        return downstream.receive(input)
    }
    
    func receive(completion: Subscribers.Completion<UpstreamFailure>) {
        debugLog("TryCatch", String(debugID), "Received completion: \(completion)")
        switch completion {
        case .finished:
            debugLog("TryCatch", String(debugID), "Forwarding .finished")
            downstream.receive(completion: .finished)
        case .failure(let error):
            debugLog("TryCatch", String(debugID), "Caught error: \(error), calling handler")
            do {
                let recoveryPublisher = try handler(error)
                debugLog("TryCatch", String(debugID), "Handler returned recovery publisher, subscribing")
                
                // Subscribe to recovery publisher and forward all events to downstream
                let sub = recoveryPublisher.sink(
                    receiveCompletion: { [weak self] completion in
                        guard let self = self else { return }
                        debugLog("TryCatch", String(self.debugID), "Recovery publisher completed: \(completion)")
                        self.downstream.receive(completion: completion)
                    },
                    receiveValue: { [weak self] value in
                        guard let self = self else { return }
                        debugLog("TryCatch", String(self.debugID), "Recovery publisher sent value: \(value)")
                        _ = self.downstream.receive(value)
                    }
                )
                
                // Store the recovery subscription so it doesn't get deallocated
                self.recoverySubscription = sub
            } catch {
                debugLog("TryCatch", String(debugID), "Handler threw error: \(error)")
                downstream.receive(completion: .failure(error))
            }
        }
    }
}

private final class ReceiveOnSubscriber<Input, Failure: Error>: Subscriber, @unchecked Sendable {
    private let downstream: AnySubscriber<Input, Failure>
    private let queue: DispatchQueue
    private let debugID = UUID().uuidString.prefix(8)
    private let lock = NSLock()
    private var isCompleted = false
    
    init(downstream: AnySubscriber<Input, Failure>, queue: DispatchQueue) {
        debugLog("ReceiveOn", String(debugID), "Created for queue: \(queue.label)")
        self.downstream = downstream
        self.queue = queue
    }
    
    func receive(subscription: Subscription) {
        debugLog("ReceiveOn", String(debugID), "Received subscription: \(type(of: subscription))")
        // Forward subscription synchronously - this is important!
        downstream.receive(subscription: subscription)
    }
    
    func receive(_ input: Input) -> Subscribers.Demand {
        lock.lock()
        guard !isCompleted else {
            lock.unlock()
            debugLog("ReceiveOn", String(debugID), "Already completed, ignoring value")
            return .none
        }
        lock.unlock()
        
        debugLog("ReceiveOn", String(debugID), "Received value: \(input), dispatching to queue")
        
        // Use sync if already on target queue, otherwise async
        if queue === DispatchQueue.main && Thread.isMainThread {
            debugLog("ReceiveOn", String(debugID), "Already on main thread, forwarding synchronously")
            _ = self.downstream.receive(input)
        } else {
            let sendableInput = SendableValue(input)
            queue.async {
                debugLog("ReceiveOn", String(self.debugID), "On target queue, forwarding value")
                _ = self.downstream.receive(sendableInput.value)
            }
        }

        return .unlimited
    }

    func receive(completion: Subscribers.Completion<Failure>) {
        lock.lock()
        guard !isCompleted else {
            lock.unlock()
            debugLog("ReceiveOn", String(debugID), "Already completed, ignoring duplicate completion")
            return
        }
        isCompleted = true
        lock.unlock()

        debugLog("ReceiveOn", String(debugID), "Received completion: \(completion), dispatching to queue")

        if queue === DispatchQueue.main && Thread.isMainThread {
            debugLog("ReceiveOn", String(debugID), "Already on main thread, forwarding synchronously")
            self.downstream.receive(completion: completion)
        } else {
            let sendableCompletion = SendableValue(completion)
            queue.async {
                debugLog("ReceiveOn", String(self.debugID), "On target queue, forwarding completion")
                self.downstream.receive(completion: sendableCompletion.value)
            }
        }
    }
}

// MARK: - Just Publisher

/// A publisher that emits a single value and then finishes
public struct Just<Output>: Publisher {
    public typealias Failure = Never
    
    private let value: Output
    private let debugID: String
    
    public init(_ value: Output) {
        self.value = value
        self.debugID = String(UUID().uuidString.prefix(8))
    }
    
    public func receive<S>(subscriber: S) where S: Subscriber, S.Input == Output, S.Failure == Never {
        debugLog("Just", debugID, "Received subscriber, creating subscription")
        let subscription = JustSubscription(value: value, subscriber: subscriber)
        subscriber.receive(subscription: subscription)
        debugLog("Just", debugID, "Emitting value and completion")
        subscription.emit()
    }
}

private final class JustSubscription<Output, S: Subscriber>: Subscription where S.Input == Output, S.Failure == Never {
    private var subscriber: S?
    private let value: Output
    private let debugID: String
    
    init(value: Output, subscriber: S) {
        self.value = value
        self.subscriber = subscriber
        self.debugID = String(UUID().uuidString.prefix(8))
        debugLog("Just", debugID, "Created")
    }
    
    func emit() {
        debugLog("Just", debugID, "Sending value: \(value)")
        _ = subscriber?.receive(value)
        debugLog("Just", debugID, "Sending completion: .finished")
        subscriber?.receive(completion: .finished)
        subscriber = nil
    }
    
    func cancel() {
        debugLog("Just", debugID, "Cancelled")
        subscriber = nil
    }
}

// MARK: - Fail Publisher

/// A publisher that immediately terminates with a failure
public struct Fail<Output, Failure: Error>: Publisher {
    private let error: Failure
    
    public init(error: Failure) {
        self.error = error
    }
    
    public func receive<S>(subscriber: S) where S: Subscriber, S.Input == Output, S.Failure == Failure {
        subscriber.receive(subscription: FailSubscription())
        subscriber.receive(completion: .failure(error))
    }
}

private final class FailSubscription: Subscription {
    func cancel() {}
}

// MARK: - Deferred Publisher

/// A publisher that waits for a subscription before creating its upstream publisher
public struct Deferred<P: Publisher>: Publisher {
    public typealias Output = P.Output
    public typealias Failure = P.Failure
    
    private let createPublisher: () -> P
    
    public init(_ createPublisher: @escaping () -> P) {
        self.createPublisher = createPublisher
    }
    
    public func receive<S>(subscriber: S) where S: Subscriber, S.Input == Output, S.Failure == Failure {
        createPublisher().receive(subscriber: subscriber)
    }
}

// MARK: - Future Publisher

/// A publisher that eventually produces a single value and then finishes or fails
public final class Future<Output, Failure: Error>: Publisher {
    public typealias Promise = (Result<Output, Failure>) -> Void
    
    private let attemptToFulfill: (@escaping Promise) -> Void
    private let debugID: String
    
    public init(_ attemptToFulfill: @escaping (@escaping Promise) -> Void) {
        self.debugID = String(UUID().uuidString.prefix(8))
        debugLog("Future", debugID, "Created")
        self.attemptToFulfill = attemptToFulfill
    }
    
    public func receive<S>(subscriber: S) where S: Subscriber, S.Input == Output, S.Failure == Failure {
        debugLog("Future", debugID, "Received subscriber, creating subscription")
        let subscription = FutureSubscription(subscriber: subscriber, debugID: debugID)
        subscriber.receive(subscription: subscription)
        
        debugLog("Future", debugID, "Calling attemptToFulfill closure")
        let capturedDebugID = self.debugID
        attemptToFulfill { result in
            debugLog("Future", capturedDebugID, "Promise called with result: \(result)")
            subscription.fulfill(with: result)
        }
    }
}

private final class FutureSubscription<Output, Failure: Error, S: Subscriber>: Subscription
    where S.Input == Output, S.Failure == Failure {
    
    private var subscriber: S?
    private let lock = NSLock()
    private var isCancelled = false
    private let debugID: String
    
    init(subscriber: S, debugID: String) {
        self.subscriber = subscriber
        self.debugID = debugID
        debugLog("Future", debugID, "Created")
    }
    
    func fulfill(with result: Result<Output, Failure>) {
        debugLog("Future", debugID, "fulfill() called with: \(result)")
        lock.lock()
        guard !isCancelled, let subscriber = subscriber else {
            debugLog("Future", debugID, "Already cancelled or no subscriber")
            lock.unlock()
            return
        }
        self.subscriber = nil
        lock.unlock()
        
        switch result {
        case .success(let value):
            debugLog("Future", debugID, "Sending value: \(value)")
            _ = subscriber.receive(value)
            debugLog("Future", debugID, "Sending completion: .finished")
            subscriber.receive(completion: .finished)
        case .failure(let error):
            debugLog("Future", debugID, "Sending completion: .failure(\(error))")
            subscriber.receive(completion: .failure(error))
        }
    }
    
    func cancel() {
        debugLog("Future", debugID, "Cancelled")
        lock.lock()
        isCancelled = true
        subscriber = nil
        lock.unlock()
    }
}

// MARK: - First Operator

extension Publisher {
    /// Publishes only the first value received, then finishes
    public func first() -> AnyPublisher<Output, Failure> {
        return AnyPublisher { subscriber in
            let firstSubscriber = FirstSubscriber(downstream: subscriber)
            self.receive(subscriber: firstSubscriber)
        }
    }
    
    /// Publishes the first value that matches the predicate, then finishes
    public func first(where predicate: @escaping (Output) -> Bool) -> AnyPublisher<Output, Failure> {
        return AnyPublisher { subscriber in
            let firstWhereSubscriber = FirstWhereSubscriber(
                downstream: subscriber,
                predicate: predicate
            )
            self.receive(subscriber: firstWhereSubscriber)
        }
    }
}

private final class FirstSubscriber<Input, Failure: Error>: Subscriber {
    private let downstream: AnySubscriber<Input, Failure>
    private var subscription: Subscription?
    private var hasReceivedValue = false
    
    init(downstream: AnySubscriber<Input, Failure>) {
        self.downstream = downstream
    }
    
    func receive(subscription: Subscription) {
        self.subscription = subscription
        downstream.receive(subscription: subscription)
    }
    
    func receive(_ input: Input) -> Subscribers.Demand {
        guard !hasReceivedValue else {
            return .none
        }
        
        hasReceivedValue = true
        _ = downstream.receive(input)
        downstream.receive(completion: .finished)
        subscription?.cancel()
        
        return .none
    }
    
    func receive(completion: Subscribers.Completion<Failure>) {
        downstream.receive(completion: completion)
    }
}

private final class FirstWhereSubscriber<Input, Failure: Error>: Subscriber {
    private let downstream: AnySubscriber<Input, Failure>
    private let predicate: (Input) -> Bool
    private var subscription: Subscription?
    private var hasReceivedValue = false
    
    init(downstream: AnySubscriber<Input, Failure>, predicate: @escaping (Input) -> Bool) {
        self.downstream = downstream
        self.predicate = predicate
    }
    
    func receive(subscription: Subscription) {
        self.subscription = subscription
        downstream.receive(subscription: subscription)
    }
    
    func receive(_ input: Input) -> Subscribers.Demand {
        guard !hasReceivedValue else {
            return .none
        }
        
        guard predicate(input) else {
            return .unlimited
        }
        
        hasReceivedValue = true
        _ = downstream.receive(input)
        downstream.receive(completion: .finished)
        subscription?.cancel()
        
        return .none
    }
    
    func receive(completion: Subscribers.Completion<Failure>) {
        downstream.receive(completion: completion)
    }
}
