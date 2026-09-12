import SwiftUI
import Combine

/// Drives `GraphLayout` at ~60Hz and stops once the layout settles.
///
/// Deliberately a timer rather than `TimelineView(.animation)`: stepping physics
/// from inside a view body means mutating state during view evaluation, and it
/// would keep redrawing forever instead of cooling to a stop.
@MainActor
final class GraphSimulation: ObservableObject {

    @Published private(set) var layout = GraphLayout()
    /// Bumped every tick so the canvas redraws without republishing the layout.
    @Published private(set) var frame: Int = 0

    private var timer: Timer?

    deinit { timer?.invalidate() }

    var isRunning: Bool { timer != nil }

    // MARK: - Content

    func reset(with response: GraphResponseDTO, size: CGSize) {
        layout.bounds = size == .zero ? layout.bounds : size
        layout.reset(with: response)
        start()
    }

    func merge(_ response: GraphResponseDTO, expandedFrom entityId: String?) {
        layout.merge(response, expandedFrom: entityId)
        start()
    }

    func clear() {
        stop()
        layout = GraphLayout()
        frame = 0
    }

    // MARK: - Interaction

    func resize(to size: CGSize) {
        guard size != .zero, size != layout.bounds else { return }
        layout.resize(to: size)
        start()
    }

    func drag(_ index: Int, to point: CGPoint) {
        layout.drag(index, to: point)
        frame &+= 1
        start()
    }

    func setPinned(_ index: Int, _ value: Bool) {
        layout.setPinned(index, value)
        frame &+= 1
        start()
    }

    func removeNode(id: String) {
        layout.removeNode(id: id)
        frame &+= 1
        start()
    }

    func removeEdge(id: String) {
        layout.removeEdge(id: id)
        frame &+= 1
        start()
    }

    /// Kick a settled layout back into motion — used after a manual re-layout.
    func reheat() {
        layout.reheat(to: 0.6)
        start()
    }

    // MARK: - Loop

    func start() {
        guard timer == nil, !layout.isEmpty else { return }
        if layout.isSettled { layout.reheat(to: 0.3) }
        let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func tick() {
        layout.step()
        frame &+= 1
        if layout.isSettled { stop() }
    }
}
