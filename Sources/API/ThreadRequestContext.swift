import Hummingbird

/// Custom request context for Thread.
///
/// - Overrides the 2 MB default `maxUploadSize` to 100 MB so that batch
///   embedding requests with large document payloads are accepted.
/// - Uses the standard `ApplicationRequestContextSource` initializer, making
///   it a drop-in for `BasicRequestContext` with no additional dependencies.
struct ThreadRequestContext: RequestContext {
    var coreContext: CoreRequestContextStorage

    init(source: ApplicationRequestContextSource) {
        self.coreContext = .init(source: source)
    }

    /// Allow up to 100 MB request bodies (needed for large batch embeddings).
    var maxUploadSize: Int { 100 * 1_024 * 1_024 }
}
