import SwiftUI

struct AnnotationEditorView: View {
    @Bindable var model: EditorModel
    let close: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            EditorCanvas(model: model)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color(nsColor: .underPageBackgroundColor))
        }
        .frame(minWidth: 640, minHeight: 420)
    }

    private var toolbar: some View {
        HStack(spacing: 12) {
            Picker("Tool", selection: $model.tool) {
                ForEach(EditorTool.allCases) { tool in
                    Image(systemName: tool.systemImage)
                        .help(tool.title)
                        .accessibilityLabel(tool.title)
                        .tag(tool)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .onChange(of: model.tool) { model.commitPendingText() }

            Menu {
                ForEach(RGBAColor.presets, id: \.self) { color in
                    Button {
                        model.color = color
                    } label: {
                        Label(colorName(color), systemImage: model.color == color ? "checkmark.circle.fill" : "circle.fill")
                    }
                }
            } label: {
                Circle()
                    .fill(Color(cgColor: model.color.cgColor))
                    .overlay(Circle().strokeBorder(.secondary, lineWidth: 1))
                    .frame(width: 16, height: 16)
            }
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Color")

            if model.document.crop != nil {
                Button("Reset Crop", action: model.resetCrop)
            }

            Spacer()

            Button(action: model.undo) { Image(systemName: "arrow.uturn.backward") }
                .disabled(!model.history.canUndo)
                .keyboardShortcut("z", modifiers: .command)
                .help("Undo")
            Button(action: model.redo) { Image(systemName: "arrow.uturn.forward") }
                .disabled(!model.history.canRedo)
                .keyboardShortcut("z", modifiers: [.command, .shift])
                .help("Redo")

            Divider().frame(height: 18)

            Button("Copy") { Task { await model.copy() } }
                .keyboardShortcut("c", modifiers: .command)
            Button("Save") { Task { await model.save() } }
                .keyboardShortcut("s", modifiers: .command)
            Button("Close", action: close)
                .keyboardShortcut("w", modifiers: .command)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private func colorName(_ color: RGBAColor) -> String {
        switch color {
        case .red: "Red"
        case .orange: "Orange"
        case .yellow: "Yellow"
        case .green: "Green"
        case .blue: "Blue"
        case .black: "Black"
        case .white: "White"
        default: "Custom"
        }
    }
}

/// The image with committed annotations, the in-progress one, the crop and the text field.
private struct EditorCanvas: View {
    @Bindable var model: EditorModel
    @State private var dragStart: CGPoint?
    @State private var dragEnd: CGPoint?
    @State private var dragPath: [CGPoint] = []
    /// Freehand input is smoothed the same way as draw on screen's.
    @State private var inkFilter = OneEuroFilter()
    @FocusState private var isTextFocused: Bool

    var body: some View {
        GeometryReader { geometry in
            let fitted = CanvasGeometry.fittedRect(imagePointSize: model.base.pointSize, in: geometry.size)
            let toView = CanvasGeometry.imageToView(fitted: fitted, imagePixelSize: model.pixelSize)

            ZStack(alignment: .topLeading) {
                Image(decorative: model.rendered, scale: model.base.scale)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: fitted.width, height: fitted.height)
                    .offset(x: fitted.minX, y: fitted.minY)

                Canvas { context, _ in
                    context.concatenate(toView)
                    drawCrop(in: &context)
                    drawInProgress(in: &context)
                }
                .allowsHitTesting(false)

                if let pending = model.pendingText {
                    textField(at: pending.point.applying(toView), scale: fitted.width / max(model.pixelSize.width, 1))
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height, alignment: .topLeading)
            .contentShape(Rectangle())
            .gesture(drag(fitted: fitted))
        }
        .onChange(of: model.pendingText == nil) { _, isNil in
            if !isNil { isTextFocused = true }
        }
    }

    private func drag(fitted: CGRect) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                let point = imagePoint(value.location, fitted: fitted)
                let time = value.time.timeIntervalSinceReferenceDate
                if dragStart == nil {
                    let start = imagePoint(value.startLocation, fitted: fitted)
                    dragStart = start
                    inkFilter = OneEuroFilter()
                    dragPath = [inkFilter.filter(start, at: time)]
                }
                dragEnd = point
                dragPath.append(inkFilter.filter(point, at: time))
            }
            .onEnded { value in
                let start = dragStart ?? imagePoint(value.startLocation, fitted: fitted)
                let end = imagePoint(value.location, fitted: fitted)
                // The stroke ends exactly where the pointer did.
                model.finishDrag(from: start, to: end, path: Array(dragPath.dropLast()) + [end])
                dragStart = nil
                dragEnd = nil
                dragPath = []
            }
    }

    private func imagePoint(_ location: CGPoint, fitted: CGRect) -> CGPoint {
        let point = CanvasGeometry.imagePoint(fromView: location, fitted: fitted, imagePixelSize: model.pixelSize)
        return CGPoint(
            x: min(max(point.x, 0), model.pixelSize.width),
            y: min(max(point.y, 0), model.pixelSize.height)
        )
    }

    private func drawCrop(in context: inout GraphicsContext) {
        let bounds = CGRect(origin: .zero, size: model.pixelSize)
        let pendingCrop = model.tool == .crop ? currentDragRect : nil
        guard let crop = pendingCrop ?? model.document.crop else { return }
        var outside = Path(bounds)
        outside.addRect(crop)
        context.fill(outside, with: .color(.black.opacity(0.5)), style: FillStyle(eoFill: true))
        context.stroke(Path(crop), with: .color(.white), lineWidth: 2 * model.base.scale)
    }

    private var currentDragRect: CGRect? {
        guard let dragStart, let dragEnd else { return nil }
        return CanvasGeometry.rect(from: dragStart, to: dragEnd, imagePixelSize: model.pixelSize)
    }

    private func drawInProgress(in context: inout GraphicsContext) {
        guard let dragStart, let dragEnd,
              let annotation = model.annotation(from: dragStart, to: dragEnd, path: dragPath)
        else { return }
        switch annotation {
        case let .arrow(from, to, color, lineWidth):
            var shaft = Path()
            shaft.move(to: from)
            shaft.addLine(to: to)
            context.stroke(shaft, with: .color(Color(cgColor: color.cgColor)), style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
            let angle = atan2(to.y - from.y, to.x - from.x)
            let head = AnnotationRenderer.arrowHeadLength(for: lineWidth)
            var tip = Path()
            tip.move(to: to)
            tip.addLine(to: CGPoint(x: to.x - cos(angle - .pi / 7) * head, y: to.y - sin(angle - .pi / 7) * head))
            tip.addLine(to: CGPoint(x: to.x - cos(angle + .pi / 7) * head, y: to.y - sin(angle + .pi / 7) * head))
            tip.closeSubpath()
            context.fill(tip, with: .color(Color(cgColor: color.cgColor)))
        case let .rectangle(rect, color, lineWidth):
            context.stroke(Path(rect), with: .color(Color(cgColor: color.cgColor)), lineWidth: lineWidth)
        case let .highlight(points, color, lineWidth):
            let path = AnnotationRenderer.inkPath(points: points, options: .highlighter(width: lineWidth))
            context.fill(Path(path), with: .color(Color(cgColor: color.cgColor)))
        case let .ink(points, color, lineWidth):
            let path = AnnotationRenderer.inkPath(points: points, options: .pen(width: lineWidth))
            context.fill(Path(path), with: .color(Color(cgColor: color.cgColor)))
        case let .pixelate(rect, _):
            context.fill(Path(rect), with: .color(.gray.opacity(0.5)))
            context.stroke(Path(rect), with: .color(.white), style: StrokeStyle(lineWidth: model.base.scale, dash: [4 * model.base.scale]))
        case .text:
            break
        }
    }

    private func textField(at viewPoint: CGPoint, scale: CGFloat) -> some View {
        let binding = Binding(
            get: { model.pendingText?.string ?? "" },
            set: { model.pendingText?.string = $0 }
        )
        return TextField("Text", text: binding, axis: .vertical)
            .textFieldStyle(.plain)
            .font(.system(size: max(model.fontSize * scale, 9), weight: .bold))
            .foregroundStyle(Color(cgColor: model.color.cgColor))
            .frame(minWidth: 120, alignment: .leading)
            .fixedSize()
            .padding(2)
            .background(RoundedRectangle(cornerRadius: 3).stroke(.secondary, style: StrokeStyle(lineWidth: 1, dash: [3])))
            .offset(x: viewPoint.x - 2, y: viewPoint.y - 2)
            .focused($isTextFocused)
            .onSubmit { model.commitPendingText() }
            .onExitCommand { model.pendingText = nil }
    }
}
