//
//  StackSecretMiddleware.swift
//  thread
//
//  WHAT: Local mode. When the app that launched this Thread hands it its
//        stack secret (AMBIENT_STACK_SECRET, or RAO_HOME + RAO_APP on a shared
//        ~/.rao stack), every request must carry that secret in
//        X-Ambient-Secret and address this machine by loopback.
//  IN:   StackMode.thread(environment:), decided once at start. A Thread is
//        always one app's: it accepts that app's secret and no other, even on
//        a stack where Sewn accepts every app's.
//  OUT:  401 without the secret; 421 for a Host that isn't loopback
//  PIN:  Keeps web pages out. A page can't send a custom header cross-site
//        without a CORS preflight, and local mode answers none; a
//        DNS-rebinding page arrives under its own Host and never learns the
//        secret. /health stays open so a launcher can ask for proof of the
//        secret without sending it. The rules themselves live in RaoStack,
//        shared with Sewn and every launcher.
//

import Foundation
import HTTPTypes
import Hummingbird
import RaoStack

extension HTTPField.Name {
    static let ambientSecret = HTTPField.Name(StackSecret.headerName)!
    static let ambientNonce = HTTPField.Name(StackSecret.nonceHeaderName)!
    static let raoApp = HTTPField.Name(StackSecret.appHeaderName)!
}

struct StackSecretMiddleware<Context: RequestContext>: RouterMiddleware {
    let mode: StackMode

    func handle(
        _ request: Request,
        context: Context,
        next: (Request, Context) async throws -> Response
    ) async throws -> Response {
        if request.uri.path == "/health" {
            return try await next(request, context)
        }
        switch mode.admit(authority: request.head.authority, presented: request.headers[.ambientSecret]) {
        case .admitted:
            return try await next(request, context)
        case .notLoopback:
            throw HTTPError(.misdirectedRequest, message: "This server answers on loopback only")
        case .badSecret:
            throw HTTPError(.unauthorized, message: "Missing or wrong X-Ambient-Secret")
        }
    }
}
