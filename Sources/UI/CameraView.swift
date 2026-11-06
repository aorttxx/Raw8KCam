import AVFoundation
import SwiftUI
import UIKit

// MARK: - Modificador de Material "Liquid Glass" (Inspirado en Vidrio.tendies)
struct LiquidGlassModifier: ViewModifier {
    var cornerRadius: CGFloat = 20
    var tintColor: Color = .cyan
    var isHighlighted: Bool = false

    func body(content: Content) -> some View {
        content
            .background(
                ZStack {
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .fill(.ultraThinMaterial)

                    // Refracción cáustica diagonal tipo lente de vidrio líquido
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [
                                    Color.white.opacity(isHighlighted ? 0.34 : 0.18),
                                    tintColor.opacity(isHighlighted ? 0.28 : 0.08),
                                    Color.clear,
                                    Color(red: 0.55, green: 0.38, blue: 1.0).opacity(0.12)
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                }
            )
            .overlay(
                // Borde especular de cristal (brillo intenso arriba/izquierda y reflejo frío abajo/derecha)
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(
                        LinearGradient(
                            colors: [
                                Color.white.opacity(isHighlighted ? 0.90 : 0.62),
                                Color.white.opacity(0.12),
                                tintColor.opacity(isHighlighted ? 0.65 : 0.32)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: isHighlighted ? 1.5 : 1.0
                    )
            )
            .shadow(color: Color.black.opacity(0.42), radius: 12, x: 0, y: 6)
    }
}

extension View {
    func liquidGlass(cornerRadius: CGFloat = 20, tint: Color = .cyan, highlighted: Bool = false) -> some View {
        modifier(LiquidGlassModifier(cornerRadius: cornerRadius, tintColor: tint, isHighlighted: highlighted))
    }
}

// MARK: - Visor Nativo AVCaptureVideoPreviewLayer Sincronizado con el Formato Guardado
struct CameraPreviewView: UIViewRepresentable {
    let session: AVCaptureSession
    let onTapFocus: (CGPoint, CGPoint) -> Void

    final class VideoPreviewUIView: UIView {
        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
        var tapHandler: ((CGPoint, CGPoint) -> Void)?

        @objc func handleTap(_ sender: UITapGestureRecognizer) {
            let pt = sender.location(in: self)
            let devPt = previewLayer.captureDevicePointConverted(fromLayerPoint: pt)
            tapHandler?(devPt, pt)
        }
    }

    func makeUIView(context: Context) -> VideoPreviewUIView {
        let v = VideoPreviewUIView()
        v.backgroundColor = .black
        v.previewLayer.session = session
        v.previewLayer.videoGravity = .resizeAspectFill
        let tap = UITapGestureRecognizer(target: v, action: #selector(VideoPreviewUIView.handleTap(_:)))
        v.addGestureRecognizer(tap)
        v.tapHandler = onTapFocus
        return v
    }

    func updateUIView(_ uiView: VideoPreviewUIView, context: Context) {
        uiView.tapHandler = onTapFocus
    }
}

// MARK: - Hoja Nativa de Compartir (.DNG / .MOV 8K / 6K)
struct ShareSheetView: UIViewControllerRepresentable {
    let items: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }
    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}

enum ActiveDrawerControl: String, CaseIterable {
    case none
    case exposure
    case focus
}

struct CameraView: View {
    @StateObject private var engine = CameraEngine()
    @State private var activeDrawer: ActiveDrawerControl = .none
    @State private var showShareSheet = false

    private let fpsOptions: [Int] = [24, 30, 60]

    private let shutterPresets: [(String, Double)] = [
        ("1/4000", 1.0 / 4000.0),
        ("1/1000", 1.0 / 1000.0),
        ("1/250", 1.0 / 250.0),
        ("1/120", 1.0 / 120.0),
        ("1/60", 1.0 / 60.0),
        ("1/30", 1.0 / 30.0),
        ("1/15", 1.0 / 15.0),
        ("1/4", 1.0 / 4.0)
    ]

    var body: some View {
        ZStack {
            // Fondo ambiental oscuro con reflejos cáusticos tipo Vidrio.tendies
            ZStack {
                Color(red: 0.03, green: 0.04, blue: 0.07)
                Circle()
                    .fill(accentColor.opacity(0.14))
                    .frame(width: 320, height: 320)
                    .blur(radius: 75)
                    .offset(x: -110, y: -240)
                Circle()
                    .fill(Color(red: 0.45, green: 0.25, blue: 0.95).opacity(0.14))
                    .frame(width: 300, height: 300)
                    .blur(radius: 80)
                    .offset(x: 120, y: 240)
            }
            .ignoresSafeArea()

            VStack(spacing: 8) {
                // 1. Cápsula Superior Liquid Glass (Telemetría + Histograma + FPS)
                topLiquidGlassHUD
                    .padding(.horizontal, 12)
                    .padding(.top, 2)

                // 2. Visor con Proporción Exacta (3:4 o 9:16 idéntica al video/foto guardado)
                GeometryReader { geo in
                    let availW = geo.size.width
                    let availH = geo.size.height
                    let aspect = engine.viewfinderPortraitAspect // 0.75 (3:4) o 0.5625 (9:16)
                    let fitH = min(availH, availW / aspect)
                    let fitW = min(availW, fitH * aspect)

                    ZStack {
                        // Marco exacto de captura (lo que ves aquí es 100% idéntico a lo que se guarda)
                        ZStack {
                            CameraPreviewView(session: engine.session) { devPt, viewPt in
                                engine.focusAndExpose(at: devPt, viewPoint: viewPt)
                            }
                            .frame(width: fitW, height: fitH)
                            .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))

                            // Rejilla óptica de tercios y borde especular Liquid Glass
                            viewfinderGlassOverlay(width: fitW, height: fitH)

                            // Destello de obturador al capturar RAW
                            if engine.flashEffect {
                                RoundedRectangle(cornerRadius: 24, style: .continuous)
                                    .fill(Color.white.opacity(0.6))
                                    .frame(width: fitW, height: fitH)
                                    .allowsHitTesting(false)
                            }

                            // Retícula de enfoque Liquid Glass al tocar
                            if let pt = engine.focusTapPoint {
                                focusGlassOrb
                                    .position(pt)
                                    .onAppear {
                                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.3) {
                                            withAnimation(.easeOut(duration: 0.25)) {
                                                engine.focusTapPoint = nil
                                            }
                                        }
                                    }
                            }

                            // Overlay de Masterización 8K / 6K sin pérdida de FPS
                            if engine.isMasteringVideo {
                                masteringGlassOverlay
                            }

                            // Píldora flotante de Lentes (0.5x • 1x • 2x) en vidrio líquido
                            VStack {
                                Spacer()
                                lensLiquidGlassDock
                                    .padding(.bottom, 12)
                            }
                            .frame(width: fitW, height: fitH)
                        }
                        .frame(width: fitW, height: fitH)
                        .animation(.spring(response: 0.32, dampingFraction: 0.82), value: engine.viewfinderPortraitAspect)
                    }
                    .frame(width: availW, height: availH)
                }
                .padding(.horizontal, 8)

                // 3. Barra de Resolución (8K / 6K / 4.3K) y Cadencia (24 / 30 / 60 FPS) en modos de video
                if engine.mode != .rawPhoto {
                    videoResolutionAndFPSGlassBar
                        .padding(.horizontal, 12)
                        .transition(.opacity.combined(with: .move(edge: .bottom)))
                }

                // 4. Cajón Desplegable Liquid Glass para ISO / Obturador / Enfoque Manual
                if activeDrawer != .none {
                    fineControlGlassDrawer
                        .padding(.horizontal, 12)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }

                // 5. Panel Inferior Liquid Glass (Controles Manuales + Modos + Obturador de Cristal)
                VStack(spacing: 10) {
                    quickGlassControlsRow
                    modeSelectorGlassBar
                    bottomShutterGlassDeck
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .liquidGlass(cornerRadius: 28, tint: accentColor, highlighted: false)
                .padding(.horizontal, 10)
                .padding(.bottom, 4)
            }
        }
        .preferredColorScheme(.dark)
        .sheet(isPresented: $showShareSheet) {
            if let url = engine.lastCapturedFileURL {
                ShareSheetView(items: [url])
            }
        }
    }

    // MARK: - 1. HUD Superior Liquid Glass
    private var topLiquidGlassHUD: some View {
        VStack(spacing: 5) {
            HStack(spacing: 8) {
                // Pastilla brillante del modo activo
                HStack(spacing: 5) {
                    Circle()
                        .fill(engine.isRecording ? Color.red : Color.black)
                        .frame(width: 6.5, height: 6.5)
                    Text(engine.mode.rawValue)
                        .font(.system(size: 10.5, weight: .black, design: .rounded))
                        .foregroundColor(.black)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 4.5)
                .background(
                    LinearGradient(
                        colors: [Color.white, accentColor],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .clipShape(Capsule())

                Text(engine.activeSensorFormatText)
                    .font(.system(size: 10.5, weight: .bold, design: .monospaced))
                    .foregroundColor(.white.opacity(0.95))
                    .lineLimit(1)
                    .minimumScaleFactor(0.72)

                Spacer()

                // Histograma cáustico en vivo
                HStack(alignment: .bottom, spacing: 1.4) {
                    ForEach(Array(engine.histogramBins.enumerated()), id: \.offset) { _, val in
                        RoundedRectangle(cornerRadius: 1)
                            .fill(
                                LinearGradient(
                                    colors: [ Color.white, accentColor.opacity(0.8) ],
                                    startPoint: .top,
                                    endPoint: .bottom
                                )
                            )
                            .frame(width: 2.0, height: max(2, CGFloat(val) * 20))
                    }
                }
                .frame(height: 22)
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background(Color.black.opacity(0.35))
                .clipShape(Capsule())
            }

            HStack(spacing: 8) {
                Text(engine.statusBanner)
                    .font(.system(size: 10, weight: .medium, design: .rounded))
                    .foregroundColor(.white.opacity(0.82))
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)

                Spacer()

                // Medidor de FPS reales
                HStack(spacing: 4) {
                    Circle()
                        .fill(engine.measuredFPS >= 23 ? Color.green : Color.orange)
                        .frame(width: 6, height: 6)
                    Text(String(format: "%.0f FPS", engine.measuredFPS))
                        .font(.system(size: 10, weight: .black, design: .monospaced))
                        .foregroundColor(.white)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(Color.white.opacity(0.10))
                .clipShape(Capsule())
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .liquidGlass(cornerRadius: 20, tint: accentColor, highlighted: engine.isRecording)
    }

    // MARK: - 2. Marco de Cristal del Visor y Guías
    private func viewfinderGlassOverlay(width: CGFloat, height: CGFloat) -> some View {
        ZStack {
            if engine.showGridLines {
                Path { p in
                    p.move(to: CGPoint(x: width / 3, y: 0))
                    p.addLine(to: CGPoint(x: width / 3, y: height))
                    p.move(to: CGPoint(x: 2 * width / 3, y: 0))
                    p.addLine(to: CGPoint(x: 2 * width / 3, y: height))
                    p.move(to: CGPoint(x: 0, y: height / 3))
                    p.addLine(to: CGPoint(x: width, y: height / 3))
                    p.move(to: CGPoint(x: 0, y: 2 * height / 3))
                    p.addLine(to: CGPoint(x: width, y: 2 * height / 3))
                }
                .stroke(Color.white.opacity(0.22), lineWidth: 0.65)
            }

            // Borde especular Liquid Glass alrededor del área exacta capturada
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .strokeBorder(
                    LinearGradient(
                        colors: [
                            engine.isRecording ? Color.red : Color.white.opacity(0.75),
                            accentColor.opacity(0.35),
                            Color.white.opacity(0.15),
                            engine.isRecording ? Color.red : accentColor.opacity(0.65)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: engine.isRecording ? 2.2 : 1.3
                )

            // Píldora superior de proporción real dentro del visor
            VStack {
                HStack {
                    Text(engine.mode == .videoFluid ? "ENCUADRE 9:16 VERTICAL EXACTO" : "ENCUADRE 3:4 SENSOR COMPLETO")
                        .font(.system(size: 9.5, weight: .bold, design: .monospaced))
                        .foregroundColor(.white)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 4)
                        .liquidGlass(cornerRadius: 12, tint: accentColor, highlighted: false)
                    Spacer()
                }
                .padding(10)
                Spacer()
            }
        }
        .frame(width: width, height: height)
        .allowsHitTesting(false)
    }

    private var focusGlassOrb: some View {
        ZStack {
            Circle()
                .fill(Color.white.opacity(0.12))
                .frame(width: 68, height: 68)
                .liquidGlass(cornerRadius: 34, tint: .yellow, highlighted: true)
            Circle()
                .fill(Color.yellow)
                .frame(width: 6, height: 6)
        }
    }

    private var masteringGlassOverlay: some View {
        VStack(spacing: 10) {
            ProgressView(value: engine.masteringProgress, total: 1.0)
                .progressViewStyle(.linear)
                .tint(accentColor)
                .frame(width: 190)
            Text(String(format: "MASTERIZANDO %@ SIN PÉRDIDA: %.0f%%", engine.resolutionTier.rawValue, engine.masteringProgress * 100))
                .font(.system(size: 10.5, weight: .black, design: .monospaced))
                .foregroundColor(.white)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
        .liquidGlass(cornerRadius: 20, tint: accentColor, highlighted: true)
    }

    // MARK: - Píldora Flotante Liquid Glass de Lentes (0.5x • 1x • 2x)
    private var lensLiquidGlassDock: some View {
        HStack(spacing: 8) {
            ForEach(LensChoice.allCases) { l in
                let isSelected = (engine.lens == l)
                Button {
                    guard !engine.isRecording, !engine.isMasteringVideo else { return }
                    UIImpactFeedbackGenerator(style: .rigid).impactOccurred()
                    withAnimation(.spring(response: 0.26, dampingFraction: 0.74)) {
                        engine.lens = l
                    }
                } label: {
                    Text(l.rawValue)
                        .font(.system(size: 12, weight: .black, design: .rounded))
                        .foregroundColor(isSelected ? .black : .white)
                        .frame(width: isSelected ? 46 : 38, height: 34)
                        .background(
                            Group {
                                if isSelected {
                                    LinearGradient(
                                        colors: [Color.white, accentColor],
                                        startPoint: .topLeading,
                                        endPoint: .bottomTrailing
                                    )
                                } else {
                                    Color.white.opacity(0.08)
                                }
                            }
                        )
                        .clipShape(Capsule())
                }
            }
        }
        .padding(5)
        .liquidGlass(cornerRadius: 24, tint: accentColor, highlighted: false)
    }

    // MARK: - 3. Barra Liquid Glass de Resolución (8K / 6K / 4.3K) y FPS (24 / 30 / 60)
    private var videoResolutionAndFPSGlassBar: some View {
        HStack(spacing: 8) {
            // Selector de Resolución: 8K UHD | 6K PRO | 4.3K DIRECTO
            HStack(spacing: 4) {
                ForEach(VideoResolutionTier.allCases) { tier in
                    let active = (engine.resolutionTier == tier)
                    Button {
                        guard !engine.isRecording, !engine.isMasteringVideo else { return }
                        UIImpactFeedbackGenerator(style: .light).impactOccurred()
                        withAnimation(.spring(response: 0.24, dampingFraction: 0.78)) {
                            engine.resolutionTier = tier
                        }
                    } label: {
                        Text(tier.rawValue)
                            .font(.system(size: 9.5, weight: .black, design: .monospaced))
                            .foregroundColor(active ? .black : .white.opacity(0.9))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 6)
                            .background(
                                active
                                    ? AnyShapeStyle(LinearGradient(colors: [Color.white, accentColor], startPoint: .topLeading, endPoint: .bottomTrailing))
                                    : AnyShapeStyle(Color.white.opacity(0.06))
                            )
                            .clipShape(Capsule())
                    }
                }
            }
            .padding(3)
            .liquidGlass(cornerRadius: 18, tint: accentColor, highlighted: false)

            Spacer(minLength: 4)

            // Selector de FPS: 24 | 30 | 60 (disponible en TODOS los modos de video)
            HStack(spacing: 4) {
                ForEach(fpsOptions, id: \.self) { fps in
                    let active = (engine.targetFPS == fps)
                    Button {
                        guard !engine.isRecording, !engine.isMasteringVideo else { return }
                        UIImpactFeedbackGenerator(style: .light).impactOccurred()
                        withAnimation(.spring(response: 0.24, dampingFraction: 0.78)) {
                            engine.targetFPS = fps
                        }
                    } label: {
                        Text("\(fps)")
                            .font(.system(size: 10.5, weight: .black, design: .monospaced))
                            .foregroundColor(active ? .black : .white.opacity(0.9))
                            .padding(.horizontal, 9)
                            .padding(.vertical, 6)
                            .background(
                                active
                                    ? AnyShapeStyle(LinearGradient(colors: [Color.white, accentColor], startPoint: .topLeading, endPoint: .bottomTrailing))
                                    : AnyShapeStyle(Color.white.opacity(0.06))
                            )
                            .clipShape(Capsule())
                    }
                }
            }
            .padding(3)
            .liquidGlass(cornerRadius: 18, tint: accentColor, highlighted: false)
        }
    }

    // MARK: - 4. Tira de Píldoras Manuales Liquid Glass
    private var quickGlassControlsRow: some View {
        HStack(spacing: 8) {
            Button {
                withAnimation(.spring(response: 0.26, dampingFraction: 0.8)) {
                    activeDrawer = (activeDrawer == .exposure) ? .none : .exposure
                }
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "dial.medium.fill")
                        .font(.system(size: 11))
                    Text(engine.manualExposure ? "ISO \(Int(engine.isoValue))" : "EXP AUTO")
                        .font(.system(size: 10.5, weight: .bold, design: .monospaced))
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6.5)
                .liquidGlass(cornerRadius: 16, tint: .yellow, highlighted: activeDrawer == .exposure || engine.manualExposure)
                .foregroundColor(.white)
            }

            Button {
                withAnimation(.spring(response: 0.26, dampingFraction: 0.8)) {
                    activeDrawer = (activeDrawer == .focus) ? .none : .focus
                }
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "scope")
                        .font(.system(size: 11))
                    Text(engine.manualFocus ? String(format: "MF %.2f", engine.focusPosition) : "AF")
                        .font(.system(size: 10.5, weight: .bold, design: .monospaced))
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6.5)
                .liquidGlass(cornerRadius: 16, tint: .cyan, highlighted: activeDrawer == .focus || engine.manualFocus)
                .foregroundColor(.white)
            }

            Spacer()

            Button {
                engine.showGridLines.toggle()
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "grid")
                        .font(.system(size: 11))
                    Text("GUÍAS")
                        .font(.system(size: 10.5, weight: .bold, design: .monospaced))
                }
                .padding(.horizontal, 11)
                .padding(.vertical, 6.5)
                .liquidGlass(cornerRadius: 16, tint: .white, highlighted: engine.showGridLines)
                .foregroundColor(.white)
            }
        }
    }

    // MARK: - Cajón Desplegable Liquid Glass (ISO / Obturación / Enfoque)
    private var fineControlGlassDrawer: some View {
        VStack(spacing: 8) {
            if activeDrawer == .exposure {
                HStack {
                    Toggle("EXPOSICIÓN MANUAL", isOn: $engine.manualExposure)
                        .font(.system(size: 11, weight: .bold, design: .monospaced))
                        .tint(.yellow)
                        .onChange(of: engine.manualExposure) { _ in engine.applyExposureSettings() }

                    Spacer()
                    if engine.manualExposure {
                        Text("ISO \(Int(engine.isoValue))")
                            .font(.system(size: 11, weight: .black, design: .monospaced))
                            .foregroundColor(.yellow)
                    }
                }

                if engine.manualExposure {
                    Slider(value: $engine.isoValue, in: engine.minISO...engine.maxISO) { _ in
                        engine.applyExposureSettings()
                    }
                    .tint(.yellow)

                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 6) {
                            ForEach(shutterPresets, id: \.0) { label, sec in
                                let active = abs(engine.shutterSeconds - sec) < 0.0001
                                Button(label) {
                                    engine.shutterSeconds = sec
                                    engine.applyExposureSettings()
                                }
                                .font(.system(size: 10.5, weight: .bold, design: .monospaced))
                                .padding(.horizontal, 9)
                                .padding(.vertical, 5)
                                .background(active ? Color.yellow : Color.white.opacity(0.12))
                                .foregroundColor(active ? .black : .white)
                                .clipShape(Capsule())
                            }
                        }
                    }
                }
            } else if activeDrawer == .focus {
                HStack {
                    Toggle("ENFOQUE MANUAL", isOn: $engine.manualFocus)
                        .font(.system(size: 11, weight: .bold, design: .monospaced))
                        .tint(.cyan)
                        .onChange(of: engine.manualFocus) { _ in engine.applyFocusSettings() }

                    Spacer()
                    if engine.manualFocus {
                        Text(String(format: "LENTE %.2f", engine.focusPosition))
                            .font(.system(size: 11, weight: .black, design: .monospaced))
                            .foregroundColor(.cyan)
                    }
                }

                if engine.manualFocus {
                    Slider(value: $engine.focusPosition, in: 0.0...1.0) { _ in
                        engine.applyFocusSettings()
                    }
                    .tint(.cyan)
                }
            }
        }
        .padding(12)
        .liquidGlass(cornerRadius: 20, tint: accentColor, highlighted: true)
    }

    // MARK: - 5. Selector de Modos en Vidrio Líquido
    private var modeSelectorGlassBar: some View {
        HStack(spacing: 6) {
            ForEach(CaptureMode.allCases) { m in
                let selected = (engine.mode == m)
                Button {
                    guard !engine.isRecording, !engine.isMasteringVideo else { return }
                    UIImpactFeedbackGenerator(style: .soft).impactOccurred()
                    withAnimation(.spring(response: 0.26, dampingFraction: 0.78)) {
                        engine.mode = m
                    }
                } label: {
                    Text(m.rawValue)
                        .font(.system(size: 11, weight: .black, design: .rounded))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 7)
                        .background(
                            Group {
                                if selected {
                                    LinearGradient(
                                        colors: [Color.white, accentColor],
                                        startPoint: .topLeading,
                                        endPoint: .bottomTrailing
                                    )
                                } else {
                                    Color.white.opacity(0.06)
                                }
                            }
                        )
                        .foregroundColor(selected ? .black : .white.opacity(0.88))
                        .clipShape(Capsule())
                }
            }
        }
    }

    // MARK: - 6. Cubierta Inferior con Obturador "Liquid Glass Orb"
    private var bottomShutterGlassDeck: some View {
        HStack {
            // Botón de última captura / Compartir .DNG o .MOV
            Button {
                if engine.lastCapturedFileURL != nil {
                    showShareSheet = true
                }
            } label: {
                HStack(spacing: 8) {
                    if let thumb = engine.lastThumbnail {
                        Image(uiImage: thumb)
                            .resizable()
                            .scaledToFill()
                            .frame(width: 44, height: 44)
                            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                            .overlay(
                                RoundedRectangle(cornerRadius: 12, style: .continuous)
                                    .stroke(Color.white.opacity(0.7), lineWidth: 1.2)
                            )
                    } else {
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(Color.white.opacity(0.08))
                            .frame(width: 44, height: 44)
                            .overlay(
                                Image(systemName: "square.and.arrow.up")
                                    .font(.system(size: 16, weight: .bold))
                                    .foregroundColor(.white.opacity(0.75))
                            )
                    }

                    VStack(alignment: .leading, spacing: 2) {
                        Text("EXPORTAR")
                            .font(.system(size: 9.5, weight: .black, design: .rounded))
                            .foregroundColor(.white)
                        Text(".DNG / MOV")
                            .font(.system(size: 8.5, weight: .bold, design: .monospaced))
                            .foregroundColor(accentColor)
                    }
                }
            }
            .frame(width: 115, alignment: .leading)

            Spacer()

            // Botón de Obturador Liquid Glass (Disco refractivo estilo Vidrio.tendies)
            Button {
                engine.triggerPrimaryAction()
            } label: {
                ZStack {
                    // Anillo exterior de cristal líquido con reflejo especular
                    Circle()
                        .fill(.ultraThinMaterial)
                        .frame(width: 76, height: 76)
                        .overlay(
                            Circle()
                                .strokeBorder(
                                    LinearGradient(
                                        colors: [
                                            Color.white.opacity(0.95),
                                            accentColor.opacity(0.65),
                                            Color.white.opacity(0.20)
                                        ],
                                        startPoint: .topLeading,
                                        endPoint: .bottomTrailing
                                    ),
                                    lineWidth: 3.0
                                )
                        )
                        .shadow(color: accentColor.opacity(0.38), radius: 12, x: 0, y: 4)

                    if engine.mode == .rawPhoto {
                        Circle()
                            .fill(
                                LinearGradient(
                                    colors: [Color.white, accentColor.opacity(0.85)],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                )
                            )
                            .frame(width: 58, height: 58)
                    } else {
                        RoundedRectangle(cornerRadius: engine.isRecording ? 10 : 29, style: .continuous)
                            .fill(
                                LinearGradient(
                                    colors: [Color(red: 1.0, green: 0.28, blue: 0.32), Color(red: 0.82, green: 0.05, blue: 0.15)],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                )
                            )
                            .frame(
                                width: engine.isRecording ? 32 : 58,
                                height: engine.isRecording ? 32 : 58
                            )
                            .animation(.spring(response: 0.25, dampingFraction: 0.7), value: engine.isRecording)
                    }
                }
            }

            Spacer()

            // Telemetría derecha
            VStack(alignment: .trailing, spacing: 3) {
                if engine.isRecording {
                    Text(String(format: "%02d:%02d", Int(engine.recordingElapsedSeconds) / 60, Int(engine.recordingElapsedSeconds) % 60))
                        .font(.system(size: 15, weight: .black, design: .monospaced))
                        .foregroundColor(.red)
                    Text("\(engine.recordedFramesCount) CUADROS")
                        .font(.system(size: 9.5, weight: .bold, design: .monospaced))
                        .foregroundColor(.white)
                } else {
                    Text(engine.mode == .rawPhoto ? "48 MP RAW" : engine.resolutionTier.rawValue)
                        .font(.system(size: 11.5, weight: .black, design: .rounded))
                        .foregroundColor(.white)
                    Text(engine.mode == .rawPhoto ? "PRO DNG" : "\(engine.targetFPS) FPS REALES")
                        .font(.system(size: 9, weight: .bold, design: .monospaced))
                        .foregroundColor(accentColor)
                }
            }
            .frame(width: 115, alignment: .trailing)
        }
    }

    private var accentColor: Color {
        switch engine.mode {
        case .rawPhoto: return Color(red: 1.0, green: 0.84, blue: 0.28)
        case .videoFluid: return Color(red: 0.25, green: 0.90, blue: 1.0)
        case .videoOpenGate: return Color(red: 0.72, green: 0.52, blue: 1.0)
        }
    }
}
