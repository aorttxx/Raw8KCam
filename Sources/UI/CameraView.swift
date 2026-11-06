import AVFoundation
import SwiftUI

struct CameraPreviewView: UIViewRepresentable {
    let session: AVCaptureSession

    final class VideoPreviewUIView: UIView {
        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
    }

    func makeUIView(context: Context) -> VideoPreviewUIView {
        let v = VideoPreviewUIView()
        v.backgroundColor = .black
        v.previewLayer.session = session
        v.previewLayer.videoGravity = .resizeAspectFill
        return v
    }

    func updateUIView(_ uiView: VideoPreviewUIView, context: Context) {}
}

struct CameraView: View {
    @StateObject private var engine = CameraEngine()

    private let shutterPresets: [(String, Double)] = [
        ("1/2000", 1.0 / 2000.0),
        ("1/500", 1.0 / 500.0),
        ("1/120", 1.0 / 120.0),
        ("1/60", 1.0 / 60.0),
        ("1/30", 1.0 / 30.0),
        ("1/15", 1.0 / 15.0),
        ("1/4", 1.0 / 4.0)
    ]

    var body: some View {
        ZStack {
            // Visor de cámara a pantalla completa
            CameraPreviewView(session: engine.session)
                .ignoresSafeArea()

            // Retícula óptica 8K / 16:9
            GeometryReader { geo in
                ZStack {
                    Path { p in
                        let w = geo.size.width
                        let h = geo.size.height
                        p.move(to: CGPoint(x: w / 3, y: 0))
                        p.addLine(to: CGPoint(x: w / 3, y: h))
                        p.move(to: CGPoint(x: 2 * w / 3, y: 0))
                        p.addLine(to: CGPoint(x: 2 * w / 3, y: h))
                        p.move(to: CGPoint(x: 0, y: h / 3))
                        p.addLine(to: CGPoint(x: w, y: h / 3))
                        p.move(to: CGPoint(x: 0, y: 2 * h / 3))
                        p.addLine(to: CGPoint(x: w, y: 2 * h / 3))
                    }
                    .stroke(Color.white.opacity(0.16), lineWidth: 0.7)
                }
            }
            .ignoresSafeArea()
            .allowsHitTesting(false)

            VStack(spacing: 12) {
                // HUD Superior (Telemetría + Histograma en vivo)
                topHUD

                Spacer()

                // Panel de Controles Manuales (ISO, Obturador, Enfoque, Opciones 8K)
                manualControlsPanel

                // Selector de los 3 Modos (RAW .DNG | 8K FLUIDO | 8K 48MP PURO)
                modeSelectorBar

                // Barra Inferior: Selector de Lente + Botón Disparador + Contador
                bottomShutterBar
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
        }
    }

    // MARK: - HUD Superior
    private var topHUD: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                Text(engine.mode.rawValue)
                    .font(.system(size: 12, weight: .black, design: .monospaced))
                    .foregroundColor(.black)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(badgeColor)
                    .clipShape(Capsule())

                Text(engine.activeSensorFormatText)
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundColor(.white.opacity(0.92))
                    .lineLimit(1)

                Spacer()

                // Histograma de luminancia en tiempo real
                HStack(alignment: .bottom, spacing: 1.5) {
                    ForEach(Array(engine.histogramBins.enumerated()), id: \.offset) { _, val in
                        RoundedRectangle(cornerRadius: 1)
                            .fill(Color.cyan.opacity(0.85))
                            .frame(width: 2.2, height: max(2, CGFloat(val) * 26))
                    }
                }
                .frame(height: 28)
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(Color.black.opacity(0.55))
                .clipShape(RoundedRectangle(cornerRadius: 6))
            }

            HStack {
                Circle()
                    .fill(engine.isRecording ? Color.red : Color.green)
                    .frame(width: 8, height: 8)
                Text(engine.statusBanner)
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundColor(.white.opacity(0.85))
                Spacer()
                Text(String(format: "%.0f FPS", engine.measuredFPS))
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                    .foregroundColor(.yellow)
            }
        }
        .padding(10)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 14))
    }

    // MARK: - Controles Manuales (ISO / Obturación / Enfoque / Opciones de Modo)
    private var manualControlsPanel: some View {
        VStack(spacing: 10) {
            if engine.mode == .video8KFluid {
                HStack {
                    Text("CADENCIA 8K OPEN GATE:")
                        .font(.system(size: 11, weight: .bold, design: .monospaced))
                        .foregroundColor(.white.opacity(0.8))
                    Spacer()
                    Picker("FPS", selection: $engine.targetFPS) {
                        Text("30 FPS").tag(30)
                        Text("60 FPS").tag(60)
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 160)
                }
            } else if engine.mode == .video8KSensor48MP {
                Toggle(isOn: $engine.isTimelapsePacing48MP) {
                    Text("Empaquetar ráfaga 48MP a 30fps (Hyperlapse 8K)")
                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                        .foregroundColor(.orange)
                }
                .tint(.orange)
            }

            // Exposición Manual (ISO + Velocidad)
            VStack(spacing: 6) {
                HStack {
                    Toggle("EXPOSICIÓN MANUAL", isOn: $engine.manualExposure)
                        .font(.system(size: 11, weight: .bold, design: .monospaced))
                        .tint(.yellow)
                        .onChange(of: engine.manualExposure) { _ in engine.applyExposureSettings() }

                    if engine.manualExposure {
                        Text("ISO \(Int(engine.isoValue))")
                            .font(.system(size: 11, weight: .bold, design: .monospaced))
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
                                .font(.system(size: 11, weight: .bold, design: .monospaced))
                                .padding(.horizontal, 9)
                                .padding(.vertical, 5)
                                .background(active ? Color.yellow : Color.white.opacity(0.12))
                                .foregroundColor(active ? .black : .white)
                                .clipShape(Capsule())
                            }
                        }
                    }
                }
            }

            // Enfoque Manual
            VStack(spacing: 6) {
                HStack {
                    Toggle("ENFOQUE MANUAL", isOn: $engine.manualFocus)
                        .font(.system(size: 11, weight: .bold, design: .monospaced))
                        .tint(.cyan)
                        .onChange(of: engine.manualFocus) { _ in engine.applyFocusSettings() }

                    if engine.manualFocus {
                        Text(String(format: "LENTE %.2f", engine.focusPosition))
                            .font(.system(size: 11, weight: .bold, design: .monospaced))
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
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 16))
    }

    // MARK: - Barra Selectora de los 3 Modos
    private var modeSelectorBar: some View {
        VStack(spacing: 4) {
            HStack(spacing: 8) {
                ForEach(CaptureMode.allCases) { m in
                    let selected = (engine.mode == m)
                    Button {
                        guard !engine.isRecording else { return }
                        withAnimation(.easeInOut(duration: 0.2)) {
                            engine.mode = m
                        }
                    } label: {
                        Text(m.rawValue)
                            .font(.system(size: 12, weight: .heavy, design: .monospaced))
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .background(selected ? badgeColor : Color.black.opacity(0.55))
                            .foregroundColor(selected ? .black : .white)
                            .clipShape(Capsule())
                    }
                }
            }
            Text(engine.mode.subtitle)
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .foregroundColor(.white.opacity(0.75))
                .multilineTextAlignment(.center)
        }
    }

    // MARK: - Barra Inferior de Lentes y Disparador
    private var bottomShutterBar: some View {
        HStack {
            // Selector de lente físico (1x 48MP vs 0.5x)
            VStack(alignment: .leading, spacing: 4) {
                ForEach(LensChoice.allCases) { l in
                    let active = (engine.lens == l)
                    Button {
                        guard !engine.isRecording else { return }
                        engine.lens = l
                    } label: {
                        Text(l.rawValue)
                            .font(.system(size: 11, weight: .bold, design: .monospaced))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(active ? Color.white : Color.black.opacity(0.6))
                            .foregroundColor(active ? .black : .white)
                            .clipShape(Capsule())
                    }
                }
            }
            .frame(width: 125, alignment: .leading)

            Spacer()

            // Botón de Obturador / Grabación 8K
            Button {
                engine.triggerPrimaryAction()
            } label: {
                ZStack {
                    Circle()
                        .strokeBorder(Color.white, lineWidth: 4)
                        .frame(width: 78, height: 78)

                    if engine.mode == .rawPhoto {
                        Circle()
                            .fill(engine.isCapturingPhoto ? Color.yellow : Color.white)
                            .frame(width: 64, height: 64)
                    } else {
                        RoundedRectangle(cornerRadius: engine.isRecording ? 8 : 32)
                            .fill(Color.red)
                            .frame(
                                width: engine.isRecording ? 34 : 64,
                                height: engine.isRecording ? 34 : 64
                            )
                            .animation(.spring(response: 0.25, dampingFraction: 0.7), value: engine.isRecording)
                    }
                }
            }

            Spacer()

            // Telemetría de grabación 8K
            VStack(alignment: .trailing, spacing: 4) {
                if engine.isRecording {
                    Text(String(format: "%02d:%02d", Int(engine.recordingElapsedSeconds) / 60, Int(engine.recordingElapsedSeconds) % 60))
                        .font(.system(size: 15, weight: .black, design: .monospaced))
                        .foregroundColor(.red)
                    Text("\(engine.recordedFramesCount) f • 8K")
                        .font(.system(size: 11, weight: .bold, design: .monospaced))
                        .foregroundColor(.white)
                } else {
                    Text("7680×4320")
                        .font(.system(size: 12, weight: .bold, design: .monospaced))
                        .foregroundColor(.cyan)
                    Text("HEVC 120M")
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                        .foregroundColor(.white.opacity(0.7))
                }
            }
            .frame(width: 125, alignment: .trailing)
        }
        .padding(.bottom, 6)
    }

    private var badgeColor: Color {
        switch engine.mode {
        case .rawPhoto: return .yellow
        case .video8KFluid: return .cyan
        case .video8KSensor48MP: return .orange
        }
    }
}
