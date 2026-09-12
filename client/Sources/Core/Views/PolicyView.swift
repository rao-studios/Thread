import SwiftUI

/// Editor for the global extraction policy — the ontology and prompt that
/// govern entity/edge creation at ingest.
///
/// Changes are **prospective**: already-indexed documents keep the graph they
/// were extracted with until they are explicitly re-extracted.
struct PolicyView: View {
    @EnvironmentObject private var appState: AppState

    @State private var policy: ExtractionPolicyDTO?
    @State private var loading = false
    @State private var saving = false
    @State private var error: String?
    @State private var savedAt: Date?
    @State private var newKindName = ""
    @State private var newKindDescription = ""

    var body: some View {
        Group {
            if let policy {
                editor(policy)
            } else if loading {
                centered { ProgressView().scaleEffect(0.7) }
            } else {
                centered {
                    VStack(spacing: 10) {
                        Text(error ?? "Policy not loaded")
                            .font(.sewnSans(12))
                            .foregroundStyle(error == nil ? Color.sewnInk.opacity(0.35) : Color.sewnError)
                            .multilineTextAlignment(.center)
                        Button("Load policy") { Task { await load() } }
                            .font(.sewnSans(12))
                            .buttonStyle(.plain)
                            .foregroundStyle(Color.sewnGold)
                    }
                }
            }
        }
        .task { if policy == nil { await load() } }
    }

    // MARK: - Editor

    private func editor(_ current: ExtractionPolicyDTO) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                header

                group("Ontology", hint: "The entity kinds the extractor may assign. Descriptions are expanded into the prompt.") {
                    VStack(spacing: 6) {
                        ForEach(Array(current.kinds.enumerated()), id: \.offset) { index, kind in
                            kindRow(index: index, kind: kind)
                        }
                        addKindRow
                    }
                }

                group("Caps", hint: "Per-document ceilings applied during extraction.") {
                    HStack(spacing: 18) {
                        stepper("Max entities", value: Binding(
                            get: { policy?.maxEntities ?? 12 },
                            set: { policy?.maxEntities = $0 }
                        ), range: 1...100)

                        stepper("Max relationships", value: Binding(
                            get: { policy?.maxRelationships ?? 15 },
                            set: { policy?.maxRelationships = $0 }
                        ), range: 0...200)
                    }
                }

                group("Hub guard", hint: "Entities at or over this degree receive no new auto-edges. Off means unlimited.") {
                    HStack(spacing: 10) {
                        Toggle("Enabled", isOn: Binding(
                            get: { policy?.hubDegreeCap != nil },
                            set: { policy?.hubDegreeCap = $0 ? 24 : nil }
                        ))
                        .toggleStyle(.switch)
                        .font(.sewnSans(12))

                        if current.hubDegreeCap != nil {
                            stepper("Degree cap", value: Binding(
                                get: { policy?.hubDegreeCap ?? 24 },
                                set: { policy?.hubDegreeCap = $0 }
                            ), range: 1...500)
                        }
                    }
                }

                group("Co-mention edges", hint: "Links entities extracted from the same document with a weighted auto-edge.") {
                    VStack(alignment: .leading, spacing: 8) {
                        Toggle("Enabled", isOn: Binding(
                            get: { policy?.coMention?.enabled ?? false },
                            set: { on in
                                var rule = policy?.coMention
                                    ?? .init(enabled: on, predicate: "appears with", skipExplicitlyLinked: true)
                                rule.enabled = on
                                policy?.coMention = rule
                            }
                        ))
                        .toggleStyle(.switch)
                        .font(.sewnSans(12))

                        if current.coMention?.enabled == true {
                            HStack(spacing: 8) {
                                Text("Predicate")
                                    .font(.sewnSans(11))
                                    .foregroundStyle(Color.sewnInk.opacity(0.50))
                                TextField("appears with", text: Binding(
                                    get: { policy?.coMention?.predicate ?? "appears with" },
                                    set: { policy?.coMention?.predicate = $0 }
                                ))
                                .textFieldStyle(.roundedBorder)
                                .font(.sewnMono(11))
                                .frame(width: 200)
                            }
                            Toggle("Skip pairs already linked explicitly", isOn: Binding(
                                get: { policy?.coMention?.skipExplicitlyLinked ?? true },
                                set: { policy?.coMention?.skipExplicitlyLinked = $0 }
                            ))
                            .toggleStyle(.checkbox)
                            .font(.sewnSans(11.5))
                        }
                    }
                }

                group("Prompt override", hint: "Leave empty for the built-in prompt. {{kinds}}, {{max_entities}} and {{max_relationships}} expand.") {
                    TextEditor(text: Binding(
                        get: { policy?.promptTemplate ?? "" },
                        set: { policy?.promptTemplate = $0.isEmpty ? nil : $0 }
                    ))
                    .font(.sewnMono(11))
                    .frame(height: 120)
                    .padding(6)
                    .background(Color.sewnCard)
                    .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.sewnBorder, lineWidth: 1))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                }
            }
            .padding(24)
            .frame(maxWidth: 700, alignment: .leading)
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Extraction policy")
                    .font(.sewnSerif(17, weight: .medium))
                    .foregroundStyle(Color.sewnInk)
                Text("Global and prospective — existing documents keep their graph until re-extracted.")
                    .font(.sewnSans(11))
                    .foregroundStyle(Color.sewnInk.opacity(0.35))
            }

            Spacer()

            if let error {
                Text(error)
                    .font(.sewnSans(11))
                    .foregroundStyle(Color.sewnError)
                    .lineLimit(2)
                    .frame(maxWidth: 220, alignment: .trailing)
            } else if let savedAt {
                Text("Saved \(savedAt, style: .time)")
                    .font(.sewnSans(11))
                    .foregroundStyle(Color.sewnInk.opacity(0.35))
            }

            Button("Reload") { Task { await load() } }
                .font(.sewnSans(12))
                .buttonStyle(.plain)
                .foregroundStyle(Color.sewnGold)
                .disabled(loading || saving)

            Button(saving ? "Saving…" : "Save") { Task { await save() } }
                .font(.sewnSans(12))
                .buttonStyle(.borderedProminent)
                .tint(Color.sewnGold)
                .disabled(saving || loading)
        }
    }

    // MARK: - Kinds

    private func kindRow(index: Int, kind: ExtractionPolicyDTO.KindDef) -> some View {
        HStack(spacing: 8) {
            TextField("name", text: Binding(
                get: { policy?.kinds[safe: index]?.name ?? kind.name },
                set: { if policy?.kinds.indices.contains(index) == true { policy?.kinds[index].name = $0 } }
            ))
            .textFieldStyle(.roundedBorder)
            .font(.sewnMono(11))
            .frame(width: 130)

            TextField("description", text: Binding(
                get: { policy?.kinds[safe: index]?.description ?? kind.description },
                set: { if policy?.kinds.indices.contains(index) == true { policy?.kinds[index].description = $0 } }
            ))
            .textFieldStyle(.roundedBorder)
            .font(.sewnSans(11.5))

            Button {
                policy?.kinds.remove(at: index)
            } label: {
                Image(systemName: "minus.circle")
                    .font(.system(size: 12))
                    .foregroundStyle(Color.sewnInk.opacity(0.30))
            }
            .buttonStyle(.plain)
            .help("Remove kind")
        }
    }

    private var addKindRow: some View {
        HStack(spacing: 8) {
            TextField("new kind", text: $newKindName)
                .textFieldStyle(.roundedBorder)
                .font(.sewnMono(11))
                .frame(width: 130)

            TextField("description", text: $newKindDescription)
                .textFieldStyle(.roundedBorder)
                .font(.sewnSans(11.5))
                .onSubmit(addKind)

            Button(action: addKind) {
                Image(systemName: "plus.circle.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(Color.sewnGold)
            }
            .buttonStyle(.plain)
            .disabled(newKindName.trimmingCharacters(in: .whitespaces).isEmpty)
            .help("Add kind")
        }
    }

    private func addKind() {
        let name = newKindName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        policy?.kinds.append(.init(
            name: name,
            description: newKindDescription.trimmingCharacters(in: .whitespaces)
        ))
        newKindName = ""
        newKindDescription = ""
    }

    // MARK: - Layout helpers

    private func group<Content: View>(_ title: String,
                                      hint: String,
                                      @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title.uppercased())
                .font(.sewnSans(9.5))
                .tracking(1.3)
                .foregroundStyle(Color.sewnInk.opacity(0.35))
            content()
            Text(hint)
                .font(.sewnSans(10.5))
                .foregroundStyle(Color.sewnInk.opacity(0.28))
        }
    }

    private func stepper(_ label: String, value: Binding<Int>, range: ClosedRange<Int>) -> some View {
        HStack(spacing: 6) {
            Text(label)
                .font(.sewnSans(11.5))
                .foregroundStyle(Color.sewnInk.opacity(0.55))
            Stepper(value: value, in: range) {
                Text("\(value.wrappedValue)")
                    .font(.sewnMono(11.5))
                    .foregroundStyle(Color.sewnInk.opacity(0.80))
            }
            .frame(width: 90)
        }
    }

    private func centered<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        VStack { Spacer(); content(); Spacer() }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Actions

    private func load() async {
        loading = true
        error = nil
        do {
            policy = try await appState.api.policy()
        } catch {
            self.error = error.localizedDescription
        }
        loading = false
    }

    private func save() async {
        guard let current = policy else { return }
        saving = true
        error = nil
        do {
            // The server decodes this with the synthesized initializer, so every
            // non-optional key has to go back out or it 400s. Sending the whole
            // struct (rather than a delta) is what keeps that safe.
            policy = try await appState.api.updatePolicy(current)
            savedAt = Date()
        } catch {
            self.error = error.localizedDescription
        }
        saving = false
    }
}

extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
