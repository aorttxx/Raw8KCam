import AVFoundation
import CoreImage
import CoreMedia
import ImageIO
import Metal
import Photos
import SwiftUI
import UniformTypeIdentifiers
import VideoToolbox

enum CaptureMode: String, CaseIterable, Identifiable {
    case rawPhoto = "RAW .DNG"
    case video8KFluid = "8K FLUIDO"
    case video8KSensor48MP = "8K 48MP PURO"

    var id: String { rawValue }

    var subtitle: String {
        switch self {
        case .rawPhoto:
            return "Bayer RAW .DNG / 16-bit sin procesado Deep Fusion"
        case .video8KFluid:
            return "Open Gate 4032×3024 → Metal GPU 8K (7680×4320) HEVC 120 Mbps 30/60fps"
        case .video8KSensor48MP:
            return "Truco iPhone 5s: Ráfaga 48MP (8064×6048) → Recorte 1:1 8K (7680×4320)"
        }
    }
}

enum LensChoice: String, CaseIterable, Identifiable {
    case wide1x = "1x (26mm 48MP)"
    case ultraWide = "0.5x (13mm)"

    var id: String { rawValue }

    var deviceType: AVCaptureDevice.DeviceType {
        switch self {
        case .wide1x: return .builtInWideAngleCamera
        case .ultraWide: return .builtInUltraWideCamera
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
    @Published var isTimelapsePacing48MP: Bool = false

    @Published var isRecording: Bool = false
    @Published var isCapturingPhoto: Bool = false
    @Published var statusBanner: String = "Iniciando cámara..."
    @Published var activeSensorFormatText: String = "Detectando sensor..."
    @Published var measuredFPS: Double = 0.0
    @Published var recordedFramesCount: Int = 0
    @Published var recordingElapsedSeconds: Double = 0.0
    @Published var rawSupportedOnCurrentLens: Bool = false

    // Controles manuales
    @Published var manualExposure: Bool = false
    @Published var isoValue: Float = 100
    @Published var minISO: Float = 32
    @Published var maxISO: Float = 3200
    @Published var shutterSeconds: Double = 1.0 / 120.0
    @Published var manualFocus: Bool = false
    @Published var focusPosition: Float = 0.5
    @Published var histogramBins: [Float] = Array(repeating: 0.08, count: 32)

    // MARK: - AVFoundation & Metal Core
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

    // Grabador 8K (7680 x 4320 HEVC)
    private let outWidth8K = 7680
    private let outHeight8K = 4320
    private var assetWriter: AVAssetWriter?
    private var writerVideoInput: AVAssetWriterInput?
    private var writerAudioInput: AVAssetWriterInput?
    private var pixelBufferAdaptor: AVAssetWriterInputPixelBufferAdaptor?
    private var recordingStartPTS: CMTime?
    private var burstFrameIndex: Int64 = 0
    private var frameCounterWindow: Int = 0
    private var fpsWindowStart: CFAbsoluteTime = CFAbsoluteTimeGetCurrent()

    override init() {
        super.init()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            self?.requestPermissionsAndStart()
        }
    }

    // MARK: - Permisos e Inicialización Secuencial Segura
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
            self.session.sessionPreset = .photo

            // 1. Entrada de cámara principal primero (obligatorio antes de configurar salidas)
            if let cam = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back),
               let camInput = try? AVCaptureDeviceInput(device: cam),
               self.session.canAddInput(camInput) {
                self.session.addInput(camInput)
                self.videoDeviceInput = camInput
            }

            // 2. Entrada de micrófono
            if let mic = AVCaptureDevice.default(for: .audio),
               let micInput = try? AVCaptureDeviceInput(device: mic),
               self.session.canAddInput(micInput) {
                self.session.addInput(micInput)
            }

            // 3. Salida de foto (para RAW .DNG y ráfaga 48MP 8K)
            if self.session.canAddOutput(self.photoOutput) {
                self.session.addOutput(self.photoOutput)
            }

            // 4. Salida de muestras de video (para Open Gate 4032x3024 -> 8K Metal)
            self.videoDataOutput.alwaysDiscardsLateVideoFrames = true
            self.videoDataOutput.setSampleBufferDelegate(self, queue: self.videoQueue)
            if self.session.canAddOutput(self.videoDataOutput) {
                self.session.addOutput(self.videoDataOutput)
            }

            // 5. Salida de muestras de audio
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

    // MARK: - Selección de Formato Físico del Sensor (RAW / Open Gate 4032x3024 / 48MP 8064x6048)
    private func configureCameraFormatLocked() {
        guard let device = AVCaptureDevice.default(lens.deviceType, for: .video, position: .back)
                ?? AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back) else {
            return
        }

        let errMsg = ObjCCatcher.catchException {
            self.session.beginConfiguration()

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
                case .rawPhoto, .video8KSensor48MP:
                    if let bestFormat = self.selectBestPhotoFormat(for: device) {
                        device.activeFormat = bestFormat
                        let maxDim = bestFormat.supportedMaxPhotoDimensions.max {
                            Int($0.width) * Int($0.height) < Int($1.width) * Int($1.height)
                        }
                        if let maxDim, maxDim.width > 0 {
                            _ = ObjCCatcher.catchException {
                                self.photoOutput.maxPhotoDimensions = maxDim
                            }
                        }
                    }
                    _ = ObjCCatcher.catchException {
                        self.photoOutput.maxPhotoQualityPrioritization = (self.mode == .video8KSensor48MP) ? .speed : .balanced
                    }
                    if self.photoOutput.isAppleProRAWSupported {
                        _ = ObjCCatcher.catchException {
                            self.photoOutput.isAppleProRAWEnabled = (self.mode == .rawPhoto)
                        }
                    }

                case .video8KFluid:
                    if let bestVideoFormat = self.selectBestOpenGateVideoFormat(for: device, desiredFPS: Double(self.targetFPS)) {
                        device.activeFormat = bestVideoFormat
                        let fps = self.clampFPS(Double(self.targetFPS), for: bestVideoFormat)
                        let dur = CMTime(value: 1, timescale: CMTimeScale(fps))
                        _ = ObjCCatcher.catchException {
                            device.activeVideoMinFrameDuration = dur
                            device.activeVideoMaxFrameDuration = dur
                        }
                    }
                }
                device.unlockForConfiguration()
            }

            self.session.commitConfiguration()

            if let conn = self.videoDataOutput.connection(with: .video) {
                _ = ObjCCatcher.catchException {
                    if conn.isVideoRotationAngleSupported(90) {
                        conn.videoRotationAngle = 90
                    }
                }
            }
        }

        let minI = device.activeFormat.minISO
        let maxI = device.activeFormat.maxISO
        let curISO = device.iso
        let vDim = CMVideoFormatDescriptionGetDimensions(device.activeFormat.formatDescription)
        let pDim = photoOutput.maxPhotoDimensions.width > 0 ? photoOutput.maxPhotoDimensions : vDim
        let hasRAW = !photoOutput.availableRawPhotoPixelFormatTypes.isEmpty

        DispatchQueue.main.async {
            self.minISO = minI
            self.maxISO = maxI
            self.isoValue = min(max(curISO, minI), maxI)
            self.rawSupportedOnCurrentLens = hasRAW
            if let errMsg {
                self.statusBanner = "Aviso formato: \(errMsg)"
                return
            }
            switch self.mode {
            case .rawPhoto:
                self.activeSensorFormatText = "SENSOR \(pDim.width)×\(pDim.height) • \(hasRAW ? "BAYER RAW .DNG" : "RAW 16-BIT .DNG/.TIFF")"
                self.statusBanner = "RAW .DNG listo (\(pDim.width)×\(pDim.height))"
            case .video8KFluid:
                self.activeSensorFormatText = "ENTRADA \(vDim.width)×\(vDim.height) → SALIDA 8K 7680×4320 HEVC"
                self.statusBanner = "8K Fluido Metal GPU (\(self.targetFPS) fps) listo"
            case .video8KSensor48MP:
                self.activeSensorFormatText = "SENSOR 48MP \(pDim.width)×\(pDim.height) → RECORTE 1:1 7680×4320"
                self.statusBanner = "8K Puro 48MP (estilo iPhone 5s) listo"
            }
        }
    }

    private func selectBestPhotoFormat(for device: AVCaptureDevice) -> AVCaptureDevice.Format? {
        let candidates = device.formats.filter { fmt in
            let sub = CMFormatDescriptionGetMediaSubType(fmt.formatDescription)
            return sub == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
                || sub == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
                || sub == kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange
        }
        return candidates.max { a, b in
            let maxA = a.supportedMaxPhotoDimensions.map { Int($0.width) * Int($0.height) }.max() ?? 0
            let maxB = b.supportedMaxPhotoDimensions.map { Int($0.width) * Int($0.height) }.max() ?? 0
            return maxA < maxB
        } ?? device.formats.last
    }

    private func selectBestOpenGateVideoFormat(for device: AVCaptureDevice, desiredFPS: Double) -> AVCaptureDevice.Format? {
        let valid = device.formats.filter { fmt in
            let dims = CMVideoFormatDescriptionGetDimensions(fmt.formatDescription)
            let supportsFPS = fmt.videoSupportedFrameRateRanges.contains { $0.maxFrameRate >= desiredFPS }
            return dims.width >= 3840 && supportsFPS
        }
        return valid.max { a, b in
            let da = CMVideoFormatDescriptionGetDimensions(a.formatDescription)
            let db = CMVideoFormatDescriptionGetDimensions(b.formatDescription)
            return (Int(da.width) * Int(da.height)) < (Int(db.width) * Int(db.height))
        } ?? device.formats.last
    }

    private func clampFPS(_ fps: Double, for format: AVCaptureDevice.Format) -> Double {
        guard let range = format.videoSupportedFrameRateRanges.max(by: { $0.maxFrameRate < $1.maxFrameRate }) else {
            return 30
        }
        return min(max(fps, range.minFrameRate), range.maxFrameRate)
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

    // MARK: - Modo 1: Disparo Fotográfico Bayer RAW (.DNG)
    private func shootRawPhoto() {
        sessionQueue.async { [weak self] in
            guard let self, !self.isCapturingPhoto else { return }
            DispatchQueue.main.async {
                self.isCapturingPhoto = true
                self.statusBanner = "Capturando negativo RAW..."
            }

            let errMsg = ObjCCatcher.catchException {
                let settings: AVCapturePhotoSettings
                if let rawFormat = self.photoOutput.availableRawPhotoPixelFormatTypes.first {
                    settings = AVCapturePhotoSettings(rawPixelFormatType: rawFormat)
                } else if self.photoOutput.availablePhotoPixelFormatTypes.contains(kCVPixelFormatType_32BGRA) {
                    settings = AVCapturePhotoSettings(format: [
                        kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA)
                    ])
                } else {
                    settings = AVCapturePhotoSettings(format: [AVVideoCodecKey: AVVideoCodecType.hevc])
                }

                if self.photoOutput.maxPhotoDimensions.width > 0 {
                    _ = ObjCCatcher.catchException {
                        settings.maxPhotoDimensions = self.photoOutput.maxPhotoDimensions
                    }
                }
                _ = ObjCCatcher.catchException {
                    settings.photoQualityPrioritization = self.photoOutput.maxPhotoQualityPrioritization
                }

                self.photoOutput.capturePhoto(with: settings, delegate: self)
            }

            if let errMsg {
                DispatchQueue.main.async {
                    self.isCapturingPhoto = false
                    self.statusBanner = "Error al disparar: \(errMsg)"
                }
            }
        }
    }

    // MARK: - Modos 2 y 3: Grabador de Video 8K (7680x4320 HEVC 120 Mbps)
    private func start8KRecording() {
        sessionQueue.async { [weak self] in
            guard let self, !self.isRecording else { return }

            let tempURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("Raw8K_\(Int(Date().timeIntervalSince1970)).mov")
            try? FileManager.default.removeItem(at: tempURL)

            guard let writer = try? AVAssetWriter(outputURL: tempURL, fileType: .mov) else {
                DispatchQueue.main.async { self.statusBanner = "Error al inicializar codificador 8K" }
                return
            }

            let expectedFPS = (self.mode == .video8KFluid) ? self.targetFPS : (self.isTimelapsePacing48MP ? 30 : 18)
            let compressionProps: [String: Any] = [
                AVVideoAverageBitRateKey: 120_000_000,
                AVVideoExpectedSourceFrameRateKey: expectedFPS,
                AVVideoMaxKeyFrameIntervalKey: expectedFPS * 2,
                AVVideoAllowFrameReorderingKey: false
            ]

            let videoSettings: [String: Any] = [
                AVVideoCodecKey: AVVideoCodecType.hevc,
                AVVideoWidthKey: self.outWidth8K,
                AVVideoHeightKey: self.outHeight8K,
                AVVideoCompressionPropertiesKey: compressionProps
            ]

            let errMsg = ObjCCatcher.catchException {
                let vInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
                vInput.expectsMediaDataInRealTime = true

                let sourceAttrs: [String: Any] = [
                    kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA),
                    kCVPixelBufferWidthKey as String: self.outWidth8K,
                    kCVPixelBufferHeightKey as String: self.outHeight8K,
                    kCVPixelBufferMetalCompatibilityKey as String: true,
                    kCVPixelBufferIOSurfacePropertiesKey as String: [:]
                ]
                let adaptor = AVAssetWriterInputPixelBufferAdaptor(
                    assetWriterInput: vInput,
                    sourcePixelBufferAttributes: sourceAttrs
                )

                if writer.canAdd(vInput) {
                    writer.add(vInput)
                }

                if !self.isTimelapsePacing48MP {
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
                }

                writer.startWriting()
                self.assetWriter = writer
                self.writerVideoInput = vInput
                self.pixelBufferAdaptor = adaptor
                self.recordingStartPTS = nil
                self.burstFrameIndex = 0
            }

            if let errMsg {
                DispatchQueue.main.async {
                    self.statusBanner = "Error 8K HEVC: \(errMsg)"
                }
                return
            }

            DispatchQueue.main.async {
                self.isRecording = true
                self.recordedFramesCount = 0
                self.recordingElapsedSeconds = 0
                self.statusBanner = "GRABANDO 8K (7680×4320 HEVC 120 Mbps)..."
            }

            if self.mode == .video8KSensor48MP {
                self.captureNext48MPBurstFrame()
            }
        }
    }

    private func stop8KRecording() {
        sessionQueue.async { [weak self] in
            guard let self, self.isRecording, let writer = self.assetWriter else { return }
            DispatchQueue.main.async {
                self.isRecording = false
                self.statusBanner = "Cerrando archivo 8K .MOV..."
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
                self.pixelBufferAdaptor = nil

                PHPhotoLibrary.shared().performChanges({
                    PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: outputURL)
                }) { saved, err in
                    try? FileManager.default.removeItem(at: outputURL)
                    DispatchQueue.main.async {
                        if saved {
                            self.statusBanner = "Video 8K (7680×4320) guardado en Fotos (\(self.recordedFramesCount) cuadros)"
                        } else {
                            self.statusBanner = "Error al guardar 8K: \(err?.localizedDescription ?? "desconocido")"
                        }
                    }
                }
            }
        }
    }

    // MARK: - Bucle de Ráfaga 48 MP -> 8K Puro (Método iPhone 5s / Vizzywig)
    private func captureNext48MPBurstFrame() {
        guard isRecording, mode == .video8KSensor48MP else { return }
        _ = ObjCCatcher.catchException {
            let settings = AVCapturePhotoSettings(format: [AVVideoCodecKey: AVVideoCodecType.jpeg])
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
    }

    // MARK: - Procesamiento Metal GPU: Escalado Open Gate o Recorte 1:1 48MP a Buffer 8K (7680x4320)
    private func appendCIImageTo8KWriter(_ sourceImage: CIImage, pts: CMTime) {
        guard let writer = assetWriter,
              writer.status == .writing,
              let vInput = writerVideoInput,
              vInput.isReadyForMoreMediaData,
              let adaptor = pixelBufferAdaptor else {
            return
        }

        if recordingStartPTS == nil {
            recordingStartPTS = pts
            writer.startSession(atSourceTime: pts)
        }

        guard let pool = adaptor.pixelBufferPool else { return }

        var outPixelBuffer: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(nil, pool, &outPixelBuffer) == kCVReturnSuccess,
              let dstBuffer = outPixelBuffer else {
            return
        }

        let extent = sourceImage.extent
        let targetAspect = CGFloat(outWidth8K) / CGFloat(outHeight8K)

        let cropWidth: CGFloat
        let cropHeight: CGFloat
        if extent.width / extent.height > targetAspect {
            cropHeight = extent.height
            cropWidth = cropHeight * targetAspect
        } else {
            cropWidth = extent.width
            cropHeight = cropWidth / targetAspect
        }
        let cropX = extent.origin.x + (extent.width - cropWidth) * 0.5
        let cropY = extent.origin.y + (extent.height - cropHeight) * 0.5
        let cropped = sourceImage
            .cropped(to: CGRect(x: cropX, y: cropY, width: cropWidth, height: cropHeight))
            .transformed(by: CGAffineTransform(translationX: -cropX, y: -cropY))

        let scaleX = CGFloat(outWidth8K) / cropWidth
        let scaleY = CGFloat(outHeight8K) / cropHeight
        let scaled = cropped
            .transformed(by: CGAffineTransform(scaleX: scaleX, y: scaleY))
            .applyingFilter("CISharpenLuminance", parameters: [
                kCIInputSharpnessKey: 0.35,
                kCIInputRadiusKey: 1.4
            ])
            .cropped(to: CGRect(x: 0, y: 0, width: outWidth8K, height: outHeight8K))

        ciContext.render(scaled, to: dstBuffer, bounds: CGRect(x: 0, y: 0, width: outWidth8K, height: outHeight8K), colorSpace: CGColorSpace(name: CGColorSpace.displayP3))

        var appended = false
        _ = ObjCCatcher.catchException {
            appended = adaptor.append(dstBuffer, withPresentationTime: pts)
        }

        if appended {
            let start = recordingStartPTS ?? pts
            let elapsed = max(0, CMTimeGetSeconds(CMTimeSubtract(pts, start)))
            DispatchQueue.main.async {
                self.recordedFramesCount += 1
                self.recordingElapsedSeconds = elapsed
            }
        }
    }

    private func updateTelemetryAndHistogram(from pixelBuffer: CVPixelBuffer) {
        let now = CFAbsoluteTimeGetCurrent()
        frameCounterWindow += 1
        let dt = now - fpsWindowStart
        if dt >= 0.5 {
            let fps = Double(frameCounterWindow) / dt
            frameCounterWindow = 0
            fpsWindowStart = now

            CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
            var bins = [Float](repeating: 0, count: 32)
            if let base = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 0) {
                let w = CVPixelBufferGetWidthOfPlane(pixelBuffer, 0)
                let h = CVPixelBufferGetHeightOfPlane(pixelBuffer, 0)
                let bpr = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 0)
                let ptr = base.assumingMemoryBound(to: UInt8.self)
                let stepX = max(1, w / 48)
                let stepY = max(1, h / 48)
                var samples: Float = 0
                for y in stride(from: 0, to: h, by: stepY) {
                    let row = ptr + y * bpr
                    for x in stride(from: 0, to: w, by: stepX) {
                        let luma = Int(row[x])
                        bins[min(31, luma >> 3)] += 1
                        samples += 1
                    }
                }
                if samples > 0 {
                    let maxBin = max(bins.max() ?? 1, 1)
                    bins = bins.map { max(0.05, $0 / maxBin) }
                }
            }
            CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly)

            DispatchQueue.main.async {
                self.measuredFPS = fps
                self.histogramBins = bins
            }
        }
    }
}

// MARK: - Delegado de Muestras de Video y Audio en Tiempo Real
extension CameraEngine: AVCaptureVideoDataOutputSampleBufferDelegate, AVCaptureAudioDataOutputSampleBufferDelegate {
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        if output === videoDataOutput {
            guard let pb = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
            updateTelemetryAndHistogram(from: pb)

            if isRecording && mode == .video8KFluid {
                let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
                let ciImg = CIImage(cvPixelBuffer: pb)
                appendCIImageTo8KWriter(ciImg, pts: pts)
            }
        } else if output === audioDataOutput {
            guard isRecording,
                  !isTimelapsePacing48MP,
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

// MARK: - Delegado de Captura Fotográfica (Bayer RAW .DNG y Ráfaga 48MP -> 8K)
extension CameraEngine: AVCapturePhotoCaptureDelegate {
    func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
        if mode == .video8KSensor48MP && isRecording {
            if let data = photo.fileDataRepresentation(),
               let ciImg = CIImage(data: data)?.oriented(forExifOrientation: 6) {
                let pts: CMTime
                if isTimelapsePacing48MP {
                    pts = CMTime(value: burstFrameIndex, timescale: 30)
                } else {
                    pts = CMClockGetTime(CMClockGetHostTimeClock())
                }
                burstFrameIndex += 1
                videoQueue.async { [weak self] in
                    self?.appendCIImageTo8KWriter(ciImg, pts: pts)
                }
            }
            sessionQueue.async { [weak self] in
                self?.captureNext48MPBurstFrame()
            }
            return
        }

        // Modo Foto RAW (.DNG nativo o 16-bit sin comprimir)
        var finalData: Data? = photo.fileDataRepresentation()
        var ext = photo.isRawPhoto ? "DNG" : "TIFF"

        if !photo.isRawPhoto, let pb = photo.pixelBuffer {
            let ciImg = CIImage(cvPixelBuffer: pb).oriented(forExifOrientation: 6)
            if let colorSpace = CGColorSpace(name: CGColorSpace.displayP3),
               let tiffData = ciContext.tiffRepresentation(of: ciImg, format: .RGBA16, colorSpace: colorSpace, options: [:]) {
                finalData = tiffData
                ext = "TIFF"
            }
        }

        guard let data = finalData else {
            DispatchQueue.main.async {
                self.isCapturingPhoto = false
                self.statusBanner = "Error en captura RAW: \(error?.localizedDescription ?? "sin datos")"
            }
            return
        }

        let filename = "IMG_\(Int(Date().timeIntervalSince1970))_RAW8K.\(ext)"

        PHPhotoLibrary.shared().performChanges({
            let req = PHAssetCreationRequest.forAsset()
            let opts = PHAssetResourceCreationOptions()
            opts.originalFilename = filename
            req.addResource(with: .photo, data: data, options: opts)
        }) { saved, err in
            DispatchQueue.main.async {
                self.isCapturingPhoto = false
                let sizeMB = String(format: "%.1f MB", Double(data.count) / (1024 * 1024))
                if saved {
                    self.statusBanner = "Guardado \(filename) (\(sizeMB)) en Fotos"
                } else {
                    self.statusBanner = "Error al guardar \(ext): \(err?.localizedDescription ?? "")"
                }
            }
        }
    }
}
