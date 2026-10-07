import SwiftUI

/// The strip above the image: tools, colors, sizes, history, and the two
/// ways out, copy and save.
struct EditorToolbar: View {
    @ObservedObject var model: EditorModel
    var onCommand: (EditorCommand) -> Void

    var body: some View {
        HStack(spacing: 10) {
            HStack(spacing: 2) {
                ForEach(EditorTool.allCases) { tool in
                    toolButton(tool)
                }
            }

            divider

            HStack(spacing: 6) {
                ForEach(Array(EditorPalette.colors.enumerated()), id: \.offset) { index, color in
                    swatch(color, index: index)
                }
            }

            divider

            HStack(spacing: 2) {
                ForEach(0..<3) { size in
                    Button { model.setSize(size) } label: {
                        Circle()
                            .fill(Color.primary)
                            .frame(width: [5, 8, 12][size], height: [5, 8, 12][size])
                            .frame(width: 24, height: 26)
                            .background(model.size == size ? Color.accentColor.opacity(0.22) : .clear,
                                        in: RoundedRectangle(cornerRadius: 6))
                    }
                    .buttonStyle(.plain)
                    .help([L("Thin", "Fino"), L("Medium", "Medio"), L("Thick", "Grueso")][size])
                }
            }

            divider

            HStack(spacing: 2) {
                iconButton("arrow.uturn.backward", help: L("Undo (⌘Z)", "Deshacer (⌘Z)"), enabled: model.canUndo) {
                    model.undo()
                }
                iconButton("arrow.uturn.forward", help: L("Redo (⌘⇧Z)", "Rehacer (⌘⇧Z)"), enabled: model.canRedo) {
                    model.redo()
                }
            }

            Spacer(minLength: 8)

            if model.pendingCrop != nil {
                Text(L("Return to crop", "Enter para recortar"))
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
            }

            Button(L("Copy", "Copiar")) { onCommand(.copy) }
                .help(L("Copy the image (⌘C). Esc copies and closes.",
                        "Copia la imagen (⌘C). Esc copia y cierra."))
            Button(L("Save", "Guardar")) { onCommand(.save) }
                .buttonStyle(.borderedProminent)
                .help(L("Save to Capturas (⌘S). ⌘⇧S to choose where.",
                        "Guarda en Capturas (⌘S). ⌘⇧S para elegir dónde."))
        }
        .controlSize(.regular)
        .padding(.horizontal, 12)
        .frame(height: 46)
        .background(.bar)
    }

    private var divider: some View {
        Divider().frame(height: 22)
    }

    private func toolButton(_ tool: EditorTool) -> some View {
        Button { model.tool = tool } label: {
            Image(systemName: tool.symbol)
                .font(.system(size: 14, weight: .medium))
                .frame(width: 30, height: 28)
                .foregroundStyle(model.tool == tool ? Color.accentColor : Color.primary)
                .background(model.tool == tool ? Color.accentColor.opacity(0.18) : .clear,
                            in: RoundedRectangle(cornerRadius: 7))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("\(tool.title) (\(tool.key.uppercased()))")
    }

    private func swatch(_ color: NSColor, index: Int) -> some View {
        let selected = model.color == color
        return Button { model.setColor(color) } label: {
            Circle()
                .fill(Color(nsColor: color))
                .overlay(Circle().stroke(Color.primary.opacity(0.25), lineWidth: 0.5))
                .frame(width: 16, height: 16)
                .padding(3)
                .overlay(Circle().stroke(selected ? Color.accentColor : .clear, lineWidth: 2))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(L("Color \(index + 1)", "Color \(index + 1)"))
    }

    private func iconButton(_ symbol: String, help: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .medium))
                .frame(width: 28, height: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.35)
        .help(help)
    }
}
