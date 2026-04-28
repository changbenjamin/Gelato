import AVFoundation
import CoreAudio
import FluidAudio
import Observation
import os

/// Simple file logger for diagnostics — writes to /tmp/opengranola.log
func diagLog(_ msg: String) {
    let line = "\(Date()): \(msg)\n"
    let path = "/tmp/opengranola.log"
    if let fh = FileHandle(forWritingAtPath: path) {
        fh.seekToEndOfFile()
        fh.write(line.data(using: .utf8)!)
        fh.closeFile()
    } else {
        FileManager.default.createFile(atPath: path, contents: line.data(using: .utf8))
    }
}

/// Orchestrates dual StreamingTranscriber instances for mic (you) and system audio (them).
@Observable
@MainActor
final class TranscriptionEngine {
    private(set) var isRunning = false
    private(set) var assetStatus: String = "Ready"
    private(set) var lastError: String?

    private let systemCapture = SystemAudioCapture()
    private let micCapture = MicCapture()
    private let transcriptStore: TranscriptStore
    private var audioRecorder: SessionAudioRecorder?
    private var currentSessionStart: Date?

    /// Audio level from mic for the UI meter.
    var audioLevel: Float { max(micAudioLevel, systemAudioLevel) }
    var micAudioLevel: Float { micCapture.audioLevel }
    var systemAudioLevel: Float { systemCapture.audioLevel }

    private var micTask: Task<Void, Never>?
    private var sysTask: Task<Void, Never>?
    /// Keeps the mic stream alive for the audio level meter when transcription isn't running.
    private var micKeepAliveTask: Task<Void, Never>?

    /// Shared FluidAudio instances
    private var asrManager: AsrManager?
    private var vadManager: VadManager?

    /// Tracks the resolved mic device ID currently in use.
    private var currentMicDeviceID: AudioDeviceID = 0

    /// Tracks whether user selected automatic mic selection (0) or a specific device.
    private var userSelectedDeviceID: AudioDeviceID = 0

    /// Listens for default input device changes at the OS level.
    private var defaultDeviceListenerBlock: AudioObjectPropertyListenerBlock?
    /// Listens for default output device changes so the system-audio tap follows speaker swaps.
    private var defaultOutputDeviceListenerBlock: AudioObjectPropertyListenerBlock?
    /// Debounced mic restart task — cancelled and recreated on each device change notification
    /// so that rapid-fire events (e.g. AirPods disconnect triggers both input + output changes)
    /// collapse into a single restart.
    private var micRestartTask: Task<Void, Never>?
    /// Queued system-capture restart task. Output swaps can fire multiple
    /// notifications back-to-back; only one restart loop may own the tap.
    private var systemRestartTask: Task<Void, Never>?
    /// Remembers that another output-change notification arrived while a
    /// restart was pending or in flight.
    private var pendingSystemRestart = false

    init(transcriptStore: TranscriptStore) {
        self.transcriptStore = transcriptStore
    }

    func start(
        locale: Locale,
        inputDeviceID: AudioDeviceID = 0,
        sessionStart: Date = .now,
        audioRecorder: SessionAudioRecorder? = nil
    ) async {
        diagLog("[ENGINE-0] start() called, isRunning=\(isRunning)")
        guard !isRunning else { return }
        lastError = nil
        self.audioRecorder = audioRecorder
        self.currentSessionStart = sessionStart

        guard await ensureMicrophonePermission() else { return }

        isRunning = true

        // 1. Load FluidAudio models
        assetStatus = "Loading ASR model (~600MB first run)..."
        diagLog("[ENGINE-1] loading FluidAudio ASR models...")
        do {
            let models = try await AsrModels.downloadAndLoad(version: .v2)
            assetStatus = "Initializing ASR..."
            let asr = AsrManager(config: .default)
            try await asr.initialize(models: models)
            self.asrManager = asr

            assetStatus = "Loading VAD model..."
            diagLog("[ENGINE-1b] loading VAD model...")
            let vad = try await VadManager()
            self.vadManager = vad

            assetStatus = "Models ready"
            diagLog("[ENGINE-2] FluidAudio models loaded")
        } catch {
            let msg = "Failed to load models: \(error.localizedDescription)"
            diagLog("[ENGINE-2-FAIL] \(msg)")
            lastError = msg
            assetStatus = "Ready"
            isRunning = false
            return
        }

        guard let asrManager, let vadManager else { return }

        let audioRecorder = self.audioRecorder

        // 2. Start system audio capture first so we fail fast if "Them" audio
        // can't be captured for this session.
        diagLog("[ENGINE-3] starting system audio capture")
        let sysStreams: SystemAudioCapture.CaptureStreams
        do {
            sysStreams = try await systemCapture.bufferStream(
                onSystemBuffer: { capturedBuffer in
                    audioRecorder?.appendSystemBuffer(capturedBuffer)
                }
            )
        } catch {
            let msg = "System audio capture failed: \(error.localizedDescription)"
            diagLog("[ENGINE-3-FAIL] \(msg)")
            lastError = msg
            assetStatus = "Ready"
            isRunning = false
            return
        }

        // 3. Start mic capture
        userSelectedDeviceID = inputDeviceID
        let targetMicID = inputDeviceID > 0 ? inputDeviceID : MicCapture.automaticInputDeviceID()
        currentMicDeviceID = targetMicID ?? 0
        if inputDeviceID == 0 {
            diagLog("[ENGINE-4] automatic mic resolved to \(String(describing: targetMicID)) (\(MicCapture.automaticInputDeviceName() ?? "unknown"))")
        } else {
            diagLog("[ENGINE-4] starting mic capture, targetMicID=\(String(describing: targetMicID))")
        }
        let micStream = micCapture.bufferStream(
            deviceID: targetMicID,
            onBuffer: { capturedBuffer in
                audioRecorder?.appendMicBuffer(capturedBuffer)
            }
        )

        // 4. Start mic transcription
        let store = transcriptStore
        let micTranscriber = StreamingTranscriber(
            asrManager: asrManager,
            vadManager: vadManager,
            speaker: .you,
            sessionStart: sessionStart,
            onPartial: { text in
                Task { @MainActor in store.volatileYouText = text }
            },
            onFinal: { text, timestamp in
                Task { @MainActor in
                    store.volatileYouText = ""
                    store.append(Utterance(text: text, speaker: .you, timestamp: timestamp))
                }
            }
        )
        micTask = Task.detached {
            await micTranscriber.run(stream: micStream)
        }

        // 5. Start system audio transcription
        let sysTranscriber = StreamingTranscriber(
            asrManager: asrManager,
            vadManager: vadManager,
            speaker: .them,
            sessionStart: sessionStart,
            segmentationConfig: Self.systemVadSegmentationConfig,
            inputGain: Self.systemInputGain,
            onPartial: { text in
                Task { @MainActor in store.volatileThemText = text }
            },
            onFinal: { text, timestamp in
                Task { @MainActor in
                    store.volatileThemText = ""
                    store.append(Utterance(text: text, speaker: .them, timestamp: timestamp))
                }
            }
        )
        sysTask = Task.detached {
            await sysTranscriber.run(stream: sysStreams.systemAudio)
        }

        assetStatus = "Transcribing (Parakeet-TDT v2)"
        diagLog("[ENGINE-6] all transcription tasks started")

        // Install CoreAudio listener for default input device changes
        installDefaultDeviceListener()
        installDefaultOutputDeviceListener()
    }

    /// Schedule a debounced mic restart. Multiple calls within 300ms collapse into one,
    /// coalescing the input + output device change notifications that fire simultaneously
    /// when AirPods connect/disconnect.
    private func scheduleMicRestart() {
        micRestartTask?.cancel()
        micRestartTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            guard let self, !Task.isCancelled, self.isRunning else { return }
            let requestedMicID = self.userSelectedDeviceID
            self.restartMic(inputDeviceID: requestedMicID, force: true)
        }
    }

    /// Queue a system restart. This follows OpenOats' stream-first shutdown:
    /// finish the old stream, wait for its transcriber to exit, then tear down
    /// the CoreAudio tap before creating a new one.
    private func restartSystemCapture() {
        guard isRunning else { return }
        pendingSystemRestart = true
        guard systemRestartTask == nil else {
            diagLog("[ENGINE-SYS-SWAP] restart already running; queued another pass")
            return
        }

        systemRestartTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.systemRestartTask = nil }

            while self.isRunning, self.pendingSystemRestart, !Task.isCancelled {
                self.pendingSystemRestart = false
                await self.performSystemCaptureRestart()
            }
        }
    }

    /// Restart only the mic capture with a new device, keeping system audio and models intact.
    /// Pass the raw setting value (0 = automatic selection, or a specific AudioDeviceID).
    func restartMic(inputDeviceID: AudioDeviceID, force: Bool = false) {
        guard isRunning, let asrManager, let vadManager else { return }

        if inputDeviceID != 0 || userSelectedDeviceID != 0 {
            userSelectedDeviceID = inputDeviceID
        }
        let targetMicID = inputDeviceID > 0 ? inputDeviceID : MicCapture.automaticInputDeviceID() ?? 0
        guard force || targetMicID != currentMicDeviceID else {
            diagLog("[ENGINE-MIC-SWAP] same device \(targetMicID), skipping")
            return
        }

        diagLog("[ENGINE-MIC-SWAP] switching mic from \(currentMicDeviceID) to \(targetMicID)")

        // Tear down old mic
        micCapture.finishStream()
        micTask?.cancel()
        micTask = nil
        micCapture.stop()

        currentMicDeviceID = targetMicID

        // Start new mic stream — makeFreshEngine() inside bufferStream handles
        // format negotiation automatically, no stabilization delay needed.
        let audioRecorder = self.audioRecorder
        let micStream = micCapture.bufferStream(
            deviceID: targetMicID,
            onBuffer: { capturedBuffer in
                audioRecorder?.appendMicBuffer(capturedBuffer)
            }
        )
        let store = transcriptStore
        let micTranscriber = StreamingTranscriber(
            asrManager: asrManager,
            vadManager: vadManager,
            speaker: .you,
            sessionStart: currentSessionStart ?? .now,
            onPartial: { text in
                Task { @MainActor in store.volatileYouText = text }
            },
            onFinal: { text, timestamp in
                Task { @MainActor in
                    store.volatileYouText = ""
                    store.append(Utterance(text: text, speaker: .you, timestamp: timestamp))
                }
            }
        )
        micTask = Task.detached {
            await micTranscriber.run(stream: micStream)
        }

        diagLog("[ENGINE-MIC-SWAP] mic restarted on device \(targetMicID)")
    }

    // MARK: - Default Device Listener

    private func installDefaultDeviceListener() {
        guard defaultDeviceListenerBlock == nil else { return }

        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            guard let self else { return }
            Task { @MainActor in
                guard self.isRunning, self.userSelectedDeviceID == 0 else { return }
                diagLog("[ENGINE-DEVICE-CHANGE] default input device changed, scheduling mic restart")
                self.scheduleMicRestart()
            }
        }
        defaultDeviceListenerBlock = block

        AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            DispatchQueue.main,
            block
        )
    }

    private func installDefaultOutputDeviceListener() {
        guard defaultOutputDeviceListenerBlock == nil else { return }

        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            guard let self else { return }
            Task { @MainActor in
                guard self.isRunning else { return }
                diagLog("[ENGINE-DEVICE-CHANGE] default output device changed, scheduling system + mic restart")
                self.restartSystemCapture()
                self.scheduleMicRestart()
            }
        }
        defaultOutputDeviceListenerBlock = block

        AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            DispatchQueue.main,
            block
        )
    }

    private func removeDefaultDeviceListener() {
        guard let block = defaultDeviceListenerBlock else { return }
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        AudioObjectRemovePropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            DispatchQueue.main,
            block
        )
        defaultDeviceListenerBlock = nil
    }

    private func removeDefaultOutputDeviceListener() {
        guard let block = defaultOutputDeviceListenerBlock else { return }
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        AudioObjectRemovePropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            DispatchQueue.main,
            block
        )
        defaultOutputDeviceListenerBlock = nil
    }

    private func performSystemCaptureRestart() async {
        guard isRunning, let asrManager, let vadManager else { return }

        diagLog("[ENGINE-SYS-SWAP] restarting system capture for output device change")
        systemCapture.finishStream()
        await sysTask?.value
        guard isRunning, !Task.isCancelled else { return }
        sysTask = nil

        let audioRecorder = self.audioRecorder
        await systemCapture.stop()

        // Reset the audio recorder's system format so it doesn't try to convert
        // new-device audio to the old-device format using a wrong sample rate.
        audioRecorder?.resetSystemFormat()

        do {
            let sysStreams = try await systemCapture.bufferStream(
                onSystemBuffer: { capturedBuffer in
                    audioRecorder?.appendSystemBuffer(capturedBuffer)
                }
            )
            let store = transcriptStore
            let sysTranscriber = StreamingTranscriber(
                asrManager: asrManager,
                vadManager: vadManager,
                speaker: .them,
                sessionStart: currentSessionStart ?? .now,
                segmentationConfig: Self.systemVadSegmentationConfig,
                inputGain: Self.systemInputGain,
                onPartial: { text in
                    Task { @MainActor in store.volatileThemText = text }
                },
                onFinal: { text, timestamp in
                    Task { @MainActor in
                        store.volatileThemText = ""
                        store.append(Utterance(text: text, speaker: .them, timestamp: timestamp))
                    }
                }
            )
            sysTask = Task.detached {
                await sysTranscriber.run(stream: sysStreams.systemAudio)
            }
            diagLog("[ENGINE-SYS-SWAP] system capture restarted")
        } catch {
            let msg = "System audio capture restart failed: \(error.localizedDescription)"
            diagLog("[ENGINE-SYS-SWAP-FAIL] \(msg)")
            lastError = msg
        }
    }

    private func ensureMicrophonePermission() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            return true
        case .notDetermined:
            let granted = await AVCaptureDevice.requestAccess(for: .audio)
            if !granted {
                lastError = "Microphone access denied. Enable it in System Settings > Privacy & Security > Microphone."
                assetStatus = "Ready"
            }
            return granted
        case .denied, .restricted:
            lastError = "Microphone access is disabled. Enable it in System Settings > Privacy & Security > Microphone."
            assetStatus = "Ready"
            return false
        @unknown default:
            lastError = "Unable to verify microphone permission."
            assetStatus = "Ready"
            return false
        }
    }

    func stop() async {
        diagLog("[ENGINE-STOP] begin")
        removeDefaultDeviceListener()
        removeDefaultOutputDeviceListener()
        micRestartTask?.cancel()
        micRestartTask = nil
        systemRestartTask?.cancel()
        systemRestartTask = nil
        pendingSystemRestart = false
        let micTask = self.micTask
        let sysTask = self.sysTask
        self.micKeepAliveTask?.cancel()
        self.micTask = nil
        self.sysTask = nil
        self.micKeepAliveTask = nil
        isRunning = false
        assetStatus = "Ready"

        micCapture.finishStream()
        systemCapture.finishStream()
        micTask?.cancel()
        sysTask?.cancel()
        await micTask?.value
        await sysTask?.value

        micCapture.stop()

        let systemCapture = self.systemCapture
        let recorder = audioRecorder
        audioRecorder = nil
        currentSessionStart = nil
        currentMicDeviceID = 0

        await Task.detached(priority: .userInitiated) {
            await systemCapture.stop()
            _ = recorder?.finish()
        }.value
        diagLog("[ENGINE-STOP] recorder finished")
        diagLog("[ENGINE-STOP] end")
    }

    private static let systemInputGain: Float = 2.5

    private static let systemVadSegmentationConfig = VadSegmentationConfig(
        minSpeechDuration: 0.12,
        minSilenceDuration: 0.45,
        maxSpeechDuration: 14.0,
        speechPadding: 0.1,
        silenceThresholdForSplit: 0.25,
        negativeThreshold: 0.23,
        negativeThresholdOffset: 0.22,
        minSilenceAtMaxSpeech: 0.098,
        useMaxPossibleSilenceAtMaxSpeech: true
    )
}
