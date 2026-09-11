import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// MARK: - Async/Await NetworkService

extension NetworkService {
    /// Async/await request method - the recommended way to use NetworkService
    /// - Parameters:
    ///   - request: The network request to execute
    ///   - options: Request options (mocking, error suppression, etc.)
    ///   - progress: Optional progress tracking
    /// - Returns: The transformed response
    func request<R: NetworkRequest>(
        _ request: R,
        options: RequestOptions = .init(),
        progress: Progress? = nil
    ) async throws -> R.TransformedResponse {
        // Check if we should return mocked data
        if options.useMockData {
            return try await makeMockedResponse(for: request)
        }
        
        // Build the request
        let urlRequest = try buildURLRequest(for: request)
        logger.info("[NetworkService] Sending \(request.method.rawValue.uppercased()) request to: \(urlRequest.url?.absoluteString ?? "unknown")")
        
        // Execute the request
        let (data, response) = try await executeRequest(urlRequest, progress: progress)
        
        // Decode and transform the response
        let result = try await decodeAndTransform(request: request, data: data, response: response)
        
        logger.info("[NetworkService] Request completed successfully")
        
        return result
    }
}

// MARK: - Private Helper Methods

extension NetworkService {
    
    /// Builds a URLRequest from a NetworkRequest
    private func buildURLRequest<R: NetworkRequest>(for request: R) throws -> URLRequest {
        // Build URL components
        let urlString = "\(request.ignoresEndpoint == false ? configuration.endpoint : "")\(request.path)"
        
        guard let encodedString = urlString.addingPercentEncoding(withAllowedCharacters: NSCharacterSet.urlQueryAllowed),
              let url = URL(string: encodedString),
              var components = URLComponents(url: url, resolvingAgainstBaseURL: true) else {
            throw NetworkError.invalidRequestUrl
        }
        
        // Add query parameters for GET/DELETE requests
        if request.method == .get || request.method == .delete {
            components.queryItems = buildQueryItems(from: request.data)
        }
        
        // Build URLRequest
        var urlRequest = URLRequest(url: components.url!)
        urlRequest.addValue("application/json", forHTTPHeaderField: "Content-Type")
        if let timeout = request.timeoutInterval {
            urlRequest.timeoutInterval = timeout
        }

        if !request.ignoresAuthHeader {
            urlRequest.addValue("Bearer \(configuration.base.apiKey)", forHTTPHeaderField: "Authorization")
        }

        urlRequest.httpMethod = request.method.rawValue.uppercased()

        // Add body for POST requests
        if request.method == .post {
            urlRequest.httpBody = try JSONSerialization.data(withJSONObject: request.data)
        }
        
        return urlRequest
    }
    
    /// Builds URL query items from request data
    private func buildQueryItems(from data: [String: Any]) -> [URLQueryItem] {
        var items: [URLQueryItem] = []
        var processedData = data
        
        // Handle pagination
        if let paginationData = processedData["pagination"] as? [String: Any] {
            for (key, value) in paginationData {
                processedData[key] = value
            }
            processedData["pagination"] = nil
        }
        
        // Convert data to query items
        for (name, value) in processedData {
            if let array = value as? [String] {
                items.append(contentsOf: array.map { value in
                    URLQueryItem(name: name + "[]", value: "\(value)")
                })
            } else if type(of: value) == type(of: NSNumber(value: true)), let boolean = value as? Bool {
                items.append(URLQueryItem(name: name, value: boolean ? "true" : "false"))
            } else {
                items.append(URLQueryItem(name: name, value: "\(value)"))
            }
        }
        
        return items
    }
    
    /// Executes a URLRequest using async/await
    private func executeRequest(_ urlRequest: URLRequest, progress: Progress?) async throws -> (Data, URLResponse) {
        #if canImport(FoundationNetworking)
        // Linux - use manual continuation with URLSession.dataTask
        return try await withCheckedThrowingContinuation { continuation in
            let task = URLSession.shared.dataTask(with: urlRequest) { data, response, error in
                if let error = error {
                    self.logger.info("[NetworkService] Request failed: \(error.localizedDescription)")
                    continuation.resume(throwing: error)
                } else if let data = data, let response = response {
                    continuation.resume(returning: (data, response))
                } else {
                    let unknownError = NSError(
                        domain: "NetworkService",
                        code: -1,
                        userInfo: [NSLocalizedDescriptionKey: "Unknown network error"]
                    )
                    continuation.resume(throwing: unknownError)
                }
            }
            
            // Add progress tracking if provided
            if let progress = progress {
                progress.addChild(task.progress, withPendingUnitCount: 100)
            }
            
            task.resume()
        }
        #else
        // Apple platforms - use native async URLSession
        return try await URLSession.shared.data(for: urlRequest)
        #endif
    }
    
    /// Decodes the response and applies any transformations
    private func decodeAndTransform<R: NetworkRequest>(
        request: R,
        data: Data,
        response: URLResponse
    ) async throws -> R.TransformedResponse {
        // Store response headers if needed
        if let httpResponse = response as? HTTPURLResponse {
            var headers = [String: String]()
            for (name, value) in httpResponse.allHeaderFields {
                guard let name = name as? String else { continue }
                headers[name] = value as? String
            }
            // TODO: Store headers in state if needed
            // center.state.headers = headers
        }
        
        // Reject non-2xx responses before attempting to decode the success type.
        if let httpResponse = response as? HTTPURLResponse,
           !(200...299).contains(httpResponse.statusCode) {
            let body = String(data: data, encoding: .utf8) ?? "<non-UTF8 body>"
            logger.warning("[NetworkService] Non-2xx response (\(httpResponse.statusCode)): \(body)")
            throw NetworkError.invalidResponse
        }

        // Decode the response
        let decoder = JSONDecoder()
        decoder.dataDecodingStrategy = .base64
        decoder.keyDecodingStrategy = .useDefaultKeys
        decoder.nonConformingFloatDecodingStrategy = .convertFromString(
            positiveInfinity: "+∞",
            negativeInfinity: "-∞",
            nan: "NaN"
        )

        let intermediateResponse = try decoder.decode(R.Response.self, from: data)
        
        // Check if transformation is needed
        if R.TransformedResponse.self == R.Response.self {
            // No transformation needed
            return intermediateResponse as! R.TransformedResponse
        } else {
            // Apply transformation using the Combine-based transform
            // We use withCheckedThrowingContinuation directly here for the URLSession callback pattern
            let publisher = Just(intermediateResponse)
                .setFailureType(to: Error.self)
                .eraseToAnyPublisher()
            
            let transformedPublisher = try request.transform(publisher)
            
            // Convert using AsyncThrowingStream for better compatibility
            var iterator = transformedPublisher.values.makeAsyncIterator()
            guard let result = try await iterator.next() else {
                throw NetworkError.invalidRequestUrl // TODO: Create proper error
            }
            return result
        }
    }
    
    /// Creates a mocked response for testing
    private func makeMockedResponse<R: NetworkRequest>(for request: R) async throws -> R.TransformedResponse {
        // Simulate network delay
        try await Task.sleep(nanoseconds: 500_000_000) // 0.5 seconds
        
        if let mockedRequest = request as? AnyMockedRequest,
           let mockedResponse = mockedRequest.rawMockedResponse as? R.TransformedResponse {
            return mockedResponse
        } else if R.Response.self == EmptyResponse.self {
            // For empty response, return empty response as a mocked one
            return EmptyResponse() as! R.TransformedResponse
        } else {
            throw NetworkError.noMockDataAvailable
        }
    }
}

// MARK: - Publisher Extension for Async Conversion

extension Publisher where Output: Sendable {
    /// Converts a publisher to an async sequence
    var values: AsyncThrowingStream<Output, Error> {
        AsyncThrowingStream { continuation in
            let cancellable = self.sink(
                receiveCompletion: { completion in
                    switch completion {
                    case .finished:
                        continuation.finish()
                    case .failure(let error):
                        continuation.finish(throwing: error)
                    }
                },
                receiveValue: { value in
                    continuation.yield(value)
                }
            )
            
            continuation.onTermination = { _ in
                cancellable.cancel()
            }
        }
    }
}
