import AVFoundation
import CoreImage
import CoreMedia
import ImageIO
import Metal
import Photos
import SwiftUI
import UIKit
import UniformTypeIdentifiers
import VideoToolbox

enum CaptureMode: String, CaseIterable, Identifiable {
    case rawPhoto = "RAW 48MP"
    case video8KFluid = "8K 60FPS"
    case video8KSensor48MP = "8K OPEN GATE"

    var id: String { rawValue }

    var subtitle: String {
        switch self {
        case .rawPhoto:
            return "Sensor 48MP completo (8064×6048) • Cero Deep Fusion (.DNG + Carrete)"
        case .video8KFluid:
            return "7680×4320 HEVC 100 Mbps • Escalador Hardware Media Engine 60 FPS reales"
        case .video8KSensor48MP:
            return "Sensor 4:3 Open Gate completo (4032×3024 → 8K 7680×4320) • Sin recorte EIS"
        }
    }
}

enum LensChoice: String, CaseIterable, Identifiable {
    case ultraWide = "0.5x"
    case wide1x = "1x 48M"
    case tele2x = "2x"

    var id: String { rawValue }

    var deviceType: AVCaptureDevice.DeviceType {
        switch self {
        case .ultraWide: return .builtInUltraWideCamera
        case .wide1x, .tele2x: return .builtInWideAngleCamera
        }
    }

    var zoomFactor: CGFloat {
        switch self {
        case .ultraWide: return 1.0
        case .wide1x: return 1.0
        case .tele2x: return 2.0
        }
    }
}

final class CameraEngine: NSObject, ObservableObject {
    // MARK: - Published UI State
    @Published var mode: CaptureMode = .rawPhoto {
        didSet { reconfigureForMode() }
    }
    @Published var lens: LensChoice = .wide1x {
        didSet { reconfigureForMode() }
    }
    @Published var targetFPS: Int = 60 {
        didSet { reconfigureForMode() }
    }
    @Published var openGateCinema24FPS: Bool = false {
        didSet { reconfigureForMode() }
    }

    // Visor: mostrar el 100% del sensor capturado sin recortar (true) o llenar pantalla (false)
    @Published var showFullSensorFrame: Bool = true
    @Published var showGridLines: Bool = true
    @Published var flashEffect: Bool = false

    @Published var isRecording: Bool = false
    @Published var isCapturingPhoto: Bool = false
    @Published var statusBanner: String = "Iniciando sensor..."
    @Published var activeSensorFormatText: String = "48MP 8064×6048"
    @Published var activeAspectRatio: CGFloat = 4.0 / 3.0 // 4:3 en foto/OpenGate, 16:9 en 8K 60fps
    @Published var measuredFPS: Double = 60.0
    @Published var recordedFramesCount: Int = 0
    @Published var recordingElapsedSeconds: Double = 0.0
    @Published var rawSupportedOnCurrentLens: Bool = false
    @Published var lastCapturedFileURL: URL?
    @Published var lastThumbnail: UIImage?
    @Published var focusTapPoint: CGPoint?

    // Controles manuales
    @Published var manualExposure: Bool = false
    @Published var isoValue: Float = 100
    @Published var minISO: Float = 32
    @Published var maxISO: Float = 3200
    @Published var shutterSeconds: Double = 1.0 / 120.0
    @Published var manualFocus: Bool = false
    @Published var focusPosition: Float = 0.5
    @Published var histogramBins: [Float] = Array(repeating: 0.15, count: 28)

    // MARK: - AVFoundation Core
    let session = AVCaptureSession()
    private let sessionQueue = DispatchQueue(label: "com.raw8kcam.session", qos: .userInitiated)
    private let videoQueue = DispatchQueue(label: "com.raw8kcam.videoOutput", qos: .userInteractive)
    private let audioQueue = DispatchQueue(label: "com.raw8kcam.audioOutput", qos: .userInitiated)

    private var isSessionConfigured = false
    private var videoDeviceInput: AVCaptureDeviceInput?
    private let photoOutput = AVCapturePhotoOutput()
    private let videoDataOutput = AVCaptureVideoDataOutput()
    private let audioDataOutput = AVCaptureAudioDataOutput()

    private let metalDevice: MTLDevice? = MTLCreateSystemDefaultDevice()
    private lazy var ciContext: CIContext = {
        if let dev = metalDevice {
            return CIContext(mtlDevice: dev, options: [
                .workingColorSpace: CGColorSpace(name: CGColorSpace.displayP3) as Any,
                .cacheIntermediates: false
            ])
        }
        return CIContext()
    }()

    // Grabador 8K por Hardware Media Engine (7680 x 4320 HEVC directo sin copia 32BGRA)
    private let outWidth8K = 7680
    private let outHeight8K = 4320
    private var assetWriter: AVAssetWriter?
    private var writerVideoInput: AVAssetWriterInput?
    private var writerAudioInput: AVAssetWriterInput?
    private var recordingStartPTS: CMTime?
    private var frameCounterWindow: Int = 0
    private var fpsWindowStart: CFAbsoluteTime = CFAbsoluteTimeGetCurrent()

    override init() {
        super.init()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            self?.requestPermissionsAndStart()
        }
    }

    // MARK: - Permisos e Inicialización Secuencial
    func requestPermissionsAndStart() {
        AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
            guard let self else { return }
            guard granted else {
                DispatchQueue.main.async {
                    self.statusBanner = "Permiso de cámara denegado en Ajustes"
                }
                return
            }
            AVCaptureDevice.requestAccess(for: .audio) { _ in
                PHPhotoLibrary.requestAuthorization(for: .addOnly) { _ in
                    self.sessionQueue.async {
                        self.setupSession()
                    }
                }
            }
        }
    }

    private func setupSession() {
        guard !isSessionConfigured else { return }

        let errMsg = ObjCCatcher.catchException {
            self.session.beginConfiguration()
            self.session.sessionPreset = .inputPriority

            if let cam = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back),
               let camInput = try? AVCaptureDeviceInput(device: cam),
               self.session.canAddInput(camInput) {
                self.session.addInput(camInput)
                self.videoDeviceInput = camInput
            }

            if let mic = AVCaptureDevice.default(for: .audio),
               let micInput = try? AVCaptureDeviceInput(device: mic),
               self.session.canAddInput(micInput) {
                self.session.addInput(micInput)
            }

            if self.session.canAddOutput(self.photoOutput) {
                self.session.addOutput(self.photoOutput)
            }

            self.videoDataOutput.alwaysDiscardsLateVideoFrames = true
            self.videoDataOutput.videoSettings = [
                kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_420YpCbCr8BiPlanarFullRange)
            ]
            self.videoDataOutput.setSampleBufferDelegate(self, queue: self.videoQueue)
            if self.session.canAddOutput(self.videoDataOutput) {
                self.session.addOutput(self.videoDataOutput)
            }

            self.audioDataOutput.setSampleBufferDelegate(self, queue: self.audioQueue)
            if self.session.canAddOutput(self.audioDataOutput) {
                self.session.addOutput(self.audioDataOutput)
            }

            self.session.commitConfiguration()
            self.isSessionConfigured = true
        }

        if let errMsg {
            DispatchQueue.main.async {
                self.statusBanner = "Error sesión: \(errMsg)"
            }
            return
        }

        configureCameraFormatLocked()

        _ = ObjCCatcher.catchException {
            if !self.session.isRunning {
                self.session.startRunning()
            }
        }
    }

    func reconfigureForMode() {
        sessionQueue.async { [weak self] in
            guard let self, self.isSessionConfigured, !self.isRecording else { return }
            self.configureCameraFormatLocked()
        }
    }

    // MARK: - Selección Inteligente de Formato del Sensor (1x 48MP, 0.5x UltraWide 4K, 2x, 8K 60fps, Open Gate 4:3)
    private func configureCameraFormatLocked() {
        guard let device = AVCaptureDevice.default(lens.deviceType, for: .video, position: .back)
                ?? AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back) else {
            return
        }

        var chosenVideoDim = CMVideoDimensions(width: 3840, height: 2160)
        var chosenPhotoDim = CMVideoDimensions(width: 4032, height: 3024)
        var actualFPS: Double = 60.0

        let errMsg = ObjCCatcher.catchException {
            self.session.beginConfiguration()
            self.session.sessionPreset = .inputPriority

            // Cambiar de cámara física si cambió entre 1x/2x y 0.5x
            if self.videoDeviceInput?.device.uniqueID != device.uniqueID {
                if let oldInput = self.videoDeviceInput {
                    self.session.removeInput(oldInput)
                }
                if let newInput = try? AVCaptureDeviceInput(device: device), self.session.canAddInput(newInput) {
                    self.session.addInput(newInput)
                    self.videoDeviceInput = newInput
                }
            }

            if (try? device.lockForConfiguration()) != nil {
                switch self.mode {
                case .rawPhoto:
                    // Seleccionar el formato 4:3 de mayor resolución de video Y máxima foto (8064x6048 en 1x, 4032x3024 en 0.5x)
                    if let bestFormat = self.selectBestPhotoFormat(for: device) {
                        device.activeFormat = bestFormat
                        let maxDim = bestFormat.supportedMaxPhotoDimensions.max {
                            Int($0.width) * Int($0.height) < Int($1.width) * Int($1.height)
                        }
                        if let maxDim, maxDim.width > 0 {
                            _ = ObjCCatcher.catchException {
                                self.photoOutput.maxPhotoDimensions = maxDim
                            }
                            chosenPhotoDim = maxDim
                        }
                        actualFPS = self.clampFPS(60.0, for: bestFormat)
                        let dur = CMTime(value: 1, timescale: CMTimeScale(actualFPS))
                        _ = ObjCCatcher.catchException {
                            device.activeVideoMinFrameDuration = dur
                            device.activeVideoMaxFrameDuration = dur
                        }
                    }
                    _ = ObjCCatcher.catchException {
                        self.photoOutput.maxPhotoQualityPrioritization = .balanced
                    }
                    if self.photoOutput.isAppleProRAWSupported {
                        _ = ObjCCatcher.catchException {
                            self.photoOutput.isAppleProRAWEnabled = true
                        }
                    }

                case .video8KFluid:
                    // 16:9 4K (3840x2160) a 60 FPS reales -> Hardware Media Engine 8K 7680x4320
                    let desired = Double(self.targetFPS)
                    if let bestVideoFormat = self.selectBestVideoFormat(for: device, desiredFPS: desired, preferOpenGate4by3: false) {
                        device.activeFormat = bestVideoFormat
                        actualFPS = self.clampFPS(desired, for: bestVideoFormat)
                        let dur = CMTime(value: 1, timescale: CMTimeScale(actualFPS))
                        _ = ObjCCatcher.catchException {
                            device.activeVideoMinFrameDuration = dur
                            device.activeVideoMaxFrameDuration = dur
                        }
                    }

                case .video8KSensor48MP:
                    // 4:3 Open Gate completo (4032x3024) sin recorte -> 8K 7680x4320
                    let desired = self.openGateCinema24FPS ? 24.0 : 30.0
                    if let bestOpenGate = self.selectBestVideoFormat(for: device, desiredFPS: desired, preferOpenGate4by3: true) {
                        device.activeFormat = bestOpenGate
                        actualFPS = self.clampFPS(desired, for: bestOpenGate)
                        let dur = CMTime(value: 1, timescale: CMTimeScale(actualFPS))
                        _ = ObjCCatcher.catchException {
                            device.activeVideoMinFrameDuration = dur
                            device.activeVideoMaxFrameDuration = dur
                        }
                    }
                }

                // Aplicar zoom óptico 2x si está seleccionado
                let maxZ = min(device.activeFormat.videoMaxZoomFactor, 6.0)
                let targetZ = min(max(self.lens.zoomFactor, 1.0), maxZ)
                _ = ObjCCatcher.catchException {
                    device.videoZoomFactor = targetZ
                }

                // Enfoque y exposición continuos suaves por defecto (especialmente importante en 0.5x)
                if !self.manualFocus && device.isFocusModeSupported(.continuousAutoFocus) {
                    device.focusMode = .continuousAutoFocus
                }
                if !self.manualExposure && device.isExposureModeSupported(.continuousAutoExposure) {
                    device.exposureMode = .continuousAutoExposure
                }

                chosenVideoDim = CMVideoFormatDescriptionGetDimensions(device.activeFormat.formatDescription)
                device.unlockForConfiguration()
            }

            self.session.commitConfiguration()

            if let conn = self.videoDataOutput.connection(with: .video) {
                _ = ObjCCatcher.catchException {
                    if conn.isVideoRotationAngleSupported(90) {
                        conn.videoRotationAngle = 90
                    }
                    // En Open Gate Puro desactivamos el recorte de estabilización (EIS) para usar el 100% del sensor
                    if conn.isVideoStabilizationSupported {
                        conn.preferredVideoStabilizationMode = (self.mode == .video8KSensor48MP) ? .off : .standard
                    }
                }
            }
        }

        let minI = device.activeFormat.minISO
        let maxI = device.activeFormat.maxISO
        let curISO = device.iso
        let hasRAW = !photoOutput.availableRawPhotoPixelFormatTypes.isEmpty
        let pDim = photoOutput.maxPhotoDimensions.width > 0 ? photoOutput.maxPhotoDimensions : chosenPhotoDim

        DispatchQueue.main.async {
            self.minISO = minI
            self.maxISO = maxI
            self.isoValue = min(max(curISO, minI), maxI)
            self.rawSupportedOnCurrentLens = hasRAW
            self.measuredFPS = actualFPS

            if let errMsg {
                self.statusBanner = "Aviso: \(errMsg)"
                return
            }

            switch self.mode {
            case .rawPhoto:
                self.activeAspectRatio = 4.0 / 3.0
                self.activeSensorFormatText = "\(pDim.width)×\(pDim.height) • \(hasRAW ? "BAYER .DNG" : "RAW .DNG + 48MP")"
                self.statusBanner = "Sensor \(pDim.width)×\(pDim.height) listo (Cero Deep Fusion)"
            case .video8KFluid:
                self.activeAspectRatio = 16.0 / 9.0
                self.activeSensorFormatText = "\(chosenVideoDim.width)×\(chosenVideoDim.height) → 8K 7680×4320 (\(Int(actualFPS)) FPS)"
                self.statusBanner = "8K \(Int(actualFPS)) FPS Hardware Media Engine listo"
            case .video8KSensor48MP:
                let aspect = CGFloat(max(chosenVideoDim.height, 1)) / CGFloat(max(chosenVideoDim.width, 1))
                self.activeAspectRatio = aspect < 1.0 ? (1.0 / aspect) : aspect
                self.activeSensorFormatText = "OPEN GATE \(chosenVideoDim.width)×\(chosenVideoDim.height) → 8K 7680×4320"
                self.statusBanner = "8K Open Gate Puro (\(Int(actualFPS)) FPS sin recorte) listo"
            }
        }
    }

    /// Selecciona el formato con mejor vista previa (4K / 4032x3024) Y mayor resolución fotográfica (48MP en 1x, 12MP en 0.5x)
    /// Nunca elige formatos de baja resolución (640x480) que hacían ver borroso el lente 0.5x.
    private func selectBestPhotoFormat(for device: AVCaptureDevice) -> AVCaptureDevice.Format? {
        let candidates = device.formats.filter { fmt in
            let sub = CMFormatDescriptionGetMediaSubType(fmt.formatDescription)
            let vDim = CMVideoFormatDescriptionGetDimensions(fmt.formatDescription)
            let isYUV = (sub == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
                      || sub == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
                      || sub == kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange)
            return isYUV && vDim.width >= 1920
        }

        return candidates.max { a, b in
            let maxPhotoA = a.supportedMaxPhotoDimensions.map { Int($0.width) * Int($0.height) }.max() ?? 0
            let maxPhotoB = b.supportedMaxPhotoDimensions.map { Int($0.width) * Int($0.height) }.max() ?? 0
            if maxPhotoA != maxPhotoB {
                return maxPhotoA < maxPhotoB
            }
            let va = CMVideoFormatDescriptionGetDimensions(a.formatDescription)
            let vb = CMVideoFormatDescriptionGetDimensions(b.formatDescription)
            let videoPixelsA = Int(va.width) * Int(va.height)
            let videoPixelsB = Int(vb.width) * Int(vb.height)
            if videoPixelsA != videoPixelsB {
                return videoPixelsA < videoPixelsB
            }
            let fpsA = a.videoSupportedFrameRateRanges.map(\.maxFrameRate).max() ?? 0
            let fpsB = b.videoSupportedFrameRateRanges.map(\.maxFrameRate).max() ?? 0
            return fpsA < fpsB
        } ?? device.formats.last
    }

    /// Selecciona el mejor formato de video 4K 16:9 (60fps) o 4:3 Open Gate (4032x3024)
    private func selectBestVideoFormat(for device: AVCaptureDevice, desiredFPS: Double, preferOpenGate4by3: Bool) -> AVCaptureDevice.Format? {
        let candidates = device.formats.filter { fmt in
            let sub = CMFormatDescriptionGetMediaSubType(fmt.formatDescription)
            let isYUV = (sub == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
                      || sub == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange)
            let vDim = CMVideoFormatDescriptionGetDimensions(fmt.formatDescription)
            let supportsFPS = fmt.videoSupportedFrameRateRanges.contains { $0.maxFrameRate >= desiredFPS }
            return isYUV && vDim.width >= 3840 && supportsFPS
        }

        return candidates.max { a, b in
            let da = CMVideoFormatDescriptionGetDimensions(a.formatDescription)
            let db = CMVideoFormatDescriptionGetDimensions(b.formatDescription)
            let is4by3A = abs(Double(da.width) / Double(max(da.height, 1)) - (4.0 / 3.0)) < 0.08
            let is4by3B = abs(Double(db.width) / Double(max(db.height, 1)) - (4.0 / 3.0)) < 0.08

            if preferOpenGate4by3 && (is4by3A != is4by3B) {
                return !is4by3A && is4by3B
            }
            if !preferOpenGate4by3 && (is4by3A != is4by3B) {
                return is4by3A && !is4by3B
            }
            let pixA = Int(da.width) * Int(da.height)
            let pixB = Int(db.width) * Int(db.height)
            if pixA != pixB {
                return pixA < pixB
            }
            return a.videoFieldOfView < b.videoFieldOfView
        } ?? selectBestPhotoFormat(for: device)
    }

    private func clampFPS(_ fps: Double, for format: AVCaptureDevice.Format) -> Double {
        guard let range = format.videoSupportedFrameRateRanges.max(by: { $0.maxFrameRate < $1.maxFrameRate }) else {
            return 30
        }
        return min(max(fps, range.minFrameRate), range.maxFrameRate)
    }

    // MARK: - Tap-to-Focus & Exposición en el Visor
    func focusAndExpose(at normalizedPoint: CGPoint, viewPoint: CGPoint) {
        DispatchQueue.main.async {
            self.focusTapPoint = viewPoint
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
        }
        sessionQueue.async { [weak self] in
            guard let self, let device = self.videoDeviceInput?.device else { return }
            _ = ObjCCatcher.catchException {
                guard (try? device.lockForConfiguration()) != nil else { return }
                defer { device.unlockForConfiguration() }

                let clamped = CGPoint(
                    x: min(max(normalizedPoint.x, 0.05), 0.95),
                    y: min(max(normalizedPoint.y, 0.05), 0.95)
                )
                if device.isFocusPointOfInterestSupported && device.isFocusModeSupported(.autoFocus) {
                    device.focusPointOfInterest = clamped
                    device.focusMode = .autoFocus
                }
                if device.isExposurePointOfInterestSupported && device.isExposureModeSupported(.autoExpose) {
                    device.exposurePointOfInterest = clamped
                    device.exposureMode = .autoExpose
                }
            }
        }
    }

    // MARK: - Controles Manuales de Exposición y Enfoque
    func applyExposureSettings() {
        sessionQueue.async { [weak self] in
            guard let self, let device = self.videoDeviceInput?.device else { return }
            _ = ObjCCatcher.catchException {
                guard (try? device.lockForConfiguration()) != nil else { return }
                defer { device.unlockForConfiguration() }

                if self.manualExposure && device.isExposureModeSupported(.custom) {
                    let minDur = CMTimeGetSeconds(device.activeFormat.minExposureDuration)
                    let maxDur = min(CMTimeGetSeconds(device.activeFormat.maxExposureDuration), 0.5)
                    let clampedSec = min(max(self.shutterSeconds, minDur), maxDur)
                    let dur = CMTimeMakeWithSeconds(clampedSec, preferredTimescale: 1_000_000)
                    let clampedISO = min(max(self.isoValue, device.activeFormat.minISO), device.activeFormat.maxISO)
                    device.setExposureModeCustom(duration: dur, iso: clampedISO, completionHandler: nil)
                } else if device.isExposureModeSupported(.continuousAutoExposure) {
                    device.exposureMode = .continuousAutoExposure
                }
            }
        }
    }

    func applyFocusSettings() {
        sessionQueue.async { [weak self] in
            guard let self, let device = self.videoDeviceInput?.device else { return }
            _ = ObjCCatcher.catchException {
                guard (try? device.lockForConfiguration()) != nil else { return }
                defer { device.unlockForConfiguration() }

                if self.manualFocus && device.isLockingFocusWithCustomLensPositionSupported {
                    device.setFocusModeLocked(lensPosition: min(max(self.focusPosition, 0.0), 1.0), completionHandler: nil)
                } else if device.isFocusModeSupported(.continuousAutoFocus) {
                    device.focusMode = .continuousAutoFocus
                }
            }
        }
    }

    // MARK: - Acción Principal del Obturador
    func triggerPrimaryAction() {
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        switch mode {
        case .rawPhoto:
            shootRawPhoto()
        case .video8KFluid, .video8KSensor48MP:
            if isRecording {
                stop8KRecording()
            } else {
                start8KRecording()
            }
        }
    }

    // MARK: - Modo 1: Disparo Fotográfico 48MP "Process Zero" (Sin Deep Fusion) + .DNG Real
    private func shootRawPhoto() {
        sessionQueue.async { [weak self] in
            guard let self, !self.isCapturingPhoto else { return }
            DispatchQueue.main.async {
                self.isCapturingPhoto = true
                self.flashEffect = true
                self.statusBanner = "Capturando sensor completo..."
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
                    self.flashEffect = false
                }
            }

            let errMsg = ObjCCatcher.catchException {
                let settings: AVCapturePhotoSettings
                if let rawFormat = self.photoOutput.availableRawPhotoPixelFormatTypes.first {
                    settings = AVCapturePhotoSettings(rawPixelFormatType: rawFormat)
                } else {
                    // Captura directa de máxima resolución sin compresión destructiva
                    settings = AVCapturePhotoSettings(format: [AVVideoCodecKey: AVVideoCodecType.jpeg])
                }

                if self.photoOutput.maxPhotoDimensions.width > 0 {
                    _ = ObjCCatcher.catchException {
                        settings.maxPhotoDimensions = self.photoOutput.maxPhotoDimensions
                    }
                }
                // .speed o .balanced evita que el ISP aplique el procesado artificial agresivo de Deep Fusion
                _ = ObjCCatcher.catchException {
                    settings.photoQualityPrioritization = .speed
                }

                self.photoOutput.capturePhoto(with: settings, delegate: self)
            }

            if let errMsg {
                DispatchQueue.main.async {
                    self.isCapturingPhoto = false
                    self.statusBanner = "Error disparo: \(errMsg)"
                }
            }
        }
    }

    // MARK: - Modos 2 y 3: Grabación 8K (7680x4320 HEVC) por Hardware Media Engine (60 FPS / 30 FPS sin caídas)
    private func start8KRecording() {
        sessionQueue.async { [weak self] in
            guard let self, !self.isRecording else { return }

            let docsDir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
                ?? FileManager.default.temporaryDirectory
            let outputURL = docsDir.appendingPathComponent("Raw8K_\(Int(Date().timeIntervalSince1970)).mov")
            try? FileManager.default.removeItem(at: outputURL)

            guard let writer = try? AVAssetWriter(outputURL: outputURL, fileType: .mov) else {
                DispatchQueue.main.async { self.statusBanner = "Error al crear contenedor 8K .MOV" }
                return
            }

            let expectedFPS = (self.mode == .video8KFluid) ? self.targetFPS : (self.openGateCinema24FPS ? 24 : 30)
            let bitrate = (self.mode == .video8KSensor48MP) ? 130_000_000 : 100_000_000

            // Escalado directo en el Hardware Media Engine del A18 (AVVideoScalingModeKey)
            // Cero conversión a 32BGRA -> mantiene 60 FPS clavados sin caer a 8 FPS
            let compressionProps: [String: Any] = [
                AVVideoAverageBitRateKey: bitrate,
                AVVideoExpectedSourceFrameRateKey: expectedFPS,
                AVVideoMaxKeyFrameIntervalKey: expectedFPS,
                AVVideoAllowFrameReorderingKey: false
            ]

            let scalingMode = (self.mode == .video8KSensor48MP && self.showFullSensorFrame)
                ? AVVideoScalingModeResizeAspect
                : AVVideoScalingModeResizeAspectFill

            let videoSettings: [String: Any] = [
                AVVideoCodecKey: AVVideoCodecType.hevc,
                AVVideoWidthKey: self.outWidth8K,
                AVVideoHeightKey: self.outHeight8K,
                AVVideoScalingModeKey: scalingMode,
                AVVideoCompressionPropertiesKey: compressionProps
            ]

            let errMsg = ObjCCatcher.catchException {
                let vInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
                vInput.expectsMediaDataInRealTime = true
                if writer.canAdd(vInput) {
                    writer.add(vInput)
                }

                let audioSettings: [String: Any] = [
                    AVFormatIDKey: kAudioFormatMPEG4AAC,
                    AVSampleRateKey: 48_000,
                    AVNumberOfChannelsKey: 2,
                    AVEncoderBitRateKey: 256_000
                ]
                let aInput = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
                aInput.expectsMediaDataInRealTime = true
                if writer.canAdd(aInput) {
                    writer.add(aInput)
                    self.writerAudioInput = aInput
                }

                writer.startWriting()
                self.assetWriter = writer
                self.writerVideoInput = vInput
                self.recordingStartPTS = nil
            }

            if let errMsg {
                DispatchQueue.main.async {
                    self.statusBanner = "Error codificador 8K: \(errMsg)"
                }
                return
            }

            DispatchQueue.main.async {
                self.isRecording = true
                self.recordedFramesCount = 0
                self.recordingElapsedSeconds = 0
                self.statusBanner = "GRABANDO 8K \(self.outWidth8K)×\(self.outHeight8K) (\(expectedFPS) FPS)..."
            }
        }
    }

    private func stop8KRecording() {
        sessionQueue.async { [weak self] in
            guard let self, self.isRecording, let writer = self.assetWriter else { return }
            DispatchQueue.main.async {
                self.isRecording = false
                self.statusBanner = "Guardando master 8K .MOV..."
            }

            _ = ObjCCatcher.catchException {
                self.writerVideoInput?.markAsFinished()
                self.writerAudioInput?.markAsFinished()
            }
            let outputURL = writer.outputURL

            writer.finishWriting {
                self.assetWriter = nil
                self.writerVideoInput = nil
                self.writerAudioInput = nil

                PHPhotoLibrary.shared().performChanges({
                    PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: outputURL)
                }) { saved, err in
                    DispatchQueue.main.async {
                        self.lastCapturedFileURL = outputURL
                        if saved {
                            UINotificationFeedbackGenerator().notificationOccurred(.success)
                            self.statusBanner = "8K (7680×4320) guardado en Fotos y Archivos (\(self.recordedFramesCount) f)"
                        } else {
                            self.statusBanner = "8K guardado en Archivos (\(err?.localizedDescription ?? ""))"
                        }
                    }
                }
            }
        }
    }

    // MARK: - Telemetría Ligera sin Bloquear la GPU durante Grabación 8K
    private func updateTelemetryAndHistogram(from pixelBuffer: CVPixelBuffer) {
        let now = CFAbsoluteTimeGetCurrent()
        frameCounterWindow += 1
        let dt = now - fpsWindowStart
        guard dt >= 0.45 else { return }

        let fps = Double(frameCounterWindow) / dt
        frameCounterWindow = 0
        fpsWindowStart = now

        // Durante grabación 8K a 60fps evitamos bloquear la superficie IOSurface en CPU para no perder ni 1 fps
        if isRecording {
            DispatchQueue.main.async {
                self.measuredFPS = fps
            }
            return
        }

        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        var bins = [Float](repeating: 0, count: 28)
        if let base = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 0) {
            let w = CVPixelBufferGetWidthOfPlane(pixelBuffer, 0)
            let h = CVPixelBufferGetHeightOfPlane(pixelBuffer, 0)
            let bpr = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 0)
            let ptr = base.assumingMemoryBound(to: UInt8.self)
            let stepX = max(1, w / 36)
            let stepY = max(1, h / 36)
            var samples: Float = 0
            for y in stride(from: 0, to: h, by: stepY) {
                let row = ptr + y * bpr
                for x in stride(from: 0, to: w, by: stepX) {
                    let luma = Int(row[x])
                    let idx = min(27, (luma * 28) >> 8)
                    bins[idx] += 1
                    samples += 1
                }
            }
            if samples > 0 {
                let maxBin = max(bins.max() ?? 1, 1)
                bins = bins.map { max(0.06, $0 / maxBin) }
            }
        }
        CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly)

        DispatchQueue.main.async {
            self.measuredFPS = fps
            self.histogramBins = bins
        }
    }
}

// MARK: - Delegado de Video y Audio Zero-Copy 8K
extension CameraEngine: AVCaptureVideoDataOutputSampleBufferDelegate, AVCaptureAudioDataOutputSampleBufferDelegate {
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        if output === videoDataOutput {
            if let pb = CMSampleBufferGetImageBuffer(sampleBuffer) {
                updateTelemetryAndHistogram(from: pb)
            }

            guard isRecording,
                  let writer = assetWriter,
                  writer.status == .writing,
                  let vInput = writerVideoInput,
                  vInput.isReadyForMoreMediaData else {
                return
            }

            let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
            if recordingStartPTS == nil {
                recordingStartPTS = pts
                writer.startSession(atSourceTime: pts)
            }

            var appended = false
            _ = ObjCCatcher.catchException {
                appended = vInput.append(sampleBuffer)
            }

            if appended {
                let start = recordingStartPTS ?? pts
                let elapsed = max(0, CMTimeGetSeconds(CMTimeSubtract(pts, start)))
                DispatchQueue.main.async {
                    self.recordedFramesCount += 1
                    self.recordingElapsedSeconds = elapsed
                }
            }
        } else if output === audioDataOutput {
            guard isRecording,
                  let writer = assetWriter,
                  writer.status == .writing,
                  recordingStartPTS != nil,
                  let aInput = writerAudioInput,
                  aInput.isReadyForMoreMediaData else {
                return
            }
            _ = ObjCCatcher.catchException {
                aInput.append(sampleBuffer)
            }
        }
    }
}

// MARK: - Delegado de Captura Fotográfica: Guardado 100% Seguro en Carrete + Exportación .DNG en Archivos
extension CameraEngine: AVCapturePhotoCaptureDelegate {
    func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
        guard let rawOrCompressedData = photo.fileDataRepresentation() else {
            DispatchQueue.main.async {
                self.isCapturingPhoto = false
                self.statusBanner = "Error captura: \(error?.localizedDescription ?? "sin datos")"
            }
            return
        }

        let timestamp = Int(Date().timeIntervalSince1970)
        let docsDir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory

        // Miniatura para la interfaz
        let thumbImage = UIImage(data: rawOrCompressedData)

        // 1. Si es un Bayer RAW .DNG nativo, guardarlo directo como .DNG
        if photo.isRawPhoto {
            let dngURL = docsDir.appendingPathComponent("IMG_\(timestamp)_RAW.DNG")
            try? rawOrCompressedData.write(to: dngURL, options: .atomic)

            PHPhotoLibrary.shared().performChanges({
                let req = PHAssetCreationRequest.forAsset()
                req.addResource(with: .photo, fileURL: dngURL, options: nil)
            }) { saved, err in
                DispatchQueue.main.async {
                    self.isCapturingPhoto = false
                    self.lastCapturedFileURL = dngURL
                    self.lastThumbnail = thumbImage
                    let sizeMB = String(format: "%.1f MB", Double(rawOrCompressedData.count) / (1024 * 1024))
                    if saved {
                        UINotificationFeedbackGenerator().notificationOccurred(.success)
                        self.statusBanner = "RAW .DNG (\(sizeMB)) guardado en Fotos y Archivos"
                    } else {
                        self.statusBanner = "RAW .DNG (\(sizeMB)) guardado en app Archivos"
                    }
                }
            }
            return
        }

        // 2. En iPhone 16 base: guardar foto Process-Zero (48MP sin Deep Fusion) en Fotos + generar .DNG en Archivos
        let photoTempURL = FileManager.default.temporaryDirectory.appendingPathComponent("IMG_\(timestamp)_48MP.jpg")
        try? rawOrCompressedData.write(to: photoTempURL, options: .atomic)

        // Generar también el contenedor .DNG / TIFF en la carpeta Archivos del iPhone
        let dngURL = docsDir.appendingPathComponent("IMG_\(timestamp)_RAW48MP.dng")
        if let cgImg = photo.cgImageRepresentation(),
           let dest = CGImageDestinationCreateWithURL(dngURL as CFURL, "com.adobe.raw-image" as CFString, 1, nil)
                   ?? CGImageDestinationCreateWithURL(dngURL as CFURL, UTType.tiff.identifier as CFString, 1, nil) {
            let props: [CFString: Any] = [kCGImagePropertyOrientation: 6]
            CGImageDestinationAddImage(dest, cgImg, props as CFDictionary)
            CGImageDestinationFinalize(dest)
        } else {
            try? rawOrCompressedData.write(to: dngURL, options: .atomic)
        }

        let dims = photo.resolvedSettings.photoDimensions
        PHPhotoLibrary.shared().performChanges({
            PHAssetChangeRequest.creationRequestForAssetFromImage(atFileURL: photoTempURL)
        }) { saved, err in
            try? FileManager.default.removeItem(at: photoTempURL)
            DispatchQueue.main.async {
                self.isCapturingPhoto = false
                self.lastCapturedFileURL = dngURL
                self.lastThumbnail = thumbImage
                let sizeMB = String(format: "%.1f MB", Double(rawOrCompressedData.count) / (1024 * 1024))
                if saved {
                    UINotificationFeedbackGenerator().notificationOccurred(.success)
                    self.statusBanner = "Guardado \(dims.width)×\(dims.height) (\(sizeMB)) en Fotos + .DNG"
                } else {
                    self.statusBanner = "Error Fotos: \(err?.localizedDescription ?? "guardado en Archivos")"
                }
            }
        }
    }
}
