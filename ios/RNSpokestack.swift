import Spokestack

enum RNSpokestackError: Error {
    case notInitialized
    case notStarted
    case builderNotAvailable
    case downloaderNotAvailable
    case downloadFailed
}

extension RNSpokestackError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .notInitialized:
            return NSLocalizedString("Spokestack has not yet been initialized. Call Spokestack.initialize()", comment: "")
        case .notStarted:
            return NSLocalizedString("Spokestack has not yet been started. Call Spokestack.start() before calling Spokestack.activate().", comment: "")
        case .builderNotAvailable:
            return NSLocalizedString("buildPipeline() was called somehow without first initializing a builder", comment: "")
        case .downloaderNotAvailable:
            return NSLocalizedString("Models were passed to initialize that could not be downloaded. The downloader was not initialized properly.", comment: "")
        case .downloadFailed:
            return NSLocalizedString("A download callback was called, but there were no arguments. Check the code for the bad path.", comment: "")
        }
    }
}

enum RNSpokestackPromise: String {
    case initialize
    case start
    case stop
    case activate
    case deactivate
    case synthesize
    case speak
    case classify
}

internal enum NLUDownloadProp: String, CaseIterable {
    case nluModelPath
    case nluModelMetadataPath
    case nluVocabularyPath
}

internal enum WakewordDownloadProp: String, CaseIterable {
    case detectModelPath
    case encodeModelPath
    case filterModelPath
}

internal enum KeywordDownloadProp: String, CaseIterable {
    case keywordDetectModelPath
    case keywordEncodeModelPath
    case keywordFilterModelPath
    case keywordMetadataPath
}

@objc(RNSpokestack)
class RNSpokestack: RCTEventEmitter, SpokestackDelegate {
    var speechPipelineBuilder: SpeechPipelineBuilder?
    var speechPipeline: SpeechPipeline?
    var speechConfig: SpeechConfiguration = SpeechConfiguration()
    var speechContext: SpeechContext?
    var synthesizer: TextToSpeech?
    var classifier: NLUTensorflow?
    var started = false
    var resolvers: [RNSpokestackPromise:RCTPromiseResolveBlock] = [:]
    var rejecters: [RNSpokestackPromise:RCTPromiseRejectBlock] = [:]
    var makeClassifer = false
    var downloader: Downloader?
    var numRequests = 0

    @objc
    override static func requiresMainQueueSetup() -> Bool {
        return true
    }

    override func supportedEvents() -> [String]! {
        return ["activate", "deactivate", "start", "stop", "timeout", "recognize", "partial_recognize", "play", "error", "trace"]
    }

    func handleError(_ error: Error) -> Void {
        print(error)
        sendEvent(withName: "error", body: [ "error": error.localizedDescription ])
    }

    func failure(error: Error) {
        handleError(error)

        // Reject all existing promises
        for (key, reject) in rejecters {
            let value = key.rawValue
            reject(String(format: "%@_error", value), String(format: "Spokestack error during %@.", value), error)
        }
        // Reset
        resolvers = [:]
        rejecters = [:]
    }
    
    func notInitialized(_ reject: RCTPromiseRejectBlock, module: String) {
        reject(
            "not_initialized",
            "\(module) is not initialized. Call Spokestack.initialize() first.",
            RNSpokestackError.notInitialized
        )
    }

    func didTrace(_ trace: String) {
        sendEvent(withName: "trace", body: [ "message": trace ])
    }

    func didInit() {
        if let resolve = resolvers.removeValue(forKey: RNSpokestackPromise.initialize) {
            resolve(nil)
            rejecters.removeValue(forKey: RNSpokestackPromise.initialize)
        }
    }

    func didActivate() {
        if let resolve = resolvers.removeValue(forKey: RNSpokestackPromise.activate) {
            resolve(nil)
            rejecters.removeValue(forKey: RNSpokestackPromise.activate)
        }
        sendEvent(withName: "activate", body: [ "transcript": "" ])
    }

    func didDeactivate() {
        if let resolve = resolvers.removeValue(forKey: RNSpokestackPromise.deactivate) {
            resolve(nil)
            rejecters.removeValue(forKey: RNSpokestackPromise.deactivate)
        }
        sendEvent(withName: "deactivate", body: [ "transcript": "" ])
    }

    func didStart() {
        started = true
        if let resolve = resolvers.removeValue(forKey: RNSpokestackPromise.start) {
            resolve(nil)
            rejecters.removeValue(forKey: RNSpokestackPromise.start)
        }
        sendEvent(withName: "start", body: [ "transcript": "" ])
    }

    func didStop() {
        started = false
        if let resolve = resolvers.removeValue(forKey: RNSpokestackPromise.stop) {
            resolve(nil)
            rejecters.removeValue(forKey: RNSpokestackPromise.stop)
        }
        sendEvent(withName: "stop", body: [ "transcript": "" ])
    }

    func didTimeout() {
        sendEvent(withName: "timeout", body: [ "transcript": "" ])
    }

    func didRecognize(_ result: SpeechContext) {
        sendEvent(withName: "recognize", body: [ "transcript": result.transcript ])
    }

    func didRecognizePartial(_ result: SpeechContext) {
        sendEvent(withName: "partial_recognize", body: [ "transcript": result.transcript ])
    }

    func success(result: TextToSpeechResult) {
        if let resolve = resolvers.removeValue(forKey: RNSpokestackPromise.synthesize) {
            resolve(result.url?.absoluteString)
            rejecters.removeValue(forKey: RNSpokestackPromise.synthesize)
        } else if let resolve = resolvers.removeValue(forKey: RNSpokestackPromise.speak) {
            resolve(nil)
            rejecters.removeValue(forKey: RNSpokestackPromise.speak)
        }
    }

    func classification(result: NLUResult) {
        if let resolve = resolvers.removeValue(forKey: RNSpokestackPromise.classify) {
            var slots: [String:[String:Any?]] = [:]
            if let resultSlots = result.slots {
                for (name, slot) in resultSlots {
                    var value: Any?
                    if let v = slot.value as? Int {
                        value = RCTConvert.int(v)
                    } else if let v = slot.value as? Float {
                        value = RCTConvert.float(v)
                    } else if let v = slot.value as? Double {
                        value = RCTConvert.double(v)
                    } else if let v = slot.value as? Bool {
                        value = RCTConvert.bool(v)
                    } else {
                        value = RCTConvert.nsString(slot.value)
                    }
                    slots[name] = [
                        "type": slot.type,
                        "value": value,
                        "rawValue": RCTConvert.nsString(slot.rawValue)
                    ]
                }
            }

            resolve([
                "intent": result.intent,
                "confidence": result.confidence,
                "slots": slots
            ])
            rejecters.removeValue(forKey: RNSpokestackPromise.classify)
        }
    }

    func didBeginSpeaking() {
        if let resolve = resolvers.removeValue(forKey: RNSpokestackPromise.speak) {
            resolve(nil)
            rejecters.removeValue(forKey: RNSpokestackPromise.speak)
        }
        sendEvent(withName: "play", body: [ "playing": true ])
    }

    func didFinishSpeaking() {
        sendEvent(withName: "play", body: [ "playing": false ])
    }

    func makeCompleteForModelDownload(speechProp: String) -> (Error?, String?) -> Void {
        return { (error: Error?, fileUrl: String?) -> Void in
            self.numRequests -= 1
            if (error != nil || fileUrl == nil) {
                self.failure(error: error ?? RNSpokestackError.downloadFailed)
            } else {
                // Set local model filepath on speech config
                self.speechConfig.setValue(fileUrl!, forKey: speechProp)

                // Build the pipeline if there are no more requests
                if self.numRequests <= 0 {
                    self.buildPipeline()
                }
            }
        }
    }

    func buildPipeline() {
        if speechPipeline != nil {
            return
        }
        if makeClassifer {
            do {
                try classifier = NLUTensorflow([self], configuration: speechConfig)
            } catch {
                failure(error: error)
                return
            }
        }
        if var builder = speechPipelineBuilder {
            builder = builder.setConfiguration(speechConfig)
            builder = builder.addListener(self)
            do {
                try speechPipeline = builder.build()
            } catch {
                failure(error: error)
            }
        } else {
            failure(error: RNSpokestackError.builderNotAvailable)
        }
    }

    /// Initialize the speech pipeline
    /// - Parameters:
    ///   - clientId: Spokestack client ID token available from https://spokestack.io
    ///   - clientSecret: Spokestack client Secret token available from https://spokestack.io
    ///   - config: Spokestack config object to be used for initializing the Speech Pipeline.
    ///     See https://github.com/spokestack/react-native-spokestack for available options
    @objc(initialize:withClientSecret:withConfig:withResolver:withRejecter:)
    func initialize(clientId: String, clientSecret: String, config: Dictionary<String, Any>?, resolve: @escaping RCTPromiseResolveBlock, reject: @escaping RCTPromiseRejectBlock) -> Void {
        if speechPipeline != nil {
            resolve(nil)
            return
        }
        downloader = Downloader(allowCellular: RCTConvert.bool(config?["allowCellular"]), refreshModels: RCTConvert.bool(config?["refreshModels"]))
        speechContext = SpeechContext(speechConfig)
        speechConfig.apiId = clientId
        speechConfig.apiSecret = clientSecret
        speechPipelineBuilder = SpeechPipelineBuilder()
        speechPipelineBuilder = speechPipelineBuilder?.useProfile(SpeechPipelineProfiles.pushToTalkAppleSpeech)
        var nluDownloads: [URL:(Error?, String?) -> Void] = [:]
        var wakeDownloads: [URL:(Error?, String?) -> Void] = [:]
        var keywordDownloads: [URL:(Error?, String?) -> Void] = [:]
        for (key, value) in config! {
            switch key {
            case "traceLevel":
                let traceLevel = Trace.Level(rawValue: RCTConvert.nsInteger(value)) ?? Trace.Level.NONE
                debugPrint("Trace level set to: \(traceLevel.rawValue)")
                speechConfig.tracing = traceLevel
                break
            case "nlu":
                for (nluKey, nluValue) in value as! Dictionary<String, String> {
                    switch nluKey {
                    case "model":
                        nluDownloads[RCTConvert.nsurl(nluValue)] = makeCompleteForModelDownload(
                            speechProp: NLUDownloadProp.nluModelPath.rawValue)
                        break
                    case "metadata":
                        nluDownloads[RCTConvert.nsurl(nluValue)] = makeCompleteForModelDownload(
                            speechProp: NLUDownloadProp.nluModelMetadataPath.rawValue)
                        break
                    case "vocab":
                        nluDownloads[RCTConvert.nsurl(nluValue)] = makeCompleteForModelDownload(
                            speechProp: NLUDownloadProp.nluVocabularyPath.rawValue)
                        break
                    default:
                        break
                    }
                }
            case "wakeword":
                for (wakeKey, wakeValue) in value as! Dictionary<String, Any> {
                    switch wakeKey {
                    case "detect":
                        wakeDownloads[RCTConvert.nsurl(wakeValue)] = makeCompleteForModelDownload(
                            speechProp: WakewordDownloadProp.detectModelPath.rawValue)
                        break
                    case "encode":
                        wakeDownloads[RCTConvert.nsurl(wakeValue)] = makeCompleteForModelDownload(
                            speechProp: WakewordDownloadProp.encodeModelPath.rawValue)
                        break
                    case "filter":
                        wakeDownloads[RCTConvert.nsurl(wakeValue)] = makeCompleteForModelDownload(
                            speechProp: WakewordDownloadProp.filterModelPath.rawValue)
                        break
                    case "activeMin":
                        speechConfig.wakeActiveMin = RCTConvert.nsInteger(wakeValue)
                        break
                    case "activeMax":
                        speechConfig.wakeActiveMax = RCTConvert.nsInteger(wakeValue)
                        break
                    case "requestTimeout":
                        speechConfig.wakewordRequestTimeout = RCTConvert.nsInteger(wakeValue)
                        break
                    case "wakewords":
                        speechConfig.wakewords = RCTConvert.nsString(wakeValue)
                        break
                        
                    // Start advanced properties
                    case "encodeLength":
                        speechConfig.encodeLength = RCTConvert.nsInteger(wakeValue)
                        break
                    case "encodeWidth":
                        speechConfig.encodeWidth = RCTConvert.nsInteger(wakeValue)
                        break
                    case "fftWindowSize":
                        speechConfig.fftWindowSize = RCTConvert.nsInteger(wakeValue)
                        break
                    case "fftWindowType":
                        speechConfig.fftWindowType = SignalProcessing.FFTWindowType(rawValue: RCTConvert.nsString(wakeValue))
                            ?? SignalProcessing.FFTWindowType.hann
                        break
                    case "fftHopLength":
                        speechConfig.fftHopLength = RCTConvert.nsInteger(wakeValue)
                        break
                    case "melFrameLength":
                        speechConfig.melFrameLength = RCTConvert.nsInteger(wakeValue)
                        break
                    case "melFrameWidth":
                        speechConfig.melFrameWidth = RCTConvert.nsInteger(wakeValue)
                        break
                    case "preEmphasis":
                        speechConfig.preEmphasis = RCTConvert.nsNumber(wakeValue)!.floatValue
                        break
                    case "stateWidth":
                        speechConfig.stateWidth = RCTConvert.nsInteger(wakeValue)
                        break
                    case "threshold":
                        speechConfig.wakeThreshold = RCTConvert.nsNumber(wakeValue)!.floatValue
                        break
                    default:
                        break
                    }
                }
            case "keyword":
                for (keywordKey, keywordValue) in value as! Dictionary<String, Any> {
                    switch keywordKey {
                    case "detect":
                        keywordDownloads[RCTConvert.nsurl(keywordValue)] = makeCompleteForModelDownload(
                            speechProp: KeywordDownloadProp.keywordDetectModelPath.rawValue)
                        break
                    case "encode":
                        keywordDownloads[RCTConvert.nsurl(keywordValue)] = makeCompleteForModelDownload(
                            speechProp: KeywordDownloadProp.keywordEncodeModelPath.rawValue)
                        break
                    case "filter":
                        keywordDownloads[RCTConvert.nsurl(keywordValue)] = makeCompleteForModelDownload(
                            speechProp: KeywordDownloadProp.keywordFilterModelPath.rawValue)
                        break
                    case "metadata":
                        keywordDownloads[RCTConvert.nsurl(keywordValue)] = makeCompleteForModelDownload(
                            speechProp: KeywordDownloadProp.keywordMetadataPath.rawValue)
                        break
                    case "classes":
                        speechConfig.keywords = RCTConvert.nsString(keywordValue)
                        break
                    
                    // Start advanced properties
                    case "encodeLength":
                        speechConfig.keywordEncodeLength = RCTConvert.nsInteger(keywordValue)
                        break
                    case "encodeWidth":
                        speechConfig.keywordEncodeWidth = RCTConvert.nsInteger(keywordValue)
                        break
                    case "fftWindowSize":
                        speechConfig.keywordFFTWindowSize = RCTConvert.nsInteger(keywordValue)
                        break
                    case "fftWindowType":
                        speechConfig.keywordFFTWindowType = SignalProcessing.FFTWindowType(rawValue: RCTConvert.nsString(keywordValue))
                            ?? SignalProcessing.FFTWindowType.hann
                        break
                    case "fftHopLength":
                        speechConfig.keywordFFTHopLength = RCTConvert.nsInteger(keywordValue)
                        break
                    case "melFrameLength":
                        speechConfig.keywordMelFrameLength = RCTConvert.nsInteger(keywordValue)
                        break
                    case "melFrameWidth":
                        speechConfig.keywordMelFrameWidth = RCTConvert.nsInteger(keywordValue)
                        break
                    case "preEmphasis":
                        speechConfig.preEmphasis = RCTConvert.nsNumber(keywordValue)!.floatValue
                        break
                    case "stateWidth":
                        speechConfig.stateWidth = RCTConvert.nsInteger(keywordValue)
                        break
                    case "threshold":
                        speechConfig.keywordThreshold = RCTConvert.nsNumber(keywordValue)!.floatValue
                        break
                    default:
                        break
                    }
                }
            case "pipeline":
                // All values in pipeline happen to be Int
                // so no RCTConvert calls are needed
                for (pipelineKey, pipelineValue) in value as! Dictionary<String, Int> {
                    switch pipelineKey {
                    case "profile":
                        let profile = SpeechPipelineProfiles(rawValue: pipelineValue) ?? SpeechPipelineProfiles.pushToTalkAppleSpeech;
//                        debugPrint("Setting profile", profile.rawValue)
                        speechPipelineBuilder = speechPipelineBuilder?.useProfile(profile)
                        break
                    case "sampleRate":
                        speechConfig.sampleRate = pipelineValue
                        break
                    case "frameWidth":
                        speechConfig.frameWidth = pipelineValue
                        break
                    case "vadMode":
                        speechConfig.vadMode = VADMode(rawValue: pipelineValue) ?? VADMode.HighlyPermissive
                        break
                    case "vadFallDelay":
                        speechConfig.vadFallDelay = pipelineValue
                        break
                    default:
                        break
                    }
                }
                break
            default:
                break
            }
        }

        // Initialize TTS
        synthesizer = TextToSpeech([self], configuration: speechConfig)

        // Download model files if necessary
        if let d = downloader {
            // Set resolve now in case
            // all downloads are synchronous, early returns
            // from the cache and the last one builds the pipeline
            resolvers[RNSpokestackPromise.initialize] = resolve
            rejecters[RNSpokestackPromise.initialize] = reject
            let doWakeword = wakeDownloads.count == 3
            let doKeyword = keywordDownloads.count >= 3
            let doNLU = nluDownloads.count == 3
            
            // Set all request counts up-front
            // in case some downloads complete synchronously
            // from cache. This avoids building the pipeline
            // before all downloads finish.
            numRequests = (doWakeword ? wakeDownloads.count : 0) +
                (doKeyword ? keywordDownloads.count : 0) +
                (doNLU ? nluDownloads.count : 0)

            if doWakeword {
                wakeDownloads.forEach { (url, complete) in
                    d.downloadModel(url, complete)
                }
            }
            if doKeyword {
                keywordDownloads.forEach { (url, complete) in
                    d.downloadModel(url, complete)
                }
            }
            if doNLU {
                makeClassifer = true
                nluDownloads.forEach { (url, complete) in
                    d.downloadModel(url, complete)
                }
            }
        } else {
            reject("init_error", "The downloader is unexpectedly nil.", RNSpokestackError.downloaderNotAvailable)
        }

        if numRequests == 0 {
            buildPipeline()
        }
    }

    /// Start the speech pipeline
    @objc(start:withRejecter:)
    func start(resolve: @escaping RCTPromiseResolveBlock, reject: @escaping RCTPromiseRejectBlock) -> Void {
        if started {
            resolve(nil)
            return
        }
        if let pipeline = speechPipeline {
            resolvers[RNSpokestackPromise.start] = resolve
            rejecters[RNSpokestackPromise.start] = reject
            pipeline.start()
        } else {
            notInitialized(reject, module: "Speech Pipeline")
        }
    }

    /// Start the speech pipeline
    @objc(stop:withRejecter:)
    func stop(resolve: @escaping RCTPromiseResolveBlock, reject: @escaping RCTPromiseRejectBlock) -> Void {
        if !started {
            resolve(nil)
            return
        }
        if let pipeline = speechPipeline {
            resolvers[RNSpokestackPromise.stop] = resolve
            rejecters[RNSpokestackPromise.stop] = reject
            pipeline.stop()
        } else {
            notInitialized(reject, module: "Speech Pipeline")
        }
    }

    /// Manually activate the speech pipeline
    @objc(activate:withRejecter:)
    func activate(resolve: @escaping RCTPromiseResolveBlock, reject: @escaping RCTPromiseRejectBlock) -> Void {
        if let pipeline = speechPipeline {
            if !started {
                reject(
                    "not_started",
                    "Spokestack.start() must be called before Spokestack.activate()",
                    RNSpokestackError.notStarted
                )
                return
            }
            resolvers[RNSpokestackPromise.activate] = resolve
            rejecters[RNSpokestackPromise.activate] = reject
            pipeline.activate()
        } else {
            notInitialized(reject, module: "Speech Pipeline")
        }
    }

    /// Manually deactivate the speech pipeline
    @objc(deactivate:withRejecter:)
    func deactivate(resolve: @escaping RCTPromiseResolveBlock, reject: @escaping RCTPromiseRejectBlock) -> Void {
        if let pipeline = speechPipeline {
            resolvers[RNSpokestackPromise.deactivate] = resolve
            rejecters[RNSpokestackPromise.deactivate] = reject
            pipeline.deactivate()
        } else {
            notInitialized(reject, module: "Speech Pipeline")
        }
    }

    /// Synthesize text into speech
    /// - Parameters:
    ///   - input: String of text to synthesize into speech.
    ///   - format?: See the TTSFormat enum. One of text, ssml, or speech markdown.
    ///   - voice?: A string indicating the desired Spokestack voice. The default is the free voice: "demo-male".
    @objc(synthesize:withFormat:withVoice:withResolver:withRejecter:)
    func synthesize(input: String, format: Int, voice: String, resolve: @escaping RCTPromiseResolveBlock, reject: @escaping RCTPromiseRejectBlock) -> Void {
        if let tts = synthesizer {
            resolvers[RNSpokestackPromise.synthesize] = resolve
            rejecters[RNSpokestackPromise.synthesize] = reject
            let ttsInput = TextToSpeechInput(input, voice: voice, inputFormat: TTSInputFormat(rawValue: format) ?? TTSInputFormat.text)
            tts.synthesize(ttsInput)
        } else {
            notInitialized(reject, module: "Spokestack TTS")
        }
    }

    /// Convenience method for synthesizing text to speech and
    /// playing it immediately.
    /// Audio session handling can get very complex and we recommend
    /// using a RN library focused on audio for anything more than playing
    /// through the default audio system.
    @objc(speak:withFormat:withVoice:withResolver:withRejecter:)
    func speak(input: String, format: Int, voice: String, resolve: @escaping RCTPromiseResolveBlock, reject: @escaping RCTPromiseRejectBlock) -> Void {
        if let tts = synthesizer {
            resolvers[RNSpokestackPromise.speak] = resolve
            rejecters[RNSpokestackPromise.speak] = reject
            let ttsInput = TextToSpeechInput(input, voice: voice, inputFormat: TTSInputFormat(rawValue: format) ?? TTSInputFormat.text)
            tts.speak(ttsInput)
        } else {
            notInitialized(reject, module: "Spokestack TTS")
        }
    }

    /// Classfiy an utterance using NLUTensorflow
    /// - Parameters:
    ///   - utterance: String utterance from the user
    @objc(classify:withResolver:withRejecter:)
    func classify(utterance: String, resolve: @escaping RCTPromiseResolveBlock, reject: @escaping RCTPromiseRejectBlock) -> Void {
        if let nlu = classifier {
            resolvers[RNSpokestackPromise.classify] = resolve
            rejecters[RNSpokestackPromise.classify] = reject
            nlu.classify(utterance: utterance)
        } else {
            notInitialized(reject, module: "Spokestack NLU")
        }
    }
    
    /// Return whether Spokestack has been initialized
    @objc(isInitialized:withRejecter:)
    func isInitialized(resolve: @escaping RCTPromiseResolveBlock, reject: RCTPromiseRejectBlock) {
        resolve(speechPipeline != nil)
    }
    
    /// Return whether the speech pipeline has been started
    @objc(isStarted:withRejecter:)
    func isStarted(resolve: @escaping RCTPromiseResolveBlock, reject: RCTPromiseRejectBlock) {
        // isStarted is private in the SpeechPipeline
        // so we track it ourselves
        resolve(started)
    }
    
    /// Return whether the speech pipeline is currently activated
    @objc(isActivated:withRejecter:)
    func isActivated(resolve: @escaping RCTPromiseResolveBlock, reject: RCTPromiseRejectBlock) {
        if let pipeline = speechPipeline {
            resolve(pipeline.context.isActive)
        } else {
            resolve(false)
        }
    }
    
    /// Destroys the speech pipeline and frees up all resources
    @objc(destroy:withRejecter:)
    func destroy(resolve: @escaping RCTPromiseResolveBlock, reject: RCTPromiseRejectBlock) {
        if let pipeline = speechPipeline {
            pipeline.stop()
            speechPipeline = nil
            
            synthesizer?.stopSpeaking()
            synthesizer = nil
            
            classifier = nil
            
            downloader = nil
            
            speechContext = nil
        }
        resolve(nil)
    }
}
