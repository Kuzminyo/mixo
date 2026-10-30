import CoreAudio
import Foundation
import Synchronization

struct AudioError: LocalizedError {
    let step: String
    let status: OSStatus

    var errorDescription: String? { "\(step) failed (\(status))" }
}

private func check(_ status: OSStatus, _ step: String) throws {
    guard status == noErr else { throw AudioError(step: step, status: status) }
}

/// Gain shared between the UI and the real-time audio thread.
final class GainControl: Sendable {
    private let target = Atomic<UInt32>(Float(1).bitPattern)

    var value: Float {
        get { Float(bitPattern: target.load(ordering: .relaxed)) }
        set { target.store(newValue.bitPattern, ordering: .relaxed) }
    }
}

/// Routes one app's sound through Mixo so its volume can be changed.
///
/// A process tap captures the app's audio and silences the original; a private aggregate
/// device reads the tap and plays it on the real output device with the chosen gain.
final class AppTap {
    let processes: Set<AudioObjectID>
    let outputUID: String

    private let gain = GainControl()
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?

    init(processes: Set<AudioObjectID>, outputUID: String, gain value: Float) throws {
        self.processes = processes
        self.outputUID = outputUID
        gain.value = value

        do {
            try start()
        } catch {
            stop()
            throw error
        }
    }

    deinit {
        stop()
    }

    func setGain(_ value: Float) {
        gain.value = value
    }

    private func start() throws {
        let description = CATapDescription(stereoMixdownOfProcesses: Array(processes))
        description.uuid = UUID()
        description.muteBehavior = .mutedWhenTapped
        description.isPrivate = true
        try check(AudioHardwareCreateProcessTap(description, &tapID), "Create tap")

        let aggregate: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Mixo",
            kAudioAggregateDeviceUIDKey: "com.kuzminyo.mixo.\(UUID().uuidString)",
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outputUID]],
            kAudioAggregateDeviceTapListKey: [[
                kAudioSubTapDriftCompensationKey: true,
                kAudioSubTapUIDKey: description.uuid.uuidString,
            ]],
        ]
        try check(AudioHardwareCreateAggregateDevice(aggregate as CFDictionary, &aggregateID), "Create aggregate device")

        let gain = self.gain
        let renderer = Renderer()
        try check(AudioDeviceCreateIOProcIDWithBlock(&procID, aggregateID, nil) { _, input, _, output, _ in
            renderer.render(target: gain.value, input: input, output: output)
        }, "Create IO proc")
        try check(AudioDeviceStart(aggregateID, procID), "Start device")
    }

    private func stop() {
        if aggregateID != kAudioObjectUnknown {
            if let procID {
                AudioDeviceStop(aggregateID, procID)
                AudioDeviceDestroyIOProcID(aggregateID, procID)
            }
            AudioHardwareDestroyAggregateDevice(aggregateID)
        }
        if tapID != kAudioObjectUnknown {
            AudioHardwareDestroyProcessTap(tapID)
        }
        procID = nil
        aggregateID = AudioObjectID(kAudioObjectUnknown)
        tapID = AudioObjectID(kAudioObjectUnknown)
    }
}

/// Copies tapped samples to the output with gain. Runs on the real-time audio thread,
/// so it never allocates and ramps the gain across each buffer to avoid clicks.
private final class Renderer: @unchecked Sendable {
    private var current: Float = -1

    func render(target: Float, input: UnsafePointer<AudioBufferList>, output: UnsafeMutablePointer<AudioBufferList>) {
        let inputs = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
        let outputs = UnsafeMutableAudioBufferListPointer(output)
        if current < 0 { current = target }
        let start = current

        var outputChannel = 0
        for buffer in outputs {
            let channels = Int(buffer.mNumberChannels)
            guard channels > 0, let data = buffer.mData else { continue }
            let out = data.assumingMemoryBound(to: Float.self)
            let frames = Int(buffer.mDataByteSize) / (MemoryLayout<Float>.size * channels)
            let step = frames > 0 ? (target - start) / Float(frames) : 0

            for channel in 0..<channels {
                guard let source = Self.channel(outputChannel + channel, in: inputs) else {
                    for frame in 0..<frames { out[frame * channels + channel] = 0 }
                    continue
                }
                let count = min(frames, source.frames)
                for frame in 0..<count {
                    out[frame * channels + channel] = source.samples[frame * source.stride] * (start + step * Float(frame))
                }
                for frame in count..<frames { out[frame * channels + channel] = 0 }
            }
            outputChannel += channels
        }
        current = target
    }

    private static func channel(
        _ index: Int,
        in buffers: UnsafeMutableAudioBufferListPointer
    ) -> (samples: UnsafeMutablePointer<Float>, stride: Int, frames: Int)? {
        var remaining = index
        for buffer in buffers {
            let channels = Int(buffer.mNumberChannels)
            if remaining < channels, let data = buffer.mData {
                let frames = Int(buffer.mDataByteSize) / (MemoryLayout<Float>.size * channels)
                return (data.assumingMemoryBound(to: Float.self) + remaining, channels, frames)
            }
            remaining -= channels
        }
        return nil
    }
}
