import SwiftUI
import AppKit

struct CreateAgentView: View {
    @EnvironmentObject var manager: LaunchAgentManager
    @Environment(\.dismiss) private var dismiss

    @State private var step = 0
    @State private var selectedTemplate: AgentTemplate = .runScript
    @State private var formData = AgentTemplate.runScript.defaultFormData()
    @State private var loadAfterCreate = true
    @State private var errorMessage: String?
    @State private var isCreating = false

    var body: some View {
        VStack(spacing: 0) {
            // Step indicator
            HStack(spacing: 0) {
                ForEach(0..<3) { i in
                    HStack(spacing: 6) {
                        Circle()
                            .fill(i <= step ? Color.accentColor : Color.gray.opacity(0.3))
                            .frame(width: 8, height: 8)
                        Text(["Template", "Configure", "Review"][i])
                            .font(.system(.caption, weight: i == step ? .semibold : .regular))
                            .foregroundStyle(i == step ? .primary : .secondary)
                    }
                    if i < 2 {
                        Rectangle()
                            .fill(i < step ? Color.accentColor : Color.gray.opacity(0.3))
                            .frame(height: 1)
                            .frame(maxWidth: 40)
                            .padding(.horizontal, 8)
                    }
                }
            }
            .padding(.top, 20)
            .padding(.bottom, 16)

            Divider()

            // Content
            Group {
                switch step {
                case 0: templateStep
                case 1: configureStep
                case 2: reviewStep
                default: EmptyView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            Divider()

            // Navigation
            HStack {
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)

                Spacer()

                if step > 0 {
                    Button("Back") {
                        withAnimation { step -= 1 }
                    }
                }

                if step < 2 {
                    Button("Next") {
                        withAnimation { step += 1 }
                    }
                    .keyboardShortcut(.defaultAction)
                    .disabled(step == 1 && !formData.validate().isEmpty)
                } else {
                    Button("Create Agent") {
                        createAgent()
                    }
                    .keyboardShortcut(.defaultAction)
                    .disabled(isCreating)
                }
            }
            .padding(16)
        }
        .frame(width: 580, height: 520)
    }

    // MARK: - Step 1: Template

    private var templateStep: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 12)], spacing: 12) {
                ForEach(AgentTemplate.allCases) { template in
                    TemplateCard(
                        template: template,
                        isSelected: selectedTemplate == template
                    ) {
                        selectedTemplate = template
                        formData = template.defaultFormData()
                    }
                }
            }
            .padding(20)
        }
    }

    // MARK: - Step 2: Configure

    private var configureStep: some View {
        Form {
            Section("Identity") {
                Picker("Domain", selection: $formData.domain) {
                    ForEach([AgentDomain.userAgents, .globalAgents, .globalDaemons]) { domain in
                        Text(domain.rawValue).tag(domain)
                    }
                }
                if formData.domain != .userAgents {
                    Text("Creating this service requires macOS administrator authorization.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                TextField("Label (reverse-DNS)", text: $formData.label)
                    .textFieldStyle(.roundedBorder)
            }

            Section("Program") {
                HStack {
                    TextField("Program path", text: $formData.program)
                        .textFieldStyle(.roundedBorder)
                    Button("Browse...") { browseForProgram() }
                }

                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("Arguments")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button {
                            formData.arguments.append("")
                        } label: {
                            Image(systemName: "plus")
                                .font(.caption)
                        }
                        .buttonStyle(.plain)
                    }
                    ForEach(formData.arguments.indices, id: \.self) { i in
                        HStack {
                            TextField("Argument \(i + 1)", text: $formData.arguments[i])
                                .textFieldStyle(.roundedBorder)
                                .controlSize(.small)
                            Button {
                                formData.arguments.remove(at: i)
                            } label: {
                                Image(systemName: "minus.circle")
                                    .foregroundStyle(.red.opacity(0.7))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }

            Section("Schedule") {
                Toggle("Run at Load", isOn: $formData.runAtLoad)
                Toggle("Keep Alive", isOn: $formData.keepAlive)

                HStack {
                    Text("Start Interval (seconds)")
                    Spacer()
                    TextField("", value: $formData.startInterval, format: .number)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 100)
                        .controlSize(.small)
                }
            }

            Section("Watch Paths") {
                ForEach(formData.watchPaths.indices, id: \.self) { i in
                    HStack {
                        TextField("Path", text: $formData.watchPaths[i])
                            .textFieldStyle(.roundedBorder)
                            .controlSize(.small)
                        Button {
                            formData.watchPaths.remove(at: i)
                        } label: {
                            Image(systemName: "minus.circle")
                                .foregroundStyle(.red.opacity(0.7))
                        }
                        .buttonStyle(.plain)
                    }
                }
                Button("Add Watch Path") {
                    formData.watchPaths.append("")
                }
                .font(.caption)
            }

            Section("Logging") {
                TextField("Stdout Path", text: Binding(
                    get: { formData.standardOutPath ?? "" },
                    set: { formData.standardOutPath = $0.isEmpty ? nil : $0 }
                ))
                .textFieldStyle(.roundedBorder)

                TextField("Stderr Path", text: Binding(
                    get: { formData.standardErrorPath ?? "" },
                    set: { formData.standardErrorPath = $0.isEmpty ? nil : $0 }
                ))
                .textFieldStyle(.roundedBorder)
            }

            // Validation errors
            let errors = formData.validate()
            if !errors.isEmpty {
                Section {
                    ForEach(errors, id: \.self) { error in
                        Label(error, systemImage: "exclamationmark.triangle")
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
    }

    // MARK: - Step 3: Review

    private var reviewStep: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Review your agent configuration")
                .font(.headline)
                .padding(.horizontal, 20)
                .padding(.top, 16)
            Text("\(formData.domain.rawValue) · \(formData.domain == .userAgents ? manager.userAgentsDirectory : formData.domain.path)/\(formData.label).plist")
                .font(.caption).foregroundStyle(.secondary).textSelection(.enabled).padding(.horizontal, 20)

            // Preview XML
            ScrollView {
                Text(previewXML())
                    .font(.system(size: 11, design: .monospaced))
                    .textSelection(.enabled)
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(.fill.quinary, in: RoundedRectangle(cornerRadius: 8))
            .padding(.horizontal, 20)

            HStack {
                Toggle("Load agent after creating", isOn: $loadAfterCreate)
                    .font(.caption)
                Spacer()
            }
            .padding(.horizontal, 20)

            if let error = errorMessage {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .padding(.horizontal, 20)
            }
        }
        .padding(.bottom, 8)
    }

    // MARK: - Actions

    private func browseForProgram() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = URL(fileURLWithPath: "/usr/local/bin")
        if panel.runModal() == .OK, let url = panel.url {
            formData.program = url.path
        }
    }

    private func createAgent() {
        isCreating = true
        errorMessage = nil

        Task {
            do {
                try await manager.createAgent(from: formData, andLoad: loadAfterCreate)
                dismiss()
            } catch {
                errorMessage = error.localizedDescription
                isCreating = false
            }
        }
    }

    private func previewXML() -> String {
        let dict = formData.toPlistDictionary()
        guard let data = try? PropertyListSerialization.data(
            fromPropertyList: dict, format: .xml, options: 0
        ), let str = String(data: data, encoding: .utf8) else {
            return "Unable to generate preview"
        }
        return str
    }
}

// MARK: - Template Card

struct TemplateCard: View {
    let template: AgentTemplate
    let isSelected: Bool
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: 10) {
                Image(systemName: template.icon)
                    .font(.system(size: 28))
                    .foregroundStyle(isSelected ? .white : .accentColor)

                Text(template.rawValue)
                    .font(.system(.caption, weight: .semibold))
                    .foregroundStyle(isSelected ? .white : .primary)

                Text(template.description)
                    .font(.system(size: 9))
                    .foregroundStyle(isSelected ? .white.opacity(0.8) : .secondary)
                    .multilineTextAlignment(.center)
                    .lineLimit(3)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 16)
            .padding(.horizontal, 12)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(isSelected ? Color.accentColor : (isHovered ? Color.gray.opacity(0.1) : Color.gray.opacity(0.05)))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(isSelected ? Color.accentColor : Color.gray.opacity(0.2), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .scaleEffect(isHovered ? 1.02 : 1.0)
        .animation(.spring(response: 0.25, dampingFraction: 0.7), value: isHovered)
    }
}
