import Conduit
import Hummingbird

private struct AvailabilityRequest: Codable {
    let acceptingStorage: Bool

    enum CodingKeys: String, CodingKey {
        case acceptingStorage = "accepting_storage"
    }
}

private struct AvailabilityResponse: ResponseCodable {
    let accepted: Bool
}

func registerAvailabilityRoute(
    _ app: some RouterMethods<TotemRequestContext>,
    registrationClient: MothershipRegistrationClient
) {
    app.post("/v1/availability") { request, context async throws -> AvailabilityResponse in
        let body = try await request.decode(as: AvailabilityRequest.self, context: context)
        await registrationClient.sendAvailabilityUpdate(acceptingStorage: body.acceptingStorage)
        return AvailabilityResponse(accepted: true)
    }
}
