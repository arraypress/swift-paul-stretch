//
//  LiveEffectNode.swift
//  SwiftPaulStretch
//
//  An AVAudioEngine node that runs LiveEffectChain, so the library's own
//  DSP sits in the graph next to the Apple effects instead of being baked
//  into the playback buffer.
//
//  Created by David Sherlock on 7/27/26.
//

import Foundation
import AVFAudio
import AudioToolbox
import PaulStretch

#if !os(watchOS)

/// The `AUAudioUnit` that runs a ``LiveEffectChain`` in its render block.
///
/// `AVAudioEngine` offers no way to drop arbitrary Swift DSP into a chain —
/// `AVAudioUnitEffect` wraps a registered `AudioComponent`, not a closure —
/// so the DSP is packaged as a v3 audio unit registered in-process.
public final class LiveEffectAudioUnit: AUAudioUnit {

    private var inBusses: AUAudioUnitBusArray!
    private var outBusses: AUAudioUnitBusArray!
    private let inBus: AUAudioUnitBus
    private let outBus: AUAudioUnitBus

    /// Scratch the render block reuses, so the per-quantum `[Float]` pair is
    /// not freshly allocated on top of what the stages already allocate.
    private var scratchL: [Float] = []
    private var scratchR: [Float] = []
    /// Exactly-quantum-sized buffers handed to the chain.
    ///
    /// `render` takes `[Float]` sized to the quantum, and slicing the scratch
    /// buffers to build them — `Array(scratchL[0..<n])` — ALLOCATED twice per
    /// quantum on the audio thread. `malloc` can take a lock, and a blocked
    /// audio thread is a dropout; it is also pure waste at 86 quanta a second
    /// per layer. These are resized only when the quantum size changes, which
    /// happens once.
    private var workL: [Float] = []
    private var workR: [Float] = []

    /// Backing store for the output bus when the host hands us null pointers.
    private var ownedBuffer: AVAudioPCMBuffer?

    /// The DSP. Set before the engine starts; read on the audio thread.
    public var chain: LiveEffectChain?

    /// Creates the unit with a stereo 44.1 kHz default format.
    ///
    /// The engine re-negotiates the bus format on connection, so this is
    /// only the starting point.
    ///
    /// - Parameters:
    ///   - componentDescription: The registered component description.
    ///   - options: Instantiation options.
    public override init(componentDescription: AudioComponentDescription,
                         options: AudioComponentInstantiationOptions = []) throws {
        let format = AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 2)!
        inBus = try AUAudioUnitBus(format: format)
        outBus = try AUAudioUnitBus(format: format)
        try super.init(componentDescription: componentDescription, options: options)
        inBusses = AUAudioUnitBusArray(audioUnit: self, busType: .input, busses: [inBus])
        outBusses = AUAudioUnitBusArray(audioUnit: self, busType: .output, busses: [outBus])
        maximumFramesToRender = 4096
    }

    /// The single input bus.
    public override var inputBusses: AUAudioUnitBusArray { inBusses }

    /// The single output bus.
    public override var outputBusses: AUAudioUnitBusArray { outBusses }

    /// Preallocates the render scratch, so the audio thread never has to.
    public override func allocateRenderResources() throws {
        try super.allocateRenderResources()
        let n = Int(maximumFramesToRender)
        workL = [Float](repeating: 0, count: n)
        workR = [Float](repeating: 0, count: n)
        scratchL = [Float](repeating: 0, count: n)
        scratchR = [Float](repeating: 0, count: n)
        ownedBuffer = AVAudioPCMBuffer(pcmFormat: outBus.format,
                                       frameCapacity: maximumFramesToRender)
    }

    /// Releases the render scratch.
    public override func deallocateRenderResources() {
        ownedBuffer = nil
        scratchL = []; scratchR = []
        workL = []; workR = []
        super.deallocateRenderResources()
    }

    /// The render block. Pulls upstream audio into the output buffers and
    /// processes it in place through ``chain``.
    ///
    /// Runs on the audio thread: no locks are taken and nothing here can
    /// block. If the chain is absent or empty the audio passes through
    /// untouched.
    public override var internalRenderBlock: AUInternalRenderBlock {
        // Captured unowned: the render block's lifetime is bounded by the
        // unit's, and a `weak` read would retain/release on the audio thread.
        { [unowned self] _, timestamp, frameCount, _, outputData, _, pullInput in
            guard let pullInput else { return kAudioUnitErr_NoConnection }

            let ablOut = UnsafeMutableAudioBufferListPointer(outputData)

            // A v3 unit may be handed an output list with null `mData`, in
            // which case it must supply its own storage.
            if ablOut.count > 0, ablOut[0].mData == nil {
                guard let owned = ownedBuffer else { return kAudioUnitErr_Uninitialized }
                let ablOwned = UnsafeMutableAudioBufferListPointer(owned.mutableAudioBufferList)
                let bytes = frameCount * UInt32(MemoryLayout<Float>.size)
                for i in 0..<min(ablOut.count, ablOwned.count) {
                    ablOut[i].mData = ablOwned[i].mData
                    ablOut[i].mDataByteSize = bytes
                    ablOut[i].mNumberChannels = 1
                }
            }

            // Pull upstream audio directly into the output list and process
            // it in place — an effect needs no separate input buffer.
            var flags = AudioUnitRenderActionFlags()
            let status = pullInput(&flags, timestamp, frameCount, 0, outputData)
            guard status == noErr else { return status }

            guard let chain, !chain.isEmpty else { return noErr }

            let n = Int(frameCount)
            guard n <= scratchL.count, ablOut.count >= 2,
                  let lp = ablOut[0].mData?.assumingMemoryBound(to: Float.self),
                  let rp = ablOut[1].mData?.assumingMemoryBound(to: Float.self)
            else { return noErr }   // mono or oversized quantum: pass through

            // `render` wants arrays sized exactly to the quantum. Reused, not
            // rebuilt: slicing allocated two arrays per quantum on the audio
            // thread. A short quantum only happens at the very end of a stream,
            // and resizing then is a single allocation rather than one per
            // callback.
            if workL.count != n {
                workL = [Float](repeating: 0, count: n)
                workR = [Float](repeating: 0, count: n)
            }
            workL.withUnsafeMutableBufferPointer { $0.baseAddress!.update(from: lp, count: n) }
            workR.withUnsafeMutableBufferPointer { $0.baseAddress!.update(from: rp, count: n) }
            chain.render(l: &workL, r: &workR)
            workL.withUnsafeBufferPointer { lp.update(from: $0.baseAddress!, count: n) }
            workR.withUnsafeBufferPointer { rp.update(from: $0.baseAddress!, count: n) }

            return noErr
        }
    }
}

/// Wraps ``LiveEffectAudioUnit`` as an `AVAudioNode` that can be attached to
/// an `AVAudioEngine`.
///
/// Registration is a one-shot side effect keyed on a private component
/// subtype; `AVAudioUnit.instantiate` then finds it in-process without ever
/// touching the on-disk component registry.
public enum LiveEffectNode {

    private static let subType: OSType = 0x6C766678       // 'lvfx'
    private static let manufacturer: OSType = 0x50535458  // 'PSTX'

    private static let description = AudioComponentDescription(
        componentType: kAudioUnitType_Effect,
        componentSubType: subType,
        componentManufacturer: manufacturer,
        componentFlags: 0, componentFlagsMask: 0)

    private static var registered = false
    private static let registerLock = NSLock()

    private static func registerIfNeeded() {
        registerLock.lock()
        defer { registerLock.unlock() }
        guard !registered else { return }
        AUAudioUnit.registerSubclass(LiveEffectAudioUnit.self,
                                     as: description,
                                     name: "PaulStretch Live Effects",
                                     version: 1)
        registered = true
    }

    /// Creates a node running `chain`.
    ///
    /// - Parameter chain: The DSP the node should run.
    /// - Returns: The node, or `nil` if the audio unit could not be created.
    public static func make(chain: LiveEffectChain) async -> AVAudioUnit? {
        registerIfNeeded()
        let node: AVAudioUnit? = await withCheckedContinuation { cont in
            AVAudioUnit.instantiate(with: description, options: []) { unit, _ in
                cont.resume(returning: unit)
            }
        }
        guard let node else { return nil }
        (node.auAudioUnit as? LiveEffectAudioUnit)?.chain = chain
        return node
    }
}

#endif  // !os(watchOS)
