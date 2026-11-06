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
    case videoFluid = "CINE 9:16"
    case videoOpenGate = "OPEN GATE 3:4"

    var id: String { rawValue }

    var subtitle: String {
        switch self {
        case .rawPhoto:
            return "Foto 48MP (8064×6048) sin Deep Fusion • Carrete + .DNG"
        case .videoFluid:
            return "Formato Vertical 9:16 • 24 / 30 / 60 FPS sin pérdida de cuadros"
        case .videoOpenGate:
            return "Sensor Completo 3:4 Open Gate sin recorte • 24 / 30 / 60 FPS"
        }
    }
}

enum VideoResolutionTier: String, CaseIterable, Identifiable {
    case uhd8K = "8K UHD"
    case pro6K = "6K PRO"
    case native4KPlus = "4.3K DIRECTO"

    var id: String { rawValue }

    func targetLandscapeDimensions(isOpenGate4by3: Bool, sourceDim: CMVideoDimensions) -> (width: Int, height: Int) {
        let w = Int(max(sourceDim.width, sourceDim.height))
        let h = Int(min(sourceDim.width, sourceDim.height))
        switch self {
        case .uhd8K:
            return isOpenGate4by3 ? (5760, 4320) : (7680, 4320)
        case .pro6K:
            return isOpenGate4by3 ? (4800, 3600) : (5760, 3240)
        case .native4KPlus:
            return (max(w, 3840), max(h, 2160))
        }
    }

    var bitrate: Int {
        switch self {
        case .uhd8K: return 110_000_000
        case .pro6K: return 80_000_000
        case .native4KPlus: return 55_000_000
        }
    }
}

enum LensChoice: String, CaseIterable, Identifiable {
    case ultraWide = "0.5x"
    case wide1x = "1x"
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
    @Published var resolutionTier: VideoResolutionTier = .pro6K {
        didSet { updateBannerForCurrentState() }
    }
    @Published var lens: LensChoice = .wide1x {
        didSet { reconfigureForMode() }
    }
    @Published var targetFPS: Int = 60 {
        didSet { reconfigureForMode() }
    }

    @Published var showGridLines: Bool = true
    @Published var flashEffect: Bool = false

    @Published var isRecording: Bool = false
    @Published var isMasteringVideo: Bool = false
    @Published var masteringProgress: Double = 0.0
    @Published var isCapturingPhoto: Bool = false
    @Published var statusBanner: String = "Iniciando sensor..."
    @Published var activeSensorFormatText: String = "48MP 8064×6048"
    // Aspect ratio vertical mostrado en pantalla (0.75 para 3:4, 0.5625 para 9:16)
    @Published var viewfinderPortraitAspect: CGFloat = 3.0 / 4.0
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
    @Published var histogramBins: [Float] = Array(repeating: 0.18, count: 28)

    // MARK: - AVFoundation Core
    let session = AVCaptureSession()
    private let sessionQueue = DispatchQueue(label: "com.raw8kcam.session", qos: .userInitiated)
    private let videoQueue = DispatchQueue(label: "com.raw8kcam.videoOutput", qos: .userInteractive)
    private let audioQueue = DispatchQueue(label: "com.raw8kcam.audioOutput", qos: .userInitiated)
    private let masterQueue = DispatchQueue(label: "com.raw8kcam.mastering", qos: .userInitiated)

    private var isSessionConfigured = false
    private var videoDeviceInput: AVCaptureDeviceInput?
    private let photoOutput = AVCapturePhotoOutput()
    private let videoDataOutput = AVCaptureVideoDataOutput()
    private let audioDataOutput = AVCaptureAudioDataOutput()

    // Estado del formato activo del sensor
    private var currentVideoDimensions = CMVideoDimensions(width: 3840, height: 2160)
    private var currentPhotoDimensions = CMVideoDimensions(width: 8064, height: 6048)
    private var currentActualFPS: Double = 60.0

    // Grabador en Tiempo Real (Etapa 1: Captura 1:1 sin pérdida de cuadros)
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

            self.videoDataOutput.alwaysDiscardsLateVideoFrames = false
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
            guard let self, self.isSessionConfigured, !self.isRecording, !self.isMasteringVideo else { return }
            self.configureCameraFormatLocked()
        }
    }

    // MARK: - Configuración Exacta de Formato del Sensor (0.5x, 1x, 2x | 24, 30, 60 FPS | 9:16 vs 3:4)
    private func configureCameraFormatLocked() {
        guard let device = AVCaptureDevice.default(lens.deviceType, for: .video, position: .back)
                ?? AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back) else {
            return
        }

        var chosenVideoDim = CMVideoDimensions(width: 3840, height: 2160)
        var chosenPhotoDim = CMVideoDimensions(width: 4032, height: 3024)
        var actualFPS: Double = Double(targetFPS)

        let errMsg = ObjCCatcher.catchException {
            self.session.beginConfiguration()
            self.session.sessionPreset = .inputPriority

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

                case .videoFluid:
                    let desired = Double(self.targetFPS)
                    if let best16by9 = self.selectBestVideoFormat(for: device, desiredFPS: desired, prefer4by3: false) {
                        device.activeFormat = best16by9
                        actualFPS = self.clampFPS(desired, for: best16by9)
                        let dur = CMTime(value: 1, timescale: CMTimeScale(actualFPS))
                        _ = ObjCCatcher.catchException {
                            device.activeVideoMinFrameDuration = dur
                            device.activeVideoMaxFrameDuration = dur
                        }
                    }

                case .videoOpenGate:
                    let desired = Double(self.targetFPS)
                    if let best4by3 = self.selectBestVideoFormat(for: device, desiredFPS: desired, prefer4by3: true) {
                        device.activeFormat = best4by3
                        actualFPS = self.clampFPS(desired, for: best4by3)
                        let dur = CMTime(value: 1, timescale: CMTimeScale(actualFPS))
                        _ = ObjCCatcher.catchException {
                            device.activeVideoMinFrameDuration = dur
                            device.activeVideoMaxFrameDuration = dur
                        }
                    }
                }

                // Aplicar zoom 1x / 2x
                let maxZ = min(device.activeFormat.videoMaxZoomFactor, 6.0)
                let targetZ = min(max(self.lens.zoomFactor, 1.0), maxZ)
                _ = ObjCCatcher.catchException {
                    device.videoZoomFactor = targetZ
                }

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

            // IMPORTANTE: NO rotamos físicamente los píxeles en videoDataOutput (evita caída de FPS).
            // En su lugar, usamos CGAffineTransform(rotationAngle: .pi/2) en el contenedor .MOV.
            if let conn = self.videoDataOutput.connection(with: .video) {
                _ = ObjCCatcher.catchException {
                    if conn.isVideoStabilizationSupported {
                        conn.preferredVideoStabilizationMode = (self.mode == .videoOpenGate) ? .off : .standard
                    }
                }
            }
        }

        self.currentVideoDimensions = chosenVideoDim
        let pDim = photoOutput.maxPhotoDimensions.width > 0 ? photoOutput.maxPhotoDimensions : chosenPhotoDim
        self.currentPhotoDimensions = pDim
        self.currentActualFPS = actualFPS

        let minI = device.activeFormat.minISO
        let maxI = device.activeFormat.maxISO
        let curISO = device.iso
        let hasRAW = !photoOutput.availableRawPhotoPixelFormatTypes.isEmpty

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
            self.updateBannerForCurrentState()
        }
    }

    private func updateBannerForCurrentState() {
        let pDim = currentPhotoDimensions
        let vDim = currentVideoDimensions
        let fpsInt = Int(round(currentActualFPS))

        switch mode {
        case .rawPhoto:
            viewfinderPortraitAspect = 3.0 / 4.0
            activeSensorFormatText = "RAW \(pDim.width)×\(pDim.height) • 3:4"
            statusBanner = "Sensor \(pDim.width)×\(pDim.height) listo (Cero Deep Fusion)"
        case .videoFluid:
            viewfinderPortraitAspect = 9.0 / 16.0
            let out = resolutionTier.targetLandscapeDimensions(isOpenGate4by3: false, sourceDim: vDim)
            // En vertical se guarda como height x width (ej. 4320x7680 o 3240x5760)
            activeSensorFormatText = "\(resolutionTier.rawValue) \(out.height)×\(out.width) • \(fpsInt) FPS"
            statusBanner = "\(resolutionTier.rawValue) Vertical 9:16 a \(fpsInt) FPS listo"
        case .videoOpenGate:
            let w = CGFloat(max(vDim.width, vDim.height))
            let h = CGFloat(min(vDim.width, vDim.height))
            viewfinderPortraitAspect = h / max(w, 1)
            let is4by3 = abs((w / max(h, 1)) - (4.0 / 3.0)) < 0.12
            let out = resolutionTier.targetLandscapeDimensions(isOpenGate4by3: is4by3, sourceDim: vDim)
            activeSensorFormatText = "OPEN GATE \(out.height)×\(out.width) • \(fpsInt) FPS"
            statusBanner = "Open Gate Completo a \(fpsInt) FPS sin recorte listo"
        }
    }

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

    private func selectBestVideoFormat(for device: AVCaptureDevice, desiredFPS: Double, prefer4by3: Bool) -> AVCaptureDevice.Format? {
        let allYUV = device.formats.filter { fmt in
            let sub = CMFormatDescriptionGetMediaSubType(fmt.formatDescription)
            let isYUV = (sub == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
                      || sub == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange)
            let vDim = CMVideoFormatDescriptionGetDimensions(fmt.formatDescription)
            return isYUV && vDim.width >= 1920
        }

        // Primero intentamos con los formatos que soportan el FPS pedido (ej. 60, 30 o 24)
        let fpsMatching = allYUV.filter { fmt in
            fmt.videoSupportedFrameRateRanges.contains { $0.maxFrameRate + 0.5 >= desiredFPS }
        }
        let pool = fpsMatching.isEmpty ? allYUV : fpsMatching

        return pool.max { a, b in
            let da = CMVideoFormatDescriptionGetDimensions(a.formatDescription)
            let db = CMVideoFormatDescriptionGetDimensions(b.formatDescription)
            let ratioA = Double(da.width) / Double(max(da.height, 1))
            let ratioB = Double(db.width) / Double(max(db.height, 1))
            let is4by3A = abs(ratioA - (4.0 / 3.0)) < 0.09
            let is4by3B = abs(ratioB - (4.0 / 3.0)) < 0.09
            let is16by9A = abs(ratioA - (16.0 / 9.0)) < 0.09
            let is16by9B = abs(ratioB - (16.0 / 9.0)) < 0.09

            if prefer4by3 {
                // En Open Gate preferimos 4:3 de alta resolución (>= 2800 px ancho)
                let high4by3A = is4by3A && da.width >= 2800
                let high4by3B = is4by3B && db.width >= 2800
                if high4by3A != high4by3B {
                    return !high4by3A && high4by3B
                }
            } else {
                // En Cine 9:16 obligamos a elegir 16:9 (3840x2160) para que 0.5x y 1x jamás cambien a otro formato
                if is16by9A != is16by9B {
                    return !is16by9A && is16by9B
                }
            }

            let pixA = Int(da.width) * Int(da.height)
            let pixB = Int(db.width) * Int(db.height)
            if pixA != pixB {
                return pixA < pixB
            }
            return a.videoFieldOfView < b.videoFieldOfView
        } ?? device.formats.last
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
        guard !isMasteringVideo else { return }
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        switch mode {
        case .rawPhoto:
            shootRawPhoto()
        case .videoFluid, .videoOpenGate:
            if isRecording {
                stopRecordingAndMaster()
            } else {
                startZeroDropRecording()
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
                self.statusBanner = "Capturando 48MP sin Deep Fusion..."
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
                    self.flashEffect = false
                }
            }

            let errMsg = ObjCCatcher.catchException {
                let settings: AVCapturePhotoSettings
                if let rawFormat = self.photoOutput.availableRawPhotoPixelFormatTypes.first {
                    settings = AVCapturePhotoSettings(rawPixelFormatType: rawFormat)
                } else {
                    settings = AVCapturePhotoSettings(format: [AVVideoCodecKey: AVVideoCodecType.jpeg])
                }

                if self.photoOutput.maxPhotoDimensions.width > 0 {
                    _ = ObjCCatcher.catchException {
                        settings.maxPhotoDimensions = self.photoOutput.maxPhotoDimensions
                    }
                }
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

    // MARK: - Etapa 1: Captura en Tiempo Real 1:1 con CERO Caída de FPS y Orientación Vertical Exacta
    private func startZeroDropRecording() {
        sessionQueue.async { [weak self] in
            guard let self, !self.isRecording, !self.isMasteringVideo else { return }

            let tempDir = FileManager.default.temporaryDirectory
            let rawMasterURL = tempDir.appendingPathComponent("MasterZeroDrop_\(Int(Date().timeIntervalSince1970)).mov")
            try? FileManager.default.removeItem(at: rawMasterURL)

            guard let writer = try? AVAssetWriter(outputURL: rawMasterURL, fileType: .mov) else {
                DispatchQueue.main.async { self.statusBanner = "Error al crear contenedor .MOV" }
                return
            }

            let srcW = Int(max(self.currentVideoDimensions.width, 1920))
            let srcH = Int(max(self.currentVideoDimensions.height, 1080))
            let fps = Int(round(self.currentActualFPS))

            // En la Etapa 1 grabamos a la resolución nativa exacta del sensor (3840x2160 o 4032x3024)
            // con RealTime=true y sin rotación física de píxeles -> 0% cuadros perdidos a 24, 30 o 60 FPS!
            let compressionProps: [String: Any] = [
                AVVideoAverageBitRateKey: 65_000_000,
                AVVideoExpectedSourceFrameRateKey: fps,
                AVVideoMaxKeyFrameIntervalKey: fps * 2,
                AVVideoAllowFrameReorderingKey: false,
                kVTCompressionPropertyKey_RealTime as String: true
            ]

            let videoSettings: [String: Any] = [
                AVVideoCodecKey: AVVideoCodecType.hevc,
                AVVideoWidthKey: srcW,
                AVVideoHeightKey: srcH,
                AVVideoCompressionPropertiesKey: compressionProps
            ]

            let errMsg = ObjCCatcher.catchException {
                let vInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
                vInput.expectsMediaDataInRealTime = true
                // Matriz de rotación vertical (90°) de costo cero en el encabezado del .MOV
                vInput.transform = CGAffineTransform(rotationAngle: .pi / 2)

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
                    self.statusBanner = "Error grabador: \(errMsg)"
                }
                return
            }

            DispatchQueue.main.async {
                self.isRecording = true
                self.recordedFramesCount = 0
                self.recordingElapsedSeconds = 0
                self.statusBanner = "GRABANDO \(self.resolutionTier.rawValue) • \(fps) FPS SIN PÉRDIDA..."
            }
        }
    }

    // MARK: - Etapa 2: Cierre y Masterización Pull-Mode a 6K / 8K sin Congelamientos
    private func stopRecordingAndMaster() {
        sessionQueue.async { [weak self] in
            guard let self, self.isRecording, let writer = self.assetWriter else { return }

            let tier = self.resolutionTier
            let isOpenGate = (self.mode == .videoOpenGate)
            let srcDim = self.currentVideoDimensions
            let fps = Int(round(self.currentActualFPS))

            DispatchQueue.main.async {
                self.isRecording = false
                self.statusBanner = "Cerrando captura en tiempo real..."
            }

            _ = ObjCCatcher.catchException {
                self.writerVideoInput?.markAsFinished()
                self.writerAudioInput?.markAsFinished()
            }
            let masterURL = writer.outputURL

            writer.finishWriting {
                self.assetWriter = nil
                self.writerVideoInput = nil
                self.writerAudioInput = nil

                // Si el usuario eligió 4.3K DIRECTO, se guarda al instante sin espera
                if tier == .native4KPlus {
                    self.saveVideoFileToPhotosAndFiles(sourceURL: masterURL, label: "4.3K Directo (\(fps) FPS)")
                    return
                }

                // Si eligió 6K PRO u 8K UHD, escalamos con AVAssetReader (Pull-Mode) para conservar el 100% de los FPS sin congelamientos
                let ratio = Double(max(srcDim.width, srcDim.height)) / Double(max(min(srcDim.width, srcDim.height), 1))
                let is4by3 = isOpenGate && abs(ratio - (4.0 / 3.0)) < 0.12
                let target = tier.targetLandscapeDimensions(isOpenGate4by3: is4by3, sourceDim: srcDim)

                self.runOfflineHardwareUpscale(
                    sourceURL: masterURL,
                    targetWidth: target.width,
                    targetHeight: target.height,
                    bitrate: tier.bitrate,
                    fps: fps,
                    tierName: tier.rawValue
                )
            }
        }
    }

    private func runOfflineHardwareUpscale(
        sourceURL: URL,
        targetWidth: Int,
        targetHeight: Int,
        bitrate: Int,
        fps: Int,
        tierName: String
    ) {
        DispatchQueue.main.async {
            self.isMasteringVideo = true
            self.masteringProgress = 0.05
            self.statusBanner = "Masterizando \(tierName) (\(targetHeight)×\(targetWidth)) sin perder FPS..."
        }

        masterQueue.async { [weak self] in
            guard let self else { return }
            let asset = AVURLAsset(url: sourceURL)
            let durationSec = max(CMTimeGetSeconds(asset.duration), 0.1)

            let docsDir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
                ?? FileManager.default.temporaryDirectory
            let finalURL = docsDir.appendingPathComponent("Raw8K_\(tierName.replacingOccurrences(of: " ", with: ""))_\(Int(Date().timeIntervalSince1970)).mov")
            try? FileManager.default.removeItem(at: finalURL)

            guard let reader = try? AVAssetReader(asset: asset),
                  let writer = try? AVAssetWriter(outputURL: finalURL, fileType: .mov),
                  let videoTrack = asset.tracks(withMediaType: .video).first else {
                // Fallback seguro: guardar el master directo sin perder el video
                self.saveVideoFileToPhotosAndFiles(sourceURL: sourceURL, label: "Master Directo")
                return
            }

            let readerVideoSettings: [String: Any] = [
                kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_420YpCbCr8BiPlanarFullRange)
            ]
            let readerVideoOutput = AVAssetReaderTrackOutput(track: videoTrack, outputSettings: readerVideoSettings)
            readerVideoOutput.alwaysCopiesSampleData = false
            if reader.canAdd(readerVideoOutput) {
                reader.add(readerVideoOutput)
            }

            let compressionProps: [String: Any] = [
                AVVideoAverageBitRateKey: bitrate,
                AVVideoExpectedSourceFrameRateKey: fps,
                AVVideoMaxKeyFrameIntervalKey: fps * 2,
                AVVideoAllowFrameReorderingKey: false
            ]
            let writerVideoSettings: [String: Any] = [
                AVVideoCodecKey: AVVideoCodecType.hevc,
                AVVideoWidthKey: targetWidth,
                AVVideoHeightKey: targetHeight,
                AVVideoScalingModeKey: AVVideoScalingModeResizeAspectFill,
                AVVideoCompressionPropertiesKey: compressionProps
            ]
            let writerVideoInput = AVAssetWriterInput(mediaType: .video, outputSettings: writerVideoSettings)
            writerVideoInput.expectsMediaDataInRealTime = false
            writerVideoInput.transform = videoTrack.preferredTransform
            if writer.canAdd(writerVideoInput) {
                writer.add(writerVideoInput)
            }

            var readerAudioOutput: AVAssetReaderTrackOutput?
            var writerAudioInput: AVAssetWriterInput?
            if let audioTrack = asset.tracks(withMediaType: .audio).first {
                let aOut = AVAssetReaderTrackOutput(track: audioTrack, outputSettings: nil)
                if reader.canAdd(aOut) {
                    reader.add(aOut)
                    readerAudioOutput = aOut
                }
                let aIn = AVAssetWriterInput(mediaType: .audio, outputSettings: nil)
                aIn.expectsMediaDataInRealTime = false
                if writer.canAdd(aIn) {
                    writer.add(aIn)
                    writerAudioInput = aIn
                }
            }

            reader.startReading()
            writer.startWriting()
            writer.startSession(atSourceTime: .zero)

            let group = DispatchGroup()

            group.enter()
            let vQueue = DispatchQueue(label: "com.raw8kcam.upscale.video")
            writerVideoInput.requestMediaDataWhenReady(on: vQueue) {
                while writerVideoInput.isReadyForMoreMediaData {
                    if let sb = readerVideoOutput.copyNextSampleBuffer() {
                        let pts = CMSampleBufferGetPresentationTimeStamp(sb)
                        let prog = min(0.98, max(0.05, CMTimeGetSeconds(pts) / durationSec))
                        DispatchQueue.main.async {
                            self.masteringProgress = prog
                            self.statusBanner = String(format: "Masterizando %@ (%dx%d): %.0f%%", tierName, targetHeight, targetWidth, prog * 100)
                        }
                        _ = ObjCCatcher.catchException {
                            _ = writerVideoInput.append(sb)
                        }
                    } else {
                        writerVideoInput.markAsFinished()
                        group.leave()
                        break
                    }
                }
            }

            if let aOut = readerAudioOutput, let aIn = writerAudioInput {
                group.enter()
                let aQueue = DispatchQueue(label: "com.raw8kcam.upscale.audio")
                aIn.requestMediaDataWhenReady(on: aQueue) {
                    while aIn.isReadyForMoreMediaData {
                        if let sb = aOut.copyNextSampleBuffer() {
                            _ = ObjCCatcher.catchException {
                                _ = aIn.append(sb)
                            }
                        } else {
                            aIn.markAsFinished()
                            group.leave()
                            break
                        }
                    }
                }
            }

            group.notify(queue: self.masterQueue) {
                writer.finishWriting {
                    if writer.status == .completed {
                        try? FileManager.default.removeItem(at: sourceURL)
                        self.saveVideoFileToPhotosAndFiles(
                            sourceURL: finalURL,
                            label: "\(tierName) \(targetHeight)×\(targetWidth) (\(fps) FPS)"
                        )
                    } else {
                        // Si algo falló en el reescalado, guardamos el master original sin perder la grabación
                        self.saveVideoFileToPhotosAndFiles(sourceURL: sourceURL, label: "Master \(fps) FPS")
                    }
                }
            }
        }
    }

    private func saveVideoFileToPhotosAndFiles(sourceURL: URL, label: String) {
        let docsDir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let destURL: URL
        if sourceURL.path.hasPrefix(docsDir.path) {
            destURL = sourceURL
        } else {
            destURL = docsDir.appendingPathComponent(sourceURL.lastPathComponent)
            try? FileManager.default.removeItem(at: destURL)
            try? FileManager.default.moveItem(at: sourceURL, to: destURL)
        }

        PHPhotoLibrary.shared().performChanges({
            PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: destURL)
        }) { saved, err in
            DispatchQueue.main.async {
                self.isMasteringVideo = false
                self.masteringProgress = 0.0
                self.lastCapturedFileURL = destURL
                if saved {
                    UINotificationFeedbackGenerator().notificationOccurred(.success)
                    self.statusBanner = "Guardado \(label) en Fotos"
                } else {
                    self.statusBanner = "Guardado en Archivos (\(err?.localizedDescription ?? label))"
                }
            }
        }
    }

    // MARK: - Telemetría Ligera sin Bloquear la Captura
    private func updateTelemetryAndHistogram(from pixelBuffer: CVPixelBuffer) {
        let now = CFAbsoluteTimeGetCurrent()
        frameCounterWindow += 1
        let dt = now - fpsWindowStart
        guard dt >= 0.45 else { return }

        let fps = Double(frameCounterWindow) / dt
        frameCounterWindow = 0
        fpsWindowStart = now

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

// MARK: - Delegado de Video y Audio Zero-Drop
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

        let thumbImage = UIImage(data: rawOrCompressedData)

        if photo.isRawPhoto {
            let dngURL = docsDir.appendingPathComponent("IMG_\(timestamp)_RAW.DNG")
            try? rawOrCompressedData.write(to: dngURL, options: .atomic)

            PHPhotoLibrary.shared().performChanges({
                let req = PHAssetCreationRequest.forAsset()
                req.addResource(with: .photo, fileURL: dngURL, options: nil)
            }) { saved, _ in
                DispatchQueue.main.async {
                    self.isCapturingPhoto = false
                    self.lastCapturedFileURL = dngURL
                    self.lastThumbnail = thumbImage
                    let sizeMB = String(format: "%.1f MB", Double(rawOrCompressedData.count) / (1024 * 1024))
                    if saved {
                        UINotificationFeedbackGenerator().notificationOccurred(.success)
                        self.statusBanner = "RAW .DNG (\(sizeMB)) guardado en Fotos y Archivos"
                    } else {
                        self.statusBanner = "RAW .DNG (\(sizeMB)) guardado en Archivos"
                    }
                }
            }
            return
        }

        let photoTempURL = FileManager.default.temporaryDirectory.appendingPathComponent("IMG_\(timestamp)_48MP.jpg")
        try? rawOrCompressedData.write(to: photoTempURL, options: .atomic)

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
