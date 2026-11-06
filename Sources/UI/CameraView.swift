import AVFoundation
import SwiftUI
import UIKit

// MARK: - Visor Nativo AVCaptureVideoPreviewLayer (Soporta 100% Sensor Completo o Pantalla Llena)
struct CameraPreviewView: UIViewRepresentable {
    let session: AVCaptureSession
    let showFullSensorFrame: Bool
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
        v.previewLayer.videoGravity = showFullSensorFrame ? .resizeAspect : .resizeAspectFill
        let tap = UITapGestureRecognizer(target: v, action: #selector(VideoPreviewUIView.handleTap(_:)))
        v.addGestureRecognizer(tap)
        v.tapHandler = onTapFocus
        return v
    }

    func updateUIView(_ uiView: VideoPreviewUIView, context: Context) {
        let targetGravity: AVLayerVideoGravity = showFullSensorFrame ? .resizeAspect : .resizeAspectFill
        if uiView.previewLayer.videoGravity != targetGravity {
            CATransaction.begin()
            CATransaction.setAnimationDuration(0.22)
            uiView.previewLayer.videoGravity = targetGravity
            CATransaction.commit()
        }
        uiView.tapHandler = onTapFocus
    }
}

// MARK: - Hoja Nativa de Compartir (.DNG / .MOV 8K)
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
            Color.black.ignoresSafeArea()

            VStack(spacing: 0) {
                // 1. Barra Superior Pro (Telemetría + Histograma + Conmutador 100% Sensor)
                topProBar
                    .padding(.horizontal, 12)
                    .padding(.top, 4)
                    .padding(.bottom, 6)

                // 2. Visor de Cámara con Marco de Sensor Completo (4:3 o 16:9) sin recortar
                ZStack {
                    CameraPreviewView(
                        session: engine.session,
                        showFullSensorFrame: engine.showFullSensorFrame
                    ) { devPt, viewPt in
                        engine.focusAndExpose(at: devPt, viewPoint: viewPt)
                    }
                    .clipShape(RoundedRectangle(cornerRadius: engine.showFullSensorFrame ? 14 : 0))

                    // Guías ópticas de encuadre y esquinas de cine
                    viewfinderOverlay

                    // Efecto de obturador al disparar RAW
                    if engine.flashEffect {
                        Color.white.opacity(0.65)
                            .allowsHitTesting(false)
                            .transition(.opacity)
                    }

                    // Retícula animada Tap-to-Focus
                    if let pt = engine.focusTapPoint {
                        focusReticleView
                            .position(pt)
                            .onAppear {
                                DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) {
                                    withAnimation(.easeOut(duration: 0.25)) {
                                        engine.focusTapPoint = nil
                                    }
                                }
                            }
                    }

                    // Píldora flotante de Lentes (0.5x | 1x 48M | 2x) en la base del visor
                    VStack {
                        Spacer()
                        lensFloatingPill
                            .padding(.bottom, 12)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(.horizontal, engine.showFullSensorFrame ? 6 : 0)

                // 3. Panel Desplegable de Ajuste Fino (solo visible cuando se toca ISO/VEL o FOCUS)
                if activeDrawer != .none {
                    fineControlDrawer
                        .padding(.horizontal, 12)
                        .padding(.top, 6)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }

                // 4. Barra de Dials Rápidos + Selector de Modo + Disparador Pro
                VStack(spacing: 10) {
                    quickDialStrip
                    modeSelectorBar
                    bottomShutterDeck
                }
                .padding(.horizontal, 14)
                .padding(.top, 8)
                .padding(.bottom, 8)
                .background(
                    LinearGradient(
                        colors: [Color.black.opacity(0.95), Color.black],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
            }
        }
        .preferredColorScheme(.dark)
        .sheet(isPresented: $showShareSheet) {
            if let url = engine.lastCapturedFileURL {
                ShareSheetView(items: [url])
            }
        }
    }

    // MARK: - 1. Barra Superior Pro
    private var topProBar: some View {
        VStack(spacing: 6) {
            HStack(spacing: 8) {
                HStack(spacing: 5) {
                    Circle()
                        .fill(engine.isRecording ? Color.red : accentColor)
                        .frame(width: 7, height: 7)
                    Text(engine.mode.rawValue)
                        .font(.system(size: 11, weight: .black, design: .monospaced))
                        .foregroundColor(.black)
                }
                .padding(.horizontal, 9)
                .padding(.vertical, 4)
                .background(accentColor)
                .clipShape(Capsule())

                Text(engine.activeSensorFormatText)
                    .font(.system(size: 10.5, weight: .bold, design: .monospaced))
                    .foregroundColor(.white.opacity(0.92))
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)

                Spacer()

                // Histograma en vivo
                HStack(alignment: .bottom, spacing: 1.3) {
                    ForEach(Array(engine.histogramBins.enumerated()), id: \.offset) { _, val in
                        RoundedRectangle(cornerRadius: 0.8)
                            .fill(accentColor.opacity(0.9))
                            .frame(width: 2.0, height: max(2, CGFloat(val) * 22))
                    }
                }
                .frame(height: 24)
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(Color.white.opacity(0.08))
                .clipShape(RoundedRectangle(cornerRadius: 6))
            }

            HStack(spacing: 8) {
                Text(engine.statusBanner)
                    .font(.system(size: 10.5, weight: .medium, design: .monospaced))
                    .foregroundColor(.white.opacity(0.78))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)

                Spacer()

                Text(String(format: "%.0f FPS", engine.measuredFPS))
                    .font(.system(size: 10.5, weight: .heavy, design: .monospaced))
                    .foregroundColor(engine.measuredFPS >= 23 ? .green : .yellow)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(Color.white.opacity(0.1))
                    .clipShape(Capsule())

                Button {
                    withAnimation(.spring(response: 0.25, dampingFraction: 0.8)) {
                        engine.showFullSensorFrame.toggle()
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: engine.showFullSensorFrame ? "viewfinder" : "arrow.up.left.and.arrow.down.right")
                            .font(.system(size: 10, weight: .bold))
                        Text(engine.showFullSensorFrame ? "100% SENSOR" : "LLENAR")
                            .font(.system(size: 10, weight: .bold, design: .monospaced))
                    }
                    .foregroundColor(engine.showFullSensorFrame ? .black : .white)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3.5)
                    .background(engine.showFullSensorFrame ? Color.white : Color.white.opacity(0.15))
                    .clipShape(Capsule())
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(Color.white.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 14))
    }

    // MARK: - 2. Guías Ópticas y Marco del Sensor Completo
    private var viewfinderOverlay: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height
            let frameAspect = (engine.mode == .video8KFluid) ? (9.0 / 16.0) : (3.0 / 4.0)
            let boxHeight = min(h, w / frameAspect)
            let boxWidth = min(w, boxHeight * frameAspect)

            ZStack {
                if engine.showGridLines {
                    Path { p in
                        let x0 = (w - boxWidth) * 0.5
                        let y0 = (h - boxHeight) * 0.5
                        p.move(to: CGPoint(x: x0 + boxWidth / 3, y: y0))
                        p.addLine(to: CGPoint(x: x0 + boxWidth / 3, y: y0 + boxHeight))
                        p.move(to: CGPoint(x: x0 + 2 * boxWidth / 3, y: y0))
                        p.addLine(to: CGPoint(x: x0 + 2 * boxWidth / 3, y: y0 + boxHeight))
                        p.move(to: CGPoint(x: x0, y: y0 + boxHeight / 3))
                        p.addLine(to: CGPoint(x: x0 + boxWidth, y: y0 + boxHeight / 3))
                        p.move(to: CGPoint(x: x0, y: y0 + 2 * boxHeight / 3))
                        p.addLine(to: CGPoint(x: x0 + boxWidth, y: y0 + 2 * boxHeight / 3))
                    }
                    .stroke(Color.white.opacity(0.20), lineWidth: 0.6)
                }

                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(
                        engine.isRecording ? Color.red.opacity(0.85) : accentColor.opacity(0.55),
                        lineWidth: engine.isRecording ? 2.0 : 1.1
                    )
                    .frame(width: boxWidth, height: boxHeight)

                VStack {
                    HStack {
                        Text(engine.mode == .video8KFluid ? "9:16 VERTICAL • \(engine.resolutionTier.rawValue)" : "3:4 • SENSOR COMPLETO SIN RECORTE")
                            .font(.system(size: 9.5, weight: .bold, design: .monospaced))
                            .foregroundColor(accentColor)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 3)
                            .background(Color.black.opacity(0.65))
                            .clipShape(Capsule())
                        Spacer()
                    }
                    .padding(8)
                    Spacer()
                }
                .frame(width: boxWidth, height: boxHeight)
            }
            .frame(width: w, height: h)
        }
        .allowsHitTesting(false)
    }

    private var focusReticleView: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 4)
                .stroke(Color.yellow, lineWidth: 1.8)
                .frame(width: 68, height: 68)
            Circle()
                .fill(Color.yellow)
                .frame(width: 5, height: 5)
        }
    }

    // MARK: - Selector Flotante de Lentes (0.5x | 1x 48M | 2x)
    private var lensFloatingPill: some View {
        HStack(spacing: 6) {
            ForEach(LensChoice.allCases) { l in
                let isSelected = (engine.lens == l)
                Button {
                    guard !engine.isRecording else { return }
                    UIImpactFeedbackGenerator(style: .rigid).impactOccurred()
                    withAnimation(.spring(response: 0.25, dampingFraction: 0.75)) {
                        engine.lens = l
                    }
                } label: {
                    Text(l.rawValue)
                        .font(.system(size: 12, weight: .black, design: .monospaced))
                        .foregroundColor(isSelected ? .black : .white)
                        .padding(.horizontal, isSelected ? 13 : 10)
                        .padding(.vertical, 7)
                        .background(isSelected ? accentColor : Color.white.opacity(0.14))
                        .clipShape(Capsule())
                }
            }
        }
        .padding(5)
        .background(.ultraThinMaterial)
        .clipShape(Capsule())
    }

    // MARK: - 3. Tira de Píldoras Pro (8K/6K/4.3K + 24/30/60 FPS + Exposición + Enfoque + Guías)
    private var quickDialStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                if engine.mode != .rawPhoto {
                    // Selector directo 8K | 6K | 4.3K
                    ForEach(VideoResolutionTier.allCases) { tier in
                        let active = (engine.resolutionTier == tier)
                        Button {
                            guard !engine.isRecording else { return }
                            UIImpactFeedbackGenerator(style: .light).impactOccurred()
                            engine.resolutionTier = tier
                        } label: {
                            Text(tier.rawValue)
                                .font(.system(size: 11, weight: .black, design: .monospaced))
                                .padding(.horizontal, 10)
                                .padding(.vertical, 6)
                                .background(active ? accentColor : Color.white.opacity(0.1))
                                .foregroundColor(active ? .black : .white)
                                .clipShape(Capsule())
                        }
                    }

                    // Selector directo 24 | 30 | 60 FPS en cualquier modo de video
                    ForEach(fpsOptions, id: \.self) { fps in
                        let active = (engine.targetFPS == fps)
                        Button {
                            guard !engine.isRecording else { return }
                            UIImpactFeedbackGenerator(style: .light).impactOccurred()
                            engine.targetFPS = fps
                        } label: {
                            Text("\(fps) FPS")
                                .font(.system(size: 11, weight: .black, design: .monospaced))
                                .padding(.horizontal, 10)
                                .padding(.vertical, 6)
                                .background(active ? Color.white : Color.white.opacity(0.1))
                                .foregroundColor(active ? .black : .white)
                                .clipShape(Capsule())
                        }
                    }
                }

                // Píldora Exposición / ISO / Obturador
                Button {
                    withAnimation(.spring(response: 0.25, dampingFraction: 0.8)) {
                        activeDrawer = (activeDrawer == .exposure) ? .none : .exposure
                    }
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "dial.medium.fill")
                            .font(.system(size: 11))
                        Text(engine.manualExposure ? "M • ISO \(Int(engine.isoValue))" : "EXP AUTO")
                            .font(.system(size: 11, weight: .bold, design: .monospaced))
                    }
                    .padding(.horizontal, 11)
                    .padding(.vertical, 6)
                    .background(activeDrawer == .exposure || engine.manualExposure ? Color.yellow : Color.white.opacity(0.1))
                    .foregroundColor(activeDrawer == .exposure || engine.manualExposure ? .black : .white)
                    .clipShape(Capsule())
                }

                // Píldora Enfoque Manual / AF
                Button {
                    withAnimation(.spring(response: 0.25, dampingFraction: 0.8)) {
                        activeDrawer = (activeDrawer == .focus) ? .none : .focus
                    }
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "scope")
                            .font(.system(size: 11))
                        Text(engine.manualFocus ? String(format: "MF %.2f", engine.focusPosition) : "AF CONTINUO")
                            .font(.system(size: 11, weight: .bold, design: .monospaced))
                    }
                    .padding(.horizontal, 11)
                    .padding(.vertical, 6)
                    .background(activeDrawer == .focus || engine.manualFocus ? Color.cyan : Color.white.opacity(0.1))
                    .foregroundColor(activeDrawer == .focus || engine.manualFocus ? .black : .white)
                    .clipShape(Capsule())
                }

                // Píldora Rejilla
                Button {
                    engine.showGridLines.toggle()
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "grid")
                            .font(.system(size: 11))
                        Text("GUÍAS")
                            .font(.system(size: 11, weight: .bold, design: .monospaced))
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(engine.showGridLines ? Color.white.opacity(0.22) : Color.white.opacity(0.08))
                    .foregroundColor(.white)
                    .clipShape(Capsule())
                }
            }
        }
    }

    // MARK: - Cajón Desplegable de Exposición o Enfoque Manual
    private var fineControlDrawer: some View {
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
                    Toggle("ENFOQUE MANUAL (PEAKING)", isOn: $engine.manualFocus)
                        .font(.system(size: 11, weight: .bold, design: .monospaced))
                        .tint(.cyan)
                        .onChange(of: engine.manualFocus) { _ in engine.applyFocusSettings() }

                    Spacer()
                    if engine.manualFocus {
                        Text(String(format: "DISTANCIA %.2f", engine.focusPosition))
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
        .padding(10)
        .background(Color.white.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 14))
    }

    // MARK: - 4. Selector de los 3 Modos Principales
    private var modeSelectorBar: some View {
        VStack(spacing: 4) {
            HStack(spacing: 8) {
                ForEach(CaptureMode.allCases) { m in
                    let selected = (engine.mode == m)
                    Button {
                        guard !engine.isRecording else { return }
                        UIImpactFeedbackGenerator(style: .soft).impactOccurred()
                        withAnimation(.easeInOut(duration: 0.18)) {
                            engine.mode = m
                        }
                    } label: {
                        Text(m.rawValue)
                            .font(.system(size: 11.5, weight: .black, design: .monospaced))
                            .padding(.horizontal, 12)
                            .padding(.vertical, 7)
                            .background(selected ? accentColor : Color.white.opacity(0.08))
                            .foregroundColor(selected ? .black : .white.opacity(0.85))
                            .clipShape(Capsule())
                    }
                }
            }
            Text(engine.mode.subtitle)
                .font(.system(size: 9.5, weight: .medium, design: .monospaced))
                .foregroundColor(.white.opacity(0.65))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
    }

    // MARK: - 5. Cubierta Inferior: Miniatura / Exportar .DNG + Disparador Pro + Contador 8K
    private var bottomShutterDeck: some View {
        HStack {
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
                            .clipShape(RoundedRectangle(cornerRadius: 10))
                            .overlay(
                                RoundedRectangle(cornerRadius: 10)
                                    .stroke(accentColor, lineWidth: 1.5)
                            )
                    } else {
                        RoundedRectangle(cornerRadius: 10)
                            .fill(Color.white.opacity(0.1))
                            .frame(width: 44, height: 44)
                            .overlay(
                                Image(systemName: "square.and.arrow.up")
                                    .font(.system(size: 16, weight: .bold))
                                    .foregroundColor(.white.opacity(0.6))
                            )
                    }

                    VStack(alignment: .leading, spacing: 2) {
                        Text(engine.lastCapturedFileURL != nil ? "EXPORTAR" : "ARCHIVOS")
                            .font(.system(size: 9.5, weight: .black, design: .monospaced))
                            .foregroundColor(accentColor)
                        Text(".DNG / 8K")
                            .font(.system(size: 9, weight: .semibold, design: .monospaced))
                            .foregroundColor(.white.opacity(0.65))
                    }
                }
            }
            .frame(width: 118, alignment: .leading)

            Spacer()

            Button {
                engine.triggerPrimaryAction()
            } label: {
                ZStack {
                    Circle()
                        .strokeBorder(accentColor, lineWidth: 3.5)
                        .frame(width: 74, height: 74)

                    if engine.mode == .rawPhoto {
                        Circle()
                            .fill(engine.isCapturingPhoto ? Color.yellow : Color.white)
                            .frame(width: 60, height: 60)
                    } else {
                        RoundedRectangle(cornerRadius: engine.isRecording ? 8 : 30)
                            .fill(Color.red)
                            .frame(
                                width: engine.isRecording ? 32 : 60,
                                height: engine.isRecording ? 32 : 60
                            )
                            .animation(.spring(response: 0.24, dampingFraction: 0.72), value: engine.isRecording)
                    }
                }
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 3) {
                if engine.isRecording {
                    Text(String(format: "%02d:%02d", Int(engine.recordingElapsedSeconds) / 60, Int(engine.recordingElapsedSeconds) % 60))
                        .font(.system(size: 15, weight: .black, design: .monospaced))
                        .foregroundColor(.red)
                    Text("\(engine.recordedFramesCount) CUADROS")
                        .font(.system(size: 9.5, weight: .bold, design: .monospaced))
                        .foregroundColor(.white)
                } else {
                    Text(engine.mode == .rawPhoto ? "48 MP RAW" : "\(engine.resolutionTier.rawValue) • \(engine.targetFPS)F")
                        .font(.system(size: 11.5, weight: .black, design: .monospaced))
                        .foregroundColor(accentColor)
                    Text(engine.mode == .rawPhoto ? "SIN DEEP FUSION" : "HEVC HARDWARE")
                        .font(.system(size: 9, weight: .semibold, design: .monospaced))
                        .foregroundColor(.white.opacity(0.65))
                }
            }
            .frame(width: 118, alignment: .trailing)
        }
    }

    private var accentColor: Color {
        switch engine.mode {
        case .rawPhoto: return .yellow
        case .video8KFluid: return .cyan
        case .video8KSensor48MP: return .orange
        }
    }
}
