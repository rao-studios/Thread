//
//  AnyPublisher.swift
//  database-server
//
//  Created by Ritesh Pakala Rao on 12/21/25.
//

import Foundation

enum AsyncError: Error {
    case finishedWithoutValue
}

extension AnyPublisher where Output: Sendable {
    func async() async throws -> Output {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Output, Error>) in
            let lock = NSLock()
            var resumed = false
            var cancellable: AnyCancellable?

            cancellable = first()
                .sink { result in
                    lock.lock()
                    guard !resumed else { lock.unlock(); return }
                    resumed = true
                    lock.unlock()
                    cancellable?.cancel()
                    switch result {
                    case .finished:
                        continuation.resume(throwing: AsyncError.finishedWithoutValue)
                    case let .failure(error):
                        continuation.resume(throwing: error)
                    }
                } receiveValue: { value in
                    lock.lock()
                    guard !resumed else { lock.unlock(); return }
                    resumed = true
                    lock.unlock()
                    cancellable?.cancel()
                    continuation.resume(returning: value)
                }
        }
    }
}
