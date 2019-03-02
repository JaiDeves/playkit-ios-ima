
import GoogleInteractiveMediaAds
import PlayKit
import PlayKitUtils

@objc public class IMADAIPlugin: BasePlugin, PKPluginWarmUp, IMAAdsLoaderDelegate, IMAStreamManagerDelegate, IMAWebOpenerDelegate, AdsDAIPlugin, PlayerEngineWrapperProvider, IMAAVPlayerVideoDisplayDelegate {
    
    // Internal errors for requesting ads
    enum IMADAIPluginRequestError: Error {
        case missingPlayerView
        case missingVideoDisplay
        case missingLiveData
        case missingVODData
    }
    
    /// The IMA DAI plugin state machine
    private var stateMachine = BasicStateMachine(initialState: IMAState.start, allowTransitionToInitialState: false)
    
    private static var adsLoader: IMAAdsLoader!
    // We must have config, an error will be thrown otherwise
    private var pluginConfig: IMADAIConfig!
    
    private var videoDisplay: IMAVideoDisplay?
    private var streamManager: IMAStreamManager?
    private var renderingSettings: IMAAdsRenderingSettings! = IMAAdsRenderingSettings()
    
    /// Timer for checking IMA requests timeout.
    private var requestTimeoutTimer: Timer?
    /// The request timeout interval
    private var requestTimeoutInterval: TimeInterval = IMAPlugin.defaultTimeoutInterval

    private var adDisplayContainer: IMAAdDisplayContainer?
    
    private var cuepoints: [IMACuepoint] = [] {
        didSet {
            if cuepoints.count > 0 {
                var adDAICuePoints: [CuePoint] = []
                for imaCuepoint in cuepoints {
                    let cuePoint = CuePoint(startTime: imaCuepoint.startTime, endTime: imaCuepoint.endTime, played: imaCuepoint.isPlayed)
                    adDAICuePoints.append(cuePoint)
                }
                
                self.notify(event: AdEvent.AdCuePointsUpdate(adDAICuePoints: PKAdDAICuePoints(adDAICuePoints)))
            }
        }
    }
    private var currentCuepoint: IMACuepoint?
    
    public var isAdPlaying: Bool {
        return self.stateMachine.getState() == .adsPlaying
    }
    
    public var isContentPlaying: Bool {
        return self.stateMachine.getState() == .contentPlaying
    }
    
    private var adsDAIPlayerEngineWrapper: AdsDAIPlayerEngineWrapper?
    
    // MARK: - AdsPlugin - Properties
    weak public var dataSource: AdsPluginDataSource? {
        didSet {
            PKLog.debug("data source set")
        }
    }
    weak public var delegate: AdsPluginDelegate?
    public var pipDelegate: AVPictureInPictureControllerDelegate?
    
    /************************************************************/
    // MARK: - Private
    /************************************************************/
    
    private func setupLoader(with config: IMADAIConfig) {
        let imaSettings: IMASettings! = IMASettings()
        if let ppid = config.ppid { imaSettings.ppid = ppid }
        imaSettings.language = config.language
        imaSettings.maxRedirects = config.maxRedirects
        imaSettings.enableBackgroundPlayback = config.enableBackgroundPlayback
        imaSettings.autoPlayAdBreaks = config.autoPlayAdBreaks
        imaSettings.disableNowPlayingInfo = config.disableNowPlayingInfo
        imaSettings.playerType = config.playerType
        imaSettings.playerVersion = config.playerVersion
        imaSettings.enableDebugMode = config.enableDebugMode
        
        IMADAIPlugin.adsLoader = IMAAdsLoader(settings: imaSettings)
    }
    
    public func contentComplete() {
        IMADAIPlugin.adsLoader?.contentComplete()
    }
    
    private func invalidateRequestTimer() {
        self.requestTimeoutTimer?.invalidate()
        self.requestTimeoutTimer = nil
    }
    
    public func destroyManager() {
        self.invalidateRequestTimer()
        self.streamManager?.delegate = nil
        self.streamManager?.destroy()
        // In order to make multiple ad requests, StreamManager instance should be destroyed, and then contentComplete() should be called on AdsLoader.
        // This will "reset" the SDK.
        self.contentComplete()
        self.streamManager = nil
        // Reset the state machine
        self.stateMachine.reset()
        
        self.adDisplayContainer?.unregisterAllVideoControlsOverlays()
    }
    
    private func createAdsLoader() {
        self.setupLoader(with: self.pluginConfig)
        IMADAIPlugin.adsLoader.contentComplete()
        IMADAIPlugin.adsLoader.delegate = self
    }
    
    private static func createAdDisplayContainer(forView view: UIView, withCompanionView companionView: UIView? = nil) -> IMAAdDisplayContainer {
        // setup ad display container and companion if exists, needs to create a new ad container for each request.
        if let cv = companionView {
            let companionAdSlot = IMACompanionAdSlot(view: companionView, width: Int32(cv.frame.size.width), height: Int32(cv.frame.size.height))
            return IMAAdDisplayContainer(adContainer: view, companionSlots: [companionAdSlot!])
        } else {
            return IMAAdDisplayContainer(adContainer: view, companionSlots: [])
        }
    }
    
    private func createRenderingSettings() {
        self.renderingSettings.webOpenerDelegate = self
        
        if let mimeTypes = self.pluginConfig?.videoMimeTypes {
            self.renderingSettings.mimeTypes = mimeTypes
        }
        
        if let bitrate = self.pluginConfig?.videoBitrate {
            self.renderingSettings.bitrate = Int(bitrate)
        }
        
        if let loadVideoTimeout = self.pluginConfig.loadVideoTimeout {
            self.renderingSettings.loadVideoTimeout = loadVideoTimeout
        }
        
        if let playAdsAfterTime = self.dataSource?.playAdsAfterTime, playAdsAfterTime > 0 {
            self.renderingSettings.playAdsAfterTime = 20//playAdsAfterTime
        }
        
        if let uiElements = self.pluginConfig.uiElements {
            self.renderingSettings.uiElements = uiElements
        }
        
        self.renderingSettings.disableUi = self.pluginConfig.disableUI
        
        if let webOpenerPresentingController = self.pluginConfig?.webOpenerPresentingController {
            self.renderingSettings.webOpenerPresentingController = webOpenerPresentingController
        }
    }
    
    private func initStreamManager() {
        self.streamManager?.initialize(with: self.renderingSettings)
        PKLog.debug("Stream manager set")
    }
    
    private func notify(event: AdEvent) {
        self.delegate?.adsPlugin(self, didReceive: event)
        self.messageBus?.post(event)
    }
    
//    /// called when plugin need to start the ad playback on first ad play only
//    private func startAd() {
//        self.stateMachine.set(state: .adsLoadedAndPlay)
//        self.initStreamManager()
//    }
//
//    /// protects against cases where the ads manager will load after timeout.
//    /// this way we will only start ads when ads loaded and play() was used or when we came from content playing.
//    private func canPlayAd(forState state: IMAState) -> Bool {
//        if state == .adsLoadedAndPlay || state == .contentPlaying {
//            return true
//        }
//        return false
//    }
    
    private func isAdPlayable() -> Bool {
        guard let currentTime = self.player?.currentTime else { return true }
        
        for cuepoint in cuepoints {
            if cuepoint.startTime >= currentTime && cuepoint.endTime <= currentTime {
                currentCuepoint = cuepoint
                return !cuepoint.isPlayed
            }
        }
        
        return true
    }
    
    /************************************************************/
    // MARK: - IMAContentPlayhead
    /************************************************************/
    
    @objc public var currentTime: TimeInterval {
        // IMA must receive a number value so we must check `isNaN` on any value we send.
        // Before returning `player.currentTime` we need to check `!player.currentTime.isNaN`.
        if let currentTime = self.player?.currentTime, !currentTime.isNaN {
            return currentTime
        }
        return 0
    }
    
    /************************************************************/
    // MARK: - PKPluginWarmUp
    /************************************************************/
    
    public static func warmUp() {
        // load adsLoader in order to make IMA download the needed objects before initializing.
        // will setup the instance when first player is loaded
        _ = IMAAdsLoader(settings: IMASettings())
    }
    
    /************************************************************/
    // MARK: - PlayerEngineWrapperProvider
    /************************************************************/
    
    public func getPlayerEngineWrapper() -> PlayerEngineWrapper? {
        if adsDAIPlayerEngineWrapper == nil {
            adsDAIPlayerEngineWrapper = AdsDAIPlayerEngineWrapper(adsPlugin: self)
        }
        
        return adsDAIPlayerEngineWrapper
    }
    
    /************************************************************/
    // MARK: - PKPlugin
    /************************************************************/
    
    public override class var pluginName: String {
        return "IMADAIPlugin"
    }
    
    public required init(player: Player, pluginConfig: Any?, messageBus: MessageBus) throws {
        guard let imaDAIConfig = pluginConfig as? IMADAIConfig else {
            PKLog.error("Missing plugin config")
            throw PKPluginError.missingPluginConfig(pluginName: IMADAIPlugin.pluginName)
        }
        
        try super.init(player: player, pluginConfig: pluginConfig, messageBus: messageBus)
        
        self.pluginConfig = imaDAIConfig
        self.requestTimeoutInterval = imaDAIConfig.requestTimeoutInterval
        if IMADAIPlugin.adsLoader == nil {
            self.setupLoader(with: imaDAIConfig)
        }
        
//        IMADAIPlugin.adsLoader.contentComplete() // For previous one
        IMADAIPlugin.adsLoader.delegate = self
        
        self.messageBus?.addObserver(self, events: [PlayerEvent.ended]) { [weak self] event in
            self?.contentComplete()
        }
    }
    
    public override func onUpdateConfig(pluginConfig: Any) {
        PKLog.debug("pluginConfig: " + String(describing: pluginConfig))
        
        super.onUpdateConfig(pluginConfig: pluginConfig)
        
        if let adsConfig = pluginConfig as? IMADAIConfig {
            self.pluginConfig = adsConfig
        }
    }
    
    public override func destroy() {
        self.destroyManager()
        super.destroy()
    }
    
    /************************************************************/
    // MARK: - IMAAdsLoaderDelegate
    /************************************************************/
    
    public func adsLoader(_ loader: IMAAdsLoader!, adsLoadedWith adsLoadedData: IMAAdsLoadedData!) {
        print("Nilit: IMADAIPlugin adsLoader adsLoadedData")
//        self.loaderRetries = IMAPlugin.loaderRetryCount
        
        switch self.stateMachine.getState() {
        case .adsRequested:
            self.stateMachine.set(state: .adsLoaded)
        case .adsRequestedAndPlay:
            self.stateMachine.set(state: .adsLoadedAndPlay)
        default:
            break
        }
        
        self.invalidateRequestTimer()
        self.streamManager = adsLoadedData.streamManager
        adsLoadedData.streamManager.delegate = self
        
        self.createRenderingSettings()
        
        // Initialize on the stream manager starts the ads loading process, we want to initialize it only after play.
        // Machine state `adsLoaded` is when ads request succeeded but play haven't been received yet.
        // We don't want to initialize the stream manager until play() has been performed.
        if self.stateMachine.getState() == .adsLoadedAndPlay {
            self.initStreamManager()
        }
    }
    
    public func adsLoader(_ loader: IMAAdsLoader!, failedWith adErrorData: IMAAdLoadingErrorData!) {
        // Cancel the request timer
        self.invalidateRequestTimer()
        self.stateMachine.set(state: .adsRequestFailed)
        
        guard let adError = adErrorData.adError else { return }
        PKLog.error(adError.message)
        self.messageBus?.post(AdEvent.Error(nsError: IMAPluginError(adError: adError).asNSError))
        self.delegate?.adsPlugin(self, loaderFailedWith: adError.message)
    }
    
    /************************************************************/
    // MARK: - IMAStreamManagerDelegate
    /************************************************************/
    
    public func streamManager(_ streamManager: IMAStreamManager!, didReceive event: IMAAdEvent!) {
        print("Nilit: Stream manager event: \(String(describing: event.typeString))")
        PKLog.trace("Stream manager event: " + event.typeString)
//        let currentState = self.stateMachine.getState()
        
        switch event.type {
        case .CUEPOINTS_CHANGED:
            guard let adData = event.adData else { return }
            guard let cuepoints = adData["cuepoints"] else { return }
            guard let cuepointsArray = cuepoints as? [IMACuepoint] else { return }
            self.cuepoints = cuepointsArray
        case .STREAM_LOADED:
            self.notify(event: AdEvent.StreamLoaded())
            if self.pluginConfig.streamType == .vod {
                // TODO: check if it starts from the start time.
                if let streamTime = self.streamManager?.streamTime(forContentTime: self.renderingSettings.playAdsAfterTime), streamTime > 0 {
                    self.player?.seek(to: streamTime)
                }
            }
            self.stateMachine.set(state: .contentPlaying)
        case .STREAM_STARTED:
            self.notify(event: AdEvent.StreamStarted())
        case .AD_BREAK_STARTED:
            if isAdPlayable() {
                self.stateMachine.set(state: .adsPlaying)
                self.notify(event: AdEvent.AdDidRequestContentPause())
                self.notify(event: AdEvent.AdBreakStarted())
            } else {
                if let newTime = self.currentCuepoint?.endTime {
                    self.player?.seek(to: newTime)
                }
            }
        case .LOADED:
            let adEvent = event.ad != nil ? AdEvent.AdLoaded(adInfo: PKAdInfo(ad: event.ad)) : AdEvent.AdLoaded()
            self.notify(event: adEvent)
        case .STARTED:
            let event = event.ad != nil ? AdEvent.AdStarted(adInfo: PKAdInfo(ad: event.ad)) : AdEvent.AdStarted()
            self.notify(event: event)
        case .FIRST_QUARTILE:
            self.notify(event: AdEvent.AdFirstQuartile())
        case .MIDPOINT:
            self.notify(event: AdEvent.AdMidpoint())
        case .THIRD_QUARTILE:
            self.notify(event: AdEvent.AdThirdQuartile())
        case .PAUSE:
            self.notify(event: AdEvent.AdPaused())
        case .RESUME:
            self.notify(event: AdEvent.AdResumed())
        case .CLICKED:
            if let clickThroughUrl = event.ad.value(forKey: "clickThroughUrl") as? String {
                self.notify(event: AdEvent.AdClicked(clickThroughUrl: clickThroughUrl))
            } else {
                self.notify(event: AdEvent.AdClicked())
            }
        case .TAPPED:
            self.notify(event: AdEvent.AdTapped())
        case .SKIPPED:
            self.notify(event: AdEvent.AdSkipped())
        case .COMPLETE:
            self.notify(event: AdEvent.AdComplete())
        case .AD_BREAK_ENDED:
            self.stateMachine.set(state: .contentPlaying)
            self.notify(event: AdEvent.AdBreakEnded())
            self.notify(event: AdEvent.AdDidRequestContentResume())
        case .LOG:
            break
        default:
            break
        }
    }
    
    public func streamManager(_ streamManager: IMAStreamManager!, didReceive error: IMAAdError!) {
        PKLog.error(error.message)
        self.messageBus?.post(AdEvent.Error(nsError: IMAPluginError(adError: error).asNSError))
        self.delegate?.adsPlugin(self, managerFailedWith: error.message)
    }
    
    public func streamManager(_ streamManager: IMAStreamManager!,
                              adDidProgressToTime time: TimeInterval,
                              adDuration: TimeInterval,
                              adPosition: Int,
                              totalAds: Int,
                              adBreakDuration: TimeInterval) {
//        print("Nilit: streamManager adDidProgressToTime \(time) adDuration \(adDuration) adPosition \(adPosition) totalAds \(totalAds) adBreakDuration \(adBreakDuration)")
        self.notify(event: AdEvent.AdDidProgressToTime(mediaTime: time, totalTime: adDuration))
    }
    
    /************************************************************/
    // MARK: - AdsDAIPlugin
    /************************************************************/
    
    public func requestAds() throws {
        guard let playerView = self.player?.view else {
            throw IMADAIPluginRequestError.missingPlayerView
        }
        
        adDisplayContainer = IMADAIPlugin.createAdDisplayContainer(forView: playerView, withCompanionView: self.pluginConfig.companionView)
        
        if let videoControlsOverlays = self.pluginConfig?.videoControlsOverlays {
            for overlay in videoControlsOverlays {
                adDisplayContainer?.registerVideoControlsOverlay(overlay)
            }
        }
        
//        var imaPlayerVideoDisplay: IMAVideoDisplay?
//        switch adsDAIPlayerEngineWrapper?.playerEngine {
//        case is AVPlayerWrapper:
//            guard let avPlayerWrapper = adsDAIPlayerEngineWrapper?.playerEngine as? AVPlayerWrapper else { throw IMADAIPluginRequestError.missingVideoDisplay }
//            if let imaAVPlayerVideoDisplay = IMAAVPlayerVideoDisplay(avPlayer: avPlayerWrapper.currentPlayer) {
////                imaAVPlayerVideoDisplay.avPlayerVideoDisplayDelegate = self
//                imaPlayerVideoDisplay = imaAVPlayerVideoDisplay
//            }
//        default:
//            break
//        }
//
//        guard let videoDisplay = imaPlayerVideoDisplay else { throw IMADAIPluginRequestError.missingVideoDisplay }
//        self.videoDisplay = videoDisplay
        
        guard let adsDAIPlayerEngineWrapper = self.adsDAIPlayerEngineWrapper else { throw IMADAIPluginRequestError.missingVideoDisplay }
        let imaPlayerVideoDisplay = PKIMAVideoDisplay(adsDAIPlayerEngineWrapper: adsDAIPlayerEngineWrapper)
//        imaPlayerVideoDisplay.delegate = self
        self.videoDisplay = imaPlayerVideoDisplay
        
        var request: IMAStreamRequest
        switch pluginConfig.streamType {
        case .live:
            guard let assetKey = pluginConfig.assetKey else { throw IMADAIPluginRequestError.missingLiveData }
            
            request = IMALiveStreamRequest(assetKey: assetKey,
                                           adDisplayContainer: adDisplayContainer,
                                           videoDisplay: videoDisplay)
        case .vod:
            guard let contentSourceId = pluginConfig.contentSourceId, let videoId = pluginConfig.videoId else { throw IMADAIPluginRequestError.missingVODData }
            
            request = IMAVODStreamRequest(contentSourceID: contentSourceId,
                                          videoID: videoId,
                                          adDisplayContainer: adDisplayContainer,
                                          videoDisplay: videoDisplay)
        }
        
        request.apiKey = pluginConfig.apiKey
        
        self.stateMachine.set(state: .adsRequested)
        
        if IMADAIPlugin.adsLoader == nil {
            self.createAdsLoader()
        }
        
        PKLog.debug("Request Ads")
        IMADAIPlugin.adsLoader.requestStream(with: request)
        self.notify(event: AdEvent.AdsRequested())
        
        self.requestTimeoutTimer = PKTimer.after(self.requestTimeoutInterval) { [weak self] _ in
            guard let strongSelf = self else { return }
            
            if strongSelf.streamManager == nil {
                PKLog.debug("Ads request timed out")
                switch strongSelf.stateMachine.getState() {
                case .adsRequested:
                    strongSelf.delegate?.adsRequestTimedOut(shouldPlay: false)
                case .adsRequestedAndPlay:
                    strongSelf.delegate?.adsRequestTimedOut(shouldPlay: true)
                default:
                    break // should not receive timeout for any other state
                }
                // set state to request failure
                strongSelf.stateMachine.set(state: .adsRequestTimedOut)
                
                strongSelf.invalidateRequestTimer()
                // post ads request timeout event
                strongSelf.notify(event: AdEvent.RequestTimedOut())
            }
        }
    }
    
    public func resume() {
//        self.player?.resume()
    }
    
    public func pause() {
//        self.player?.pause()
    }
    
    public func didPlay() {
        // TODO: know if it's an ad or content
//        self.stateMachine.set(state: .contentPlaying)
    }
    
    public func didRequestPlay(ofType type: PlayType) {
        if !self.isAdPlayable() {
            // TODO: seek
        }
        
        switch self.stateMachine.getState() {
//        case .adsLoadedAndPlay:
        case .adsLoaded:
            // TODO: know where we are and set state
            self.delegate?.play(type)
        default:
            print("Nilit: didRequestPlay, take care of \(self.stateMachine.getState())")
            self.delegate?.play(type)
        }
    }
    
    public func contentTime(forStreamTime streamTime: TimeInterval) -> TimeInterval {
        return streamManager?.contentTime(forStreamTime: streamTime) ?? streamTime
    }
    
    public func streamTime(forContentTime contentTime: TimeInterval) -> TimeInterval {
        return streamManager?.streamTime(forContentTime: contentTime) ?? contentTime
    }
    
    public func previousCuepoint(forStreamTime streamTime: TimeInterval) -> CuePoint? {
        guard let imaCuePoint = streamManager?.previousCuepoint(forStreamTime: streamTime) else { return nil }
        return CuePoint(startTime: imaCuePoint.startTime, endTime: imaCuePoint.endTime, played: imaCuePoint.isPlayed)
    }
    
    public func canPlayAd(atStreamTime streamTime: TimeInterval) -> (canPlay: Bool, duration: TimeInterval) {
        let nextStreamTime = streamTime + 1
        guard let imaCuePoint = streamManager?.previousCuepoint(forStreamTime: nextStreamTime) else {
            return (true, 0)
        }
        return (!imaCuePoint.isPlayed, imaCuePoint.endTime - imaCuePoint.startTime)
    }
    
    public func didEnterBackground() {
        switch self.stateMachine.getState() {
        case .adsRequested, .adsRequestedAndPlay:
            self.destroyManager()
            self.stateMachine.set(state: .startAndRequest)
        default:
            break
        }
    }
    
    public func willEnterForeground() {
        if self.stateMachine.getState() == .startAndRequest {
            try? self.requestAds()
        }
    }
    
    /************************************************************/
    // MARK: - IMAAVPlayerVideoDisplayDelegate
    /************************************************************/
    
    public func avPlayerVideoDisplay(_ avPlayerVideoDisplay: IMAAVPlayerVideoDisplay!, willLoadStreamAsset avUrlAsset: AVURLAsset!) {
        guard let mediaConfig = adsDAIPlayerEngineWrapper?.mediaConfig else { return }
        guard let sources = mediaConfig.mediaEntry.sources else { return }
        for source in sources {
            source.contentUrl = avUrlAsset.url
        }
        
//        self.player?.prepare(mediaConfig)
    }
}