//
//  GameViewController.swift
//  Delta
//
//  Created by Riley Testut on 5/5/15.
//  Copyright © 2016 Riley Testut. All rights reserved.
//

import UIKit
import AVFoundation
import Photos

import DeltaCore
import GBADeltaCore
import GBCDeltaCore
import N64DeltaCore
import MelonDSDeltaCore
import GPGXDeltaCore
import Systems

import struct DSDeltaCore.DS

import Roxas
import AltKit

private var kvoContext = 0

private extension DeltaCore.ControllerSkin
{
    func hasTouchScreen(for traits: DeltaCore.ControllerSkin.Traits) -> Bool
    {
        let hasTouchScreen = self.items(for: traits)?.contains(where: { $0.kind == .touchScreen }) ?? false
        return hasTouchScreen
    }
}

private extension GameViewController
{
    struct PausedSaveState: SaveStateProtocol
    {
        var fileURL: URL
        var gameType: GameType
        
        var isSaved = false
        
        init(fileURL: URL, gameType: GameType)
        {
            self.fileURL = fileURL
            self.gameType = gameType
        }
    }
    
    struct DefaultInputMapping: GameControllerInputMappingProtocol
    {
        let gameController: GameController
        
        var gameControllerInputType: GameControllerInputType {
            return self.gameController.inputType
        }
        
        func input(forControllerInput controllerInput: Input) -> Input?
        {
            if let mappedInput = self.gameController.defaultInputMapping?.input(forControllerInput: controllerInput)
            {
                return mappedInput
            }
            
            // Only intercept controller skin inputs.
            guard controllerInput.type == .controller(.controllerSkin) else { return nil }
            
            let actionInput = ActionInput(stringValue: controllerInput.stringValue)
            return actionInput
        }
    }
    
    struct SustainInputsMapping: GameControllerInputMappingProtocol
    {
        let gameController: GameController
        
        var gameControllerInputType: GameControllerInputType {
            return self.gameController.inputType
        }
        
        func input(forControllerInput controllerInput: Input) -> Input?
        {
            if let mappedInput = self.gameController.defaultInputMapping?.input(forControllerInput: controllerInput), mappedInput == StandardGameControllerInput.menu
            {
                return mappedInput
            }
            
            return controllerInput
        }
    }
}

class GameViewController: DeltaCore.GameViewController
{
    /// Assumed to be Delta.Game instance
    override var game: GameProtocol? {
        willSet {
            self.emulatorCore?.removeObserver(self, forKeyPath: #keyPath(EmulatorCore.state), context: &kvoContext)
            
            let game = self.game as? Game
            NotificationCenter.default.removeObserver(self, name: .NSManagedObjectContextDidSave, object: game?.managedObjectContext)
        }
        didSet {
            self.emulatorCore?.addObserver(self, forKeyPath: #keyPath(EmulatorCore.state), options: [.old], context: &kvoContext)
            
            let game = self.game as? Game
            NotificationCenter.default.addObserver(self, selector: #selector(GameViewController.managedObjectContextDidChange(with:)), name: .NSManagedObjectContextObjectsDidChange, object: game?.managedObjectContext)
            
            self.emulatorCore?.saveHandler = { [weak self] _ in self?.updateGameSave() }
            
            if oldValue?.fileURL != game?.fileURL
            {
                self.shouldResetSustainedInputs = true
            }
            
            self.updateControllers()
            self.updateGraphics()
            self.updateAudio()
            
            self.presentedGyroAlert = false
            
            self.clearRewindSaveStates()
        }
    }
    
    //MARK: - Private Properties -
    private var pauseViewController: PauseViewController?
    private var pausingGameController: GameController?
    
    // Prevents the same save state from being saved multiple times
    private var pausedSaveState: PausedSaveState? {
        didSet
        {
            if let saveState = oldValue, self.pausedSaveState == nil
            {
                do
                {
                    try FileManager.default.removeItem(at: saveState.fileURL)
                }
                catch
                {
                    print(error)
                }
            }
        }
    }
    
    private var _deepLinkResumingSaveState: SaveStateProtocol? {
        didSet {
            guard let saveState = oldValue, _deepLinkResumingSaveState == nil else { return }
            
            do
            {
                try FileManager.default.removeItem(at: saveState.fileURL)
            }
            catch
            {
                print(error)
            }
        }
    }
    
    private var _isLoadingSaveState = false
    private var _isQuickSettingsOpen = false
        
    // Sustain Buttons
    private var isSelectingSustainedButtons = false
    private var sustainInputsMapping: SustainInputsMapping?
    private var shouldResetSustainedInputs = false
    
    private var sustainButtonsContentView: UIView!
    private var sustainButtonsBlurView: UIVisualEffectView!
    private var sustainButtonsBackgroundView: RSTPlaceholderView!
    private var inputsToSustain = [AnyInput: Double]()
    
    private var airPlayContentView: UIView!
    private var airPlayBlurView: UIVisualEffectView!
    private var airPlayBackgroundView: RSTPlaceholderView!
    
    private var rewindTimer: Timer?
    
    private var buttonSoundFile: AVAudioFile?
    private var buttonSoundPlayer: AVAudioPlayer?
    
    private var isGyroActive = false
    private var presentedGyroAlert = false
    
    private var isOrientationLocked = false
    private var lockedOrientation: UIInterfaceOrientationMask? = nil
    
    private var presentedJITAlert = false
    
    private var overrideToastNotification = false
    
    public var deepLinkSaveState: SaveState? {
        didSet {
            if let deepLinkSaveState = self.deepLinkSaveState
            {
                self._isLoadingSaveState = true
                self.overrideToastNotification = true
                
                self.load(deepLinkSaveState)
                
                self.deepLinkSaveState = nil
            }
        }
    }
    
    override var shouldAutorotate: Bool {
        if #available(iOS 16, *)
        {
            return false
        }
        else
        {
            return !(self.isGyroActive || self.isOrientationLocked)
        }
    }
    
    override var supportedInterfaceOrientations: UIInterfaceOrientationMask {
        if Settings.gameplayFeatures.rotationLock.isEnabled || self.isGyroActive,
           let orientation = self.lockedOrientation,
           #available(iOS 16, *)
        {
            return orientation
        }
        else
        {
            return .all
        }
    }
    
    override var preferredScreenEdgesDeferringSystemGestures: UIRectEdge {
        return .all
    }
    
    override var prefersStatusBarHidden: Bool {
        return !((Settings.userInterfaceFeatures.statusBar.isOn && Settings.userInterfaceFeatures.statusBar.isEnabled) || (!Settings.userInterfaceFeatures.statusBar.useToggle && Settings.userInterfaceFeatures.statusBar.isEnabled))
    }
    
    override var preferredStatusBarStyle: UIStatusBarStyle {
        return UIStatusBarStyle(rawValue: Settings.userInterfaceFeatures.statusBar.style.rawValue) ?? .default
    }
    
    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)

        self.updateBlurBackground()
    }
    
    required init()
    {
        super.init()
        
        self.initialize()
    }
    
    required init?(coder aDecoder: NSCoder)
    {
        super.init(coder: aDecoder)
        
        self.initialize()
    }
    
    private func initialize()
    {
        self.delegate = self
        
        NotificationCenter.default.addObserver(self, selector: #selector(GameViewController.updateControllers), name: .externalGameControllerDidConnect, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(GameViewController.updateControllers), name: .externalGameControllerDidDisconnect, object: nil)
        
        NotificationCenter.default.addObserver(self, selector: #selector(GameViewController.didEnterBackground(with:)), name: UIApplication.didEnterBackgroundNotification, object: UIApplication.shared)
        NotificationCenter.default.addObserver(self, selector: #selector(GameViewController.didBecomeActiveApp(with:)), name: UIScene.didActivateNotification, object: nil)
        
        NotificationCenter.default.addObserver(self, selector: #selector(GameViewController.settingsDidChange(with:)), name: Settings.didChangeNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(GameViewController.deepLinkControllerLaunchGame(with:)), name: .deepLinkControllerLaunchGame, object: nil)
        
        NotificationCenter.default.addObserver(self, selector: #selector(GameViewController.didActivateGyro(with:)), name: GBA.didActivateGyroNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(GameViewController.didDeactivateGyro(with:)), name: GBA.didDeactivateGyroNotification, object: nil)
        
        NotificationCenter.default.addObserver(self, selector: #selector(GameViewController.emulationDidQuit(with:)), name: EmulatorCore.emulationDidQuitNotification, object: nil)
        
        NotificationCenter.default.addObserver(self, selector: #selector(GameViewController.didEnableJIT(with:)), name: ServerManager.didEnableJITNotification, object: nil)
        
        NotificationCenter.default.addObserver(self, selector: #selector(GameViewController.sceneWillConnect(with:)), name: UIScene.willConnectNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(GameViewController.sceneDidDisconnect(with:)), name: UIScene.didDisconnectNotification, object: nil)
        
        NotificationCenter.default.addObserver(self, selector: #selector(GameViewController.unwindFromQuickSettings), name: .unwindFromSettings, object: nil)
        
        NotificationCenter.default.addObserver(self, selector: #selector(GameViewController.deviceDidShake(with:)), name: UIDevice.deviceDidShakeNotification, object: nil)
    }
    
    deinit
    {
        self.emulatorCore?.removeObserver(self, forKeyPath: #keyPath(EmulatorCore.state), context: &kvoContext)
        
        self.invalidateRewindTimer()
    }
    
    // MARK: - GameControllerReceiver -
    override func gameController(_ gameController: GameController, didActivate input: Input, value: Double)
    {
        super.gameController(gameController, didActivate: input, value: value)
        
        if self.isSelectingSustainedButtons
        {
            guard let pausingGameController = self.pausingGameController, gameController == pausingGameController else { return }
            
            if input != StandardGameControllerInput.menu,
               input.stringValue != "quickSettings"
            {
                self.inputsToSustain[AnyInput(input)] = value
            }
            
            if input.stringValue == "quickSettings"
            {
                self.performQuickSettingsAction()
            }
        }
        else if let emulatorCore = self.emulatorCore, emulatorCore.state == .running
        {
            guard let actionInput = ActionInput(input: input) else { return }
            
            switch actionInput
            {
            case .restart: self.performRestartAction()
            case .quickSave: self.performQuickSaveAction()
            case .quickLoad: self.performQuickLoadAction()
            case .screenshot: self.performScreenshotAction()
            case .statusBar: self.performStatusBarAction()
            case .toggleAltRepresentations: self.performAltRepresentationsAction()
                
            case .quickSettings:
                if let action = Settings.gameplayFeatures.quickSettings.buttonReplacement
                {
                    switch action
                    {
                    case .fastForward:
                        if Settings.gameplayFeatures.fastForward.toggle
                        {
                            let isFastForwarding = (emulatorCore.rate != emulatorCore.deltaCore.supportedRates.lowerBound)
                            self.performFastForwardAction(activate: !isFastForwarding)
                        }
                        else
                        {
                            self.performFastForwardAction(activate: true)
                        }
                        
                    case .quickSave: self.performQuickSaveAction()
                    case .quickLoad: self.performQuickLoadAction()
                    case .screenshot: self.performScreenshotAction()
                    case .restart: self.performRestartAction()
                    default: break
                    }
                }
                else
                {
                    self.performQuickSettingsAction()
                }
                
            case .toggleFastForward, .fastForward:
                if Settings.gameplayFeatures.fastForward.toggle
                {
                    let isFastForwarding = (emulatorCore.rate != emulatorCore.deltaCore.supportedRates.lowerBound)
                    self.performFastForwardAction(activate: !isFastForwarding)
                }
                else
                {
                    self.performFastForwardAction(activate: true)
                }
            }
        }
    }
    
    override func gameController(_ gameController: GameController, didDeactivate input: Input)
    {
        super.gameController(gameController, didDeactivate: input)
        
        if self.isSelectingSustainedButtons
        {
            if input.isContinuous
            {
                self.inputsToSustain[AnyInput(input)] = nil
            }
        }
        else
        {
            guard let actionInput = ActionInput(input: input) else { return }
            
            switch actionInput
            {
            case .restart: break
            case .quickSave: break
            case .quickLoad: break
            case .screenshot: break
            case .statusBar: break
            case .quickSettings: break
            case .fastForward, .toggleFastForward:
                if !Settings.gameplayFeatures.fastForward.toggle
                {
                    self.performFastForwardAction(activate: false)
                }
            case .toggleAltRepresentations: break
            }
        }
    }
}


//MARK: - UIViewController -
/// UIViewController
extension GameViewController
{
    override func viewDidLoad()
    {
        super.viewDidLoad()
        
        // Lays out self.gameView, so we can pin self.sustainButtonsContentView to it without resulting in a temporary "cannot satisfy constraints".
        self.view.layoutIfNeeded()
        
        self.controllerView.translucentControllerSkinOpacity = Settings.controllerSkinFeatures.skinCustomization.isEnabled ? Settings.controllerSkinFeatures.skinCustomization.opacity : 0.7
        
        self.airPlayContentView = UIView(frame: CGRect(x: 0, y: 0, width: self.gameView.bounds.width, height: self.gameView.bounds.height))
        self.airPlayContentView.translatesAutoresizingMaskIntoConstraints = false
        self.airPlayContentView.isHidden = true
        self.view.insertSubview(self.airPlayContentView, aboveSubview: self.gameView)
        
        self.sustainButtonsContentView = UIView(frame: CGRect(x: 0, y: 0, width: self.gameView.bounds.width, height: self.gameView.bounds.height))
        self.sustainButtonsContentView.translatesAutoresizingMaskIntoConstraints = false
        self.sustainButtonsContentView.isHidden = true
        self.view.insertSubview(self.sustainButtonsContentView, aboveSubview: self.airPlayContentView)
        
        let blurEffect = UIBlurEffect(style: .dark)
        let vibrancyEffect = UIVibrancyEffect(blurEffect: blurEffect)
        
        self.airPlayBlurView = UIVisualEffectView(effect: blurEffect)
        self.airPlayBlurView.frame = CGRect(x: 0, y: 0, width: self.airPlayContentView.bounds.width, height: self.airPlayContentView.bounds.height)
        self.airPlayBlurView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        self.airPlayContentView.addSubview(self.airPlayBlurView)
        
        self.sustainButtonsBlurView = UIVisualEffectView(effect: blurEffect)
        self.sustainButtonsBlurView.frame = CGRect(x: 0, y: 0, width: self.sustainButtonsContentView.bounds.width, height: self.sustainButtonsContentView.bounds.height)
        self.sustainButtonsBlurView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        self.sustainButtonsContentView.addSubview(self.sustainButtonsBlurView)
        
        let airPlayVibrancyView = UIVisualEffectView(effect: vibrancyEffect)
        airPlayVibrancyView.frame = CGRect(x: 0, y: 0, width: self.airPlayBlurView.contentView.bounds.width, height: self.airPlayBlurView.contentView.bounds.height)
        airPlayVibrancyView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        self.airPlayBlurView.contentView.addSubview(airPlayVibrancyView)
        
        let sustainButtonsVibrancyView = UIVisualEffectView(effect: vibrancyEffect)
        sustainButtonsVibrancyView.frame = CGRect(x: 0, y: 0, width: self.sustainButtonsBlurView.contentView.bounds.width, height: self.sustainButtonsBlurView.contentView.bounds.height)
        sustainButtonsVibrancyView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        self.sustainButtonsBlurView.contentView.addSubview(sustainButtonsVibrancyView)
        
        self.airPlayBackgroundView = RSTPlaceholderView(frame: CGRect(x: 0, y: 0, width: airPlayVibrancyView.contentView.bounds.width, height: airPlayVibrancyView.contentView.bounds.height))
        self.airPlayBackgroundView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        self.airPlayBackgroundView.imageView.image = UIImage(named: "AirPlay")
        self.airPlayBackgroundView.imageView.isHidden = false
        self.airPlayBackgroundView.textLabel.text = NSLocalizedString("AirPlaying", comment: "")
        self.airPlayBackgroundView.textLabel.numberOfLines = 1
        self.airPlayBackgroundView.textLabel.minimumScaleFactor = 0.5
        self.airPlayBackgroundView.textLabel.adjustsFontSizeToFitWidth = true
        self.airPlayBackgroundView.detailTextLabel.text = NSLocalizedString("", comment: "")
        self.airPlayBackgroundView.alpha = 0.0
        airPlayVibrancyView.contentView.addSubview(self.airPlayBackgroundView)
        
        self.sustainButtonsBackgroundView = RSTPlaceholderView(frame: CGRect(x: 0, y: 0, width: sustainButtonsVibrancyView.contentView.bounds.width, height: sustainButtonsVibrancyView.contentView.bounds.height))
        self.sustainButtonsBackgroundView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        self.sustainButtonsBackgroundView.textLabel.text = NSLocalizedString("Select Buttons to Hold Down", comment: "")
        self.sustainButtonsBackgroundView.textLabel.numberOfLines = 1
        self.sustainButtonsBackgroundView.textLabel.minimumScaleFactor = 0.5
        self.sustainButtonsBackgroundView.textLabel.adjustsFontSizeToFitWidth = true
        self.sustainButtonsBackgroundView.detailTextLabel.text = NSLocalizedString("Press the Menu button or Quick Settings button when finished.", comment: "")
        self.sustainButtonsBackgroundView.alpha = 0.0
        sustainButtonsVibrancyView.contentView.addSubview(self.sustainButtonsBackgroundView)
        
        // Auto Layout
        self.airPlayContentView.leadingAnchor.constraint(equalTo: self.gameView.leadingAnchor).isActive = true
        self.airPlayContentView.trailingAnchor.constraint(equalTo: self.gameView.trailingAnchor).isActive = true
        self.airPlayContentView.topAnchor.constraint(equalTo: self.gameView.topAnchor).isActive = true
        self.airPlayContentView.bottomAnchor.constraint(equalTo: self.gameView.bottomAnchor).isActive = true
        
        self.sustainButtonsContentView.leadingAnchor.constraint(equalTo: self.gameView.leadingAnchor).isActive = true
        self.sustainButtonsContentView.trailingAnchor.constraint(equalTo: self.gameView.trailingAnchor).isActive = true
        self.sustainButtonsContentView.topAnchor.constraint(equalTo: self.gameView.topAnchor).isActive = true
        self.sustainButtonsContentView.bottomAnchor.constraint(equalTo: self.gameView.bottomAnchor).isActive = true
        
        self.updateControllers()
    }
    
    override func viewDidAppear(_ animated: Bool)
    {
        super.viewDidAppear(animated)
        
        if self.emulatorCore?.deltaCore == DS.core, UserDefaults.standard.desmumeDeprecatedAlertCount < 3
        {
            let toastView = RSTToastView(text: NSLocalizedString("DeSmuME Core Deprecated", comment: ""), detailText: NSLocalizedString("Switch to the melonDS core in Settings for latest improvements.", comment: ""))
            self.show(toastView, duration: 5.0)
            
            UserDefaults.standard.desmumeDeprecatedAlertCount += 1
        }
        else if self.emulatorCore?.deltaCore == MelonDS.core, ProcessInfo.processInfo.isJITAvailable
        {
            self.showJITEnabledAlert()
        }
        
        self.activateRewindTimer()
    }
    
    override func viewWillTransition(to size: CGSize, with coordinator: UIViewControllerTransitionCoordinator)
    {
        super.viewWillTransition(to: size, with: coordinator)
        
        guard UIApplication.shared.applicationState != .background else { return }
                
        coordinator.animate(alongsideTransition: { (context) in
            self.updateControllerSkin()
        }, completion: nil)        
    }
    
    // MARK: - Segues
    /// KVO
    
    override func prepare(for segue: UIStoryboardSegue, sender: Any?)
    {
        guard let identifier = segue.identifier else { return }
        
        switch identifier
        {
        case "showInitialGamesViewController":
            let gamesViewController = (segue.destination as! UINavigationController).topViewController as! GamesViewController
            
            gamesViewController.theme = .opaque
            gamesViewController.showResumeButton = false
            
        case "showGamesViewController":
            let gamesViewController = (segue.destination as! UINavigationController).topViewController as! GamesViewController
            
            if let emulatorCore = self.emulatorCore
            {
                gamesViewController.theme = .translucent
                gamesViewController.activeEmulatorCore = emulatorCore
                gamesViewController.showResumeButton = true
                
                self.updateAutoSaveState()
            }
            else
            {
                gamesViewController.theme = .opaque
                gamesViewController.showResumeButton = false
            }
            
        case "pause":
            
            if let game = self.game
            {
                let fileURL = FileManager.default.uniqueTemporaryURL()
                self.pausedSaveState = PausedSaveState(fileURL: fileURL, gameType: game.type)
                
                self.emulatorCore?.saveSaveState(to: fileURL)
            }

            guard let gameController = sender as? GameController else {
                fatalError("sender for pauseSegue must be the game controller that pressed the Menu button")
            }
            
            self.pausingGameController = gameController
            
            let pauseViewController = segue.destination as! PauseViewController
            pauseViewController.pauseText = (self.game as? Game)?.name ?? NSLocalizedString("Ignited", comment: "")
            pauseViewController.emulatorCore = self.emulatorCore
            pauseViewController.saveStatesViewControllerDelegate = self
            if Settings.gameplayFeatures.cheats.isEnabled {
                pauseViewController.cheatsViewControllerDelegate = self
            }
            
            pauseViewController.restartItem?.action = { [unowned self] item in
                self.performRestartAction()
            }
            
            pauseViewController.screenshotItem?.action = { [unowned self] item in
                self.performScreenshotAction()
            }
            
            pauseViewController.statusBarItem?.isSelected = Settings.userInterfaceFeatures.statusBar.isOn
            pauseViewController.statusBarItem?.action = { [unowned self] item in
                self.performStatusBarAction()
            }
            
            pauseViewController.fastForwardItem?.isSelected = (self.emulatorCore?.rate != self.emulatorCore?.deltaCore.supportedRates.lowerBound)
            pauseViewController.fastForwardItem?.action = { [unowned self] item in
                self.performFastForwardAction(activate: item.isSelected)
            }
            
            pauseViewController.rotationLockItem?.isSelected = self.isOrientationLocked
            pauseViewController.rotationLockItem?.action = { [unowned self] item in
                self.performRotationLockAction()
            }
            
            pauseViewController.paletteItem?.action = { [unowned self] item in
                self.performPaletteAction()
            }
            
            pauseViewController.quickSettingsItem?.action = { [unowned self] item in
                self.performQuickSettingsAction()
            }
            
            pauseViewController.blurBackgroudItem?.isSelected = Settings.controllerSkinFeatures.backgroundBlur.blurBackground
            pauseViewController.blurBackgroudItem?.action = { [unowned self] item in
                self.performBlurBackgroundAction()
            }
            
            pauseViewController.altSkinItem?.isSelected = Settings.advancedFeatures.skinDebug.useAlt
            pauseViewController.altSkinItem?.action = { [unowned self] item in
                self.performAltRepresentationsAction()
            }
            
            pauseViewController.debugModeItem?.isSelected = Settings.advancedFeatures.skinDebug.isOn
            pauseViewController.debugModeItem?.action = { [unowned self] item in
                self.performDebugModeAction()
            }
            
            pauseViewController.sustainButtonsItem?.isSelected = gameController.sustainedInputs.count > 0
            pauseViewController.sustainButtonsItem?.action = { [unowned self, unowned pauseViewController] item in
                
                for input in gameController.sustainedInputs.keys
                {
                    gameController.unsustain(input)
                }
                
                if item.isSelected
                {
                    self.showSustainButtonView()
                    pauseViewController.dismiss()
                }
                
                // Re-set gameController as pausingGameController.
                self.pausingGameController = gameController
            }
            
            if self.emulatorCore?.deltaCore.supportedRates.upperBound == 1
            {
                pauseViewController.fastForwardItem = nil
            }
            
            if let game = self.game,
               game.type != .gbc
            {
                pauseViewController.paletteItem = nil
            }
            
            switch self.game?.type
            {
            case .ds? where self.emulatorCore?.deltaCore == DS.core:
                // Cheats are not supported by DeSmuME core.
                pauseViewController.cheatCodesItem = nil
                
            case .genesis?:
                // GPGX core does not support cheats yet.
                pauseViewController.cheatCodesItem = nil
                // GPGX core does not support background blur yet.
                pauseViewController.blurBackgroudItem = nil
                
            case .gbc?:
                // Rewind is disabled on GBC. Crashes gambette
                pauseViewController.rewindItem = nil

            default: break
            }
            
            if !Settings.controllerSkinFeatures.backgroundBlur.blurOverride,
               self.controllerView.backgroundBlur != nil
            {
                pauseViewController.blurBackgroudItem = nil
            }
            
            if !Settings.controllerSkinFeatures.backgroundBlur.blurAirPlay
            {
                pauseViewController.blurBackgroudItem = nil
            }
            
            let url = self.game?.fileURL
            let fileName = url!.path.components(separatedBy: "/").last
            
            switch fileName
            {
            case "dsi.bios":
                pauseViewController.rewindItem = nil
                pauseViewController.saveStateItem = nil
                pauseViewController.loadStateItem = nil
                pauseViewController.cheatCodesItem = nil
                
            case "nds.bios":
                pauseViewController.cheatCodesItem = nil
                
            default: break
            }
            
            self.pauseViewController = pauseViewController
            
        default: break
        }
    }
    
    @IBAction private func unwindFromPauseViewController(_ segue: UIStoryboardSegue)
    {
        self.pauseViewController = nil
        self.pausingGameController = nil
        
        guard let identifier = segue.identifier else { return }
        
        switch identifier
        {
        case "unwindFromPauseMenu":
            
            self.pausedSaveState = nil
            
            DispatchQueue.main.async {
                
                if self._isLoadingSaveState
                {
                    // If loading save state, resume emulation immediately (since the game view needs to be updated ASAP)
                    
                    if self.resumeEmulation()
                    {
                        // Temporarily disable audioManager to prevent delayed audio bug when using 3D Touch Peek & Pop
                        self.emulatorCore?.audioManager.isEnabled = false
                        
                        // Re-enable after delay
                        
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                            self.emulatorCore?.audioManager.isEnabled = true
                        }
                    }
                }
                else
                {
                    // Otherwise, wait for the transition to complete before resuming emulation
                    self.transitionCoordinator?.animate(alongsideTransition: nil, completion: { (context) in
                        self.resumeEmulation()
                    })
                }
                
                self._isLoadingSaveState = false
                
                if self.emulatorCore?.deltaCore == MelonDS.core, ProcessInfo.processInfo.isJITAvailable
                {
                    self.transitionCoordinator?.animate(alongsideTransition: nil, completion: { (context) in
                        self.showJITEnabledAlert()
                    })
                }
            }
            
        case "unwindToGames":
            DispatchQueue.main.async {
                self.transitionCoordinator?.animate(alongsideTransition: nil, completion: { (context) in
                    self.performSegue(withIdentifier: "showGamesViewController", sender: nil)
                })
            }
            
        default: break
        }
    }
    
    @IBAction private func unwindFromGamesViewController(with segue: UIStoryboardSegue)
    {
        self.pausedSaveState = nil
        
        if let emulatorCore = self.emulatorCore, emulatorCore.state == .paused
        {
            emulatorCore.resume()
        }
    }
    
    // MARK: - KVO
    /// KVO
    override func observeValue(forKeyPath keyPath: String?, of object: Any?, change: [NSKeyValueChangeKey : Any]?, context: UnsafeMutableRawPointer?)
    {
        guard context == &kvoContext else { return super.observeValue(forKeyPath: keyPath, of: object, change: change, context: context) }
        
        guard let rawValue = change?[.oldKey] as? Int, let previousState = EmulatorCore.State(rawValue: rawValue) else { return }
        
        if let saveState = _deepLinkResumingSaveState, let emulatorCore = self.emulatorCore, emulatorCore.state == .running
        {
            emulatorCore.pause()
            
            do
            {
                try emulatorCore.load(saveState)
            }
            catch
            {
                print(error)
            }
            
            _deepLinkResumingSaveState = nil
            emulatorCore.resume()
        }
        
        if previousState == .stopped
        {
            self.emulatorCore?.updateCheats()
        }
        
        if self.emulatorCore?.state == .running
        {
            DatabaseManager.shared.performBackgroundTask { (context) in
                guard let game = self.game as? Game else { return }
                
                let backgroundGame = context.object(with: game.objectID) as! Game
                backgroundGame.playedDate = Date()
                
                context.saveWithErrorLogging()
            }
        }
    }
}

//MARK: - Controllers -
private extension GameViewController
{
    @objc func updateControllers()
    {
        let isExternalGameControllerConnected = ExternalGameControllerManager.shared.connectedControllers.contains(where: { $0.playerIndex != nil })
        if !isExternalGameControllerConnected && Settings.localControllerPlayerIndex == nil
        {
            Settings.localControllerPlayerIndex = 0
        }
        
        // If Settings.localControllerPlayerIndex is non-nil, and there isn't a connected controller with same playerIndex, show controller view.
        if let index = Settings.localControllerPlayerIndex, !ExternalGameControllerManager.shared.connectedControllers.contains(where: { $0.playerIndex == index })
        {
            self.controllerView.playerIndex = index
            self.controllerView.isHidden = false
        }
        else
        {
            if let game = self.game,
               let traits = self.controllerView.controllerSkinTraits,
               let controllerSkin = DeltaCore.ControllerSkin.standardControllerSkin(for: game.type),
               controllerSkin.hasTouchScreen(for: traits)
            {
                if !(Settings.controllerSkinFeatures.skinCustomization.alwaysShow && Settings.controllerSkinFeatures.skinCustomization.isEnabled)
                {
                    Settings.localControllerPlayerIndex = nil
                }
                else
                {
                    Settings.localControllerPlayerIndex = 0
                }
                self.controllerView.isHidden = false
                self.controllerView.playerIndex = 0
            }
            else
            {
                if !(Settings.controllerSkinFeatures.skinCustomization.alwaysShow && Settings.controllerSkinFeatures.skinCustomization.isEnabled)
                {
                    self.controllerView.isHidden = true
                    self.controllerView.playerIndex = nil // TODO: Does this need changed to 0?
                    Settings.localControllerPlayerIndex = nil
                }
                else
                {
                    self.controllerView.isHidden = false
                    self.controllerView.playerIndex = 0
                    Settings.localControllerPlayerIndex = 0
                }
            }
        }
        
        self.view.setNeedsLayout()
        self.view.layoutIfNeeded()
        
        // Roundabout way of combining arrays to prevent rare runtime crash in + operator :(
        var controllers = [GameController]()
        controllers.append(self.controllerView)
        controllers.append(contentsOf: ExternalGameControllerManager.shared.connectedControllers)
        
        if let emulatorCore = self.emulatorCore, let game = self.game
        {
            for gameController in controllers
            {
                if gameController.playerIndex != nil
                {
                    let inputMapping: GameControllerInputMappingProtocol
                    
                    if let mapping = GameControllerInputMapping.inputMapping(for: gameController, gameType: game.type, in: DatabaseManager.shared.viewContext)
                    {
                        inputMapping = mapping
                    }
                    else
                    {
                        inputMapping = DefaultInputMapping(gameController: gameController)
                    }
                    
                    gameController.addReceiver(self, inputMapping: inputMapping)
                    gameController.addReceiver(emulatorCore, inputMapping: inputMapping)
                }
                else
                {
                    gameController.removeReceiver(self)
                    gameController.removeReceiver(emulatorCore)
                }
            }
        }
        
        if self.shouldResetSustainedInputs
        {
            for controller in controllers
            {
                for input in controller.sustainedInputs.keys
                {
                    controller.unsustain(input)
                }
            }
            
            self.shouldResetSustainedInputs = false
        }
        
        let vibrationEnabled = Settings.touchFeedbackFeatures.touchVibration.isEnabled
        self.controllerView.isButtonHapticFeedbackEnabled = Settings.touchFeedbackFeatures.touchVibration.buttonsEnabled && vibrationEnabled
        self.controllerView.isThumbstickHapticFeedbackEnabled = Settings.touchFeedbackFeatures.touchVibration.sticksEnabled && vibrationEnabled
        self.controllerView.isClickyHapticEnabled = Settings.touchFeedbackFeatures.touchVibration.releaseEnabled && vibrationEnabled
        self.controllerView.hapticFeedbackStrength = Settings.touchFeedbackFeatures.touchVibration.strength
        
        self.controllerView.isButtonTouchOverlayEnabled = Settings.touchFeedbackFeatures.touchOverlay.isEnabled
        self.controllerView.touchOverlayOpacity = Settings.touchFeedbackFeatures.touchOverlay.opacity
        self.controllerView.touchOverlaySize = Settings.touchFeedbackFeatures.touchOverlay.size
        self.controllerView.touchOverlayColor = Settings.touchFeedbackFeatures.touchOverlay.themed ? UIColor.themeColor : UIColor(Settings.touchFeedbackFeatures.touchOverlay.overlayColor)
        self.controllerView.touchOverlayStyle = Settings.touchFeedbackFeatures.touchOverlay.style
        
        self.controllerView.isAltRepresentationsEnabled = Settings.advancedFeatures.skinDebug.useAlt
        self.controllerView.isDebugModeEnabled = Settings.advancedFeatures.skinDebug.isOn
        
        self.controllerView.updateControllerSkin()
        self.updateControllerSkin()
        
        self.updateButtonAudioFeedbackSound()
        self.updateGameboyPalette()
        self.updateBlurBackground()
        self.updateControllerSkinCustomization()
        self.updateControllerTriggerDeadzone()
    }
    
    func updateControllerTriggerDeadzone()
    {
        for gameController in ExternalGameControllerManager.shared.connectedControllers
        {
            gameController.triggerDeadzone = Settings.controllerSkinFeatures.controller.isEnabled ? Float(Settings.controllerSkinFeatures.controller.triggerDeadzone) : 0.15
        }
    }
    
    func updateButtonAudioFeedbackSound()
    {
        let sound = Settings.touchFeedbackFeatures.touchAudio.sound
        
        guard let buttonSoundURL = Bundle.main.url(forResource: sound.fileName, withExtension: sound.fileExtension) else
        {
            fatalError("Audio file not found")
        }
        
        do
        {
            try self.buttonSoundFile = AVAudioFile(forReading: buttonSoundURL)
            try self.buttonSoundPlayer = AVAudioPlayer(contentsOf: buttonSoundURL)
            
            self.buttonSoundPlayer?.volume = Float(Settings.touchFeedbackFeatures.touchAudio.buttonVolume)
        }
        catch
        {
            print(error)
        }
        
        if Settings.touchFeedbackFeatures.touchAudio.useGameVolume
        {
            self.controllerView.buttonPressedHandler = { [weak self] () in
                if Settings.touchFeedbackFeatures.touchAudio.isEnabled,
                   let core = self?.emulatorCore,
                   let buttonSoundFile = self?.buttonSoundFile
                {
                    core.audioManager.playButtonSound(buttonSoundFile)
                }
            }
        }
        else
        {
            self.controllerView.buttonPressedHandler = { [weak self] () in
                if Settings.touchFeedbackFeatures.touchAudio.isEnabled,
                   let core = self?.emulatorCore,
                   let buttonSoundPlayer = self?.buttonSoundPlayer
                {
                    buttonSoundPlayer.play()
                }
            }
        }
                
    }
    
    func playButtonAudioFeedbackSound()
    {
        if let buttonSoundPlayer = self.buttonSoundPlayer
        {
            buttonSoundPlayer.volume = 1.0
            buttonSoundPlayer.play()
            buttonSoundPlayer.volume = Float(Settings.touchFeedbackFeatures.touchAudio.buttonVolume)
        }
    }
    
    func updateStatusBar()
    {
        self.setNeedsStatusBarAppearanceUpdate()
    }
    
    func updateControllerSkin()
    {
        guard let game = self.game as? Game, let window = self.view.window else { return }
        
        var traits = DeltaCore.ControllerSkin.Traits.defaults(for: window)
        
        if (Settings.advancedFeatures.skinDebug.skinEnabled || Settings.advancedFeatures.skinDebug.isEnabled) && Settings.advancedFeatures.skinDebug.traitOverride
        {
            switch Settings.advancedFeatures.skinDebug.device
            {
            case .iphone: traits.device = .iphone
            case .ipad: traits.device = .ipad
            case .tv: traits.device = .tv
            }
            
            switch Settings.advancedFeatures.skinDebug.displayType
            {
            case .standard: traits.displayType = .standard
            case .edgeToEdge: traits.displayType = .edgeToEdge
            case .splitView: traits.displayType = .splitView
            }
            
            self.controllerView.overrideControllerSkinTraits = traits
        }
        else
        {
            self.controllerView.overrideControllerSkinTraits = nil
        }
        
        if Settings.localControllerPlayerIndex != nil
        {
            let controllerSkin = Settings.preferredControllerSkin(for: game, traits: traits)
            self.controllerView.controllerSkin = controllerSkin
        }
        else if let controllerSkin = DeltaCore.ControllerSkin.standardControllerSkin(for: game.type), controllerSkin.hasTouchScreen(for: traits)
        {
            var touchControllerSkin = TouchControllerSkin(controllerSkin: controllerSkin)
            
            if UIApplication.shared.isExternalDisplayConnected
            {
                // Only show touch screen if external display is connected.
                touchControllerSkin.screenPredicate = { $0.isTouchScreen }
            }
            
            if self.view.bounds.width > self.view.bounds.height
            {
                touchControllerSkin.screenLayoutAxis = .horizontal
            }
            else
            {
                touchControllerSkin.screenLayoutAxis = .vertical
            }
            
            self.controllerView.controllerSkin = touchControllerSkin
        }
        
        Settings.advancedFeatures.skinDebug.skinEnabled = self.controllerView.controllerSkin?.isDebugModeEnabled ?? false
        Settings.advancedFeatures.skinDebug.hasAlt = self.controllerView.controllerSkin?.hasAltRepresentations ?? false
        
        self.updateExternalDisplay()
        
        self.view.setNeedsLayout()
    }
    
    func updateGameViews()
    {
        if UIApplication.shared.isExternalDisplayConnected,
           !Settings.controllerSkinFeatures.airPlayKeepScreen.isEnabled
        {
            // AirPlaying, hide all screens except touchscreens and blur screens.
                 
            if let traits = self.controllerView.controllerSkinTraits, let screens = self.screens(for: traits)
            {
                for (screen, gameView) in zip(screens, self.gameViews)
                {
                    let enableBlurScreen = screen.id == "gameViewController.screen.blur" && Settings.controllerSkinFeatures.backgroundBlur.blurAirPlay
                    
                    let enabled = screen.isTouchScreen || enableBlurScreen
                    
                    gameView.isEnabled = enabled
                    gameView.isHidden = !enabled
                }
            }
            else
            {
                // Either self.controllerView.controllerSkin is `nil`, or it doesn't support these traits.
                // Most likely this system only has 1 screen, so just hide self.gameView.
                     
                self.gameView.isEnabled = false
                self.gameView.isHidden = true
            }
        }
        else
        {
            // Not AirPlaying, show all screens.
                 
            for gameView in self.gameViews
            {
                gameView.isEnabled = true
                gameView.isHidden = false
            }
        }
    }
    
    @objc func unwindFromQuickSettings()
    {
        self._isQuickSettingsOpen = false
        
        self.updateBlurBackground()
    }
    
    func updateBlurBackground()
    {
        self.blurScreenKeepAspect = Settings.controllerSkinFeatures.backgroundBlur.blurAspect
        self.blurScreenOverride = Settings.controllerSkinFeatures.backgroundBlur.blurOverride
        self.blurScreenStrength = Settings.controllerSkinFeatures.backgroundBlur.blurStrength
        if Settings.controllerSkinFeatures.backgroundBlur.blurTint
        {
            switch UITraitCollection.current.userInterfaceStyle
            {
            case .light:
                self.blurScreenBrightness = Settings.controllerSkinFeatures.backgroundBlur.blurTintIntensity
                
            case .dark, .unspecified:
                var intensity = Settings.controllerSkinFeatures.backgroundBlur.blurTintIntensity
                intensity.negate()
                self.blurScreenBrightness = intensity
            }
        }
        else
        {
            self.blurScreenBrightness = Settings.controllerSkinFeatures.backgroundBlur.blurBrightness
        }
        
        // Set enabled last as it's the property that triggers updateGameViews()
        if let game = self.game,
           game.type == .genesis
        {
            self.blurScreenEnabled = false //TODO: Fix background blur on genesis
        }
        else
        {
            self.blurScreenEnabled = Settings.controllerSkinFeatures.backgroundBlur.isEnabled ? Settings.controllerSkinFeatures.backgroundBlur.blurBackground : false
        }
        
    }
    
    func updateGameboyPalette()
    {
        if let bridge = self.emulatorCore?.deltaCore.emulatorBridge as? GBCEmulatorBridge
        {
            if Settings.gbcFeatures.palettes.isEnabled
            {
                if Settings.gbcFeatures.palettes.multiPalette
                {
                    setMultiPalette(palette1: Settings.gbcFeatures.palettes.palette.colors,
                                    palette2: Settings.gbcFeatures.palettes.spritePalette1.colors,
                                    palette3: Settings.gbcFeatures.palettes.spritePalette2.colors)
                }
                else
                {
                    setSinglePalette(palette: Settings.gbcFeatures.palettes.palette.colors)
                }
            }
            else
            {
                setSinglePalette(palette: GameboyPalette.nilColors)
            }
            
            bridge.updatePalette()
            
            
            func setSinglePalette(palette: [UInt32])
            {
                bridge.palette0color0 = palette[0]
                bridge.palette0color1 = palette[1]
                bridge.palette0color2 = palette[2]
                bridge.palette0color3 = palette[3]
                bridge.palette1color0 = palette[0]
                bridge.palette1color1 = palette[1]
                bridge.palette1color2 = palette[2]
                bridge.palette1color3 = palette[3]
                bridge.palette2color0 = palette[0]
                bridge.palette2color1 = palette[1]
                bridge.palette2color2 = palette[2]
                bridge.palette2color3 = palette[3]
            }
            
            func setMultiPalette(palette1: [UInt32], palette2: [UInt32], palette3: [UInt32])
            {
                bridge.palette0color0 = palette1[0]
                bridge.palette0color1 = palette1[1]
                bridge.palette0color2 = palette1[2]
                bridge.palette0color3 = palette1[3]
                bridge.palette1color0 = palette2[0]
                bridge.palette1color1 = palette2[1]
                bridge.palette1color2 = palette2[2]
                bridge.palette1color3 = palette2[3]
                bridge.palette2color0 = palette3[0]
                bridge.palette2color1 = palette3[1]
                bridge.palette2color2 = palette3[2]
                bridge.palette2color3 = palette3[3]
            }
        }
    }
    
    func updateEmulationSpeed()
    {
        self.emulatorCore?.rate = Settings.gameplayFeatures.quickSettings.fastForwardSpeed
    }
    
    func updateControllerSkinCustomization()
    {
        self.controllerView.translucentControllerSkinOpacity = Settings.controllerSkinFeatures.skinCustomization.isEnabled ? Settings.controllerSkinFeatures.skinCustomization.opacity : 0.7
        
        if Settings.controllerSkinFeatures.skinCustomization.isEnabled
        {
            self.backgroundColor = Settings.controllerSkinFeatures.skinCustomization.matchTheme ? UIColor.themeColor : UIColor(Settings.controllerSkinFeatures.skinCustomization.backgroundColor)
        }
        else
        {
            self.backgroundColor = .black
        }
    }
}

//MARK: - Game Saves -
/// Game Saves
private extension GameViewController
{
    func updateGameSave()
    {
        guard let game = self.game as? Game else { return }
        
        DatabaseManager.shared.performBackgroundTask { (context) in
            do
            {
                let game = context.object(with: game.objectID) as! Game
                
                let hash = try RSTHasher.sha1HashOfFile(at: game.gameSaveURL)
                let previousHash = game.gameSave?.sha1
                
                guard hash != previousHash else { return }
                
                if let gameSave = game.gameSave
                {
                    gameSave.modifiedDate = Date()
                    gameSave.sha1 = hash
                }
                else
                {
                    let gameSave = GameSave(context: context)
                    gameSave.identifier = game.identifier
                    gameSave.sha1 = hash
                    game.gameSave = gameSave
                }
                
                try context.save()
                if Settings.userInterfaceFeatures.toasts.gameSave
                {
                    let text = NSLocalizedString("Game Saved", comment: "")
                    self.presentToastView(text: text)
                }
                
                // update auto save state to prevent overwriting newer game saves when loading latest auto save
                if game.type != .n64 // N64 saves game when saving state, causing loop
                {
                    self.updateAutoSaveState()
                }
            }
            catch CocoaError.fileNoSuchFile
            {
                // Ignore
            }
            catch
            {
                print("Error updating game save.", error)
            }
        }
    }
}

//MARK: - Save States -
/// Save States
extension GameViewController: SaveStatesViewControllerDelegate
{
    private func updateAutoSaveState(_ ignoringAutoSaveOption: Bool = false)
    {
        guard Settings.gameplayFeatures.saveStates.autoSave || ignoringAutoSaveOption else { return }
        
        // Ensures game is non-nil and also a Game subclass
        guard let game = self.game as? Game else { return }
        
        guard let emulatorCore = self.emulatorCore, emulatorCore.state != .stopped else { return }
        
        // If pausedSaveState exists and has already been saved, don't update auto save state
        // This prevents us from filling our auto save state slots with the same save state
        let savedPausedSaveState = self.pausedSaveState?.isSaved ?? false
        guard !savedPausedSaveState else { return }
        
        self.pausedSaveState?.isSaved = true
        
        // Must be done synchronously
        let backgroundContext = DatabaseManager.shared.newBackgroundContext()
        backgroundContext.performAndWait {
            
            let game = backgroundContext.object(with: game.objectID) as! Game
            
            let fetchRequest = SaveState.fetchRequest(for: game, type: .auto)
            fetchRequest.sortDescriptors = [NSSortDescriptor(key: #keyPath(SaveState.creationDate), ascending: true)]
            
            do
            {
                let saveStates = try fetchRequest.execute()
                
                if let saveState = saveStates.first, saveStates.count >= 2
                {
                    // If there are two or more auto save states, update the oldest one
                    self.update(saveState, with: self.pausedSaveState)
                    
                    // Tiny hack: SaveStatesViewController sorts save states by creation date, so we update the creation date too
                    // Simpler than deleting old save states ¯\_(ツ)_/¯
                    saveState.creationDate = saveState.modifiedDate
                }
                else
                {
                    // Otherwise, create a new one
                    let saveState = SaveState.insertIntoManagedObjectContext(backgroundContext)
                    saveState.type = .auto
                    saveState.game = game
                    
                    self.update(saveState, with: self.pausedSaveState)
                }
            }
            catch
            {
                print(error)
            }

            backgroundContext.saveWithErrorLogging()
        }
    }
    
    private func clearRewindSaveStates(afterDate: Date? = nil)
    {
        guard let game = self.game as? Game,
              Settings.gameplayFeatures.rewind.keepStates == false else { return }
        
        let fetchRequest = SaveState.fetchRequest(for: game, type: .rewind)
        fetchRequest.includesPropertyValues = false
        
        // if afterDate is included, we have rewound and should clear any rewind states that exist after our new time location
        if let afterDate = afterDate
        {
            fetchRequest.predicate = NSPredicate(format: "%K == %@ AND %K >= %@", #keyPath(SaveState.type), NSNumber(value: SaveStateType.rewind.rawValue), #keyPath(SaveState.creationDate), afterDate as NSDate)
        }
        else
        {
            fetchRequest.predicate = NSPredicate(format: "%K == %@", #keyPath(SaveState.type), NSNumber(value: SaveStateType.rewind.rawValue))
        }
        
        DatabaseManager.shared.performBackgroundTask { (context) in
            do
            {
                let saveStates = try context.fetch(fetchRequest)
                for saveState in saveStates {
                    let temporarySaveState = context.object(with: saveState.objectID)
                    context.delete(temporarySaveState)
                }
                context.saveWithErrorLogging()
            }
            catch
            {
                print(error)
            }
        }
    }
    
    private func update(_ saveState: SaveState, with replacementSaveState: SaveStateProtocol? = nil, shouldSuspendEmulation: Bool = true)
    {
        let isRunning = (self.emulatorCore?.state == .running)
        
        if isRunning && shouldSuspendEmulation
        {
            self.pauseEmulation()
        }
        
        if let replacementSaveState = replacementSaveState
        {
            do
            {
                if FileManager.default.fileExists(atPath: saveState.fileURL.path)
                {
                    // Don't use replaceItem(), since that removes the original file as well
                    try FileManager.default.removeItem(at: saveState.fileURL)
                }
                
                try FileManager.default.copyItem(at: replacementSaveState.fileURL, to: saveState.fileURL)
            }
            catch
            {
                print(error)
            }
        }
        else
        {
            self.emulatorCore?.saveSaveState(to: saveState.fileURL)
        }
        
        if let snapshot = self.emulatorCore?.videoManager.snapshot(), let data = snapshot.pngData()
        {
            do
            {
                try data.write(to: saveState.imageFileURL, options: [.atomicWrite])
            }
            catch
            {
                print(error)
            }
        }
        
        saveState.modifiedDate = Date()
        saveState.coreIdentifier = self.emulatorCore?.deltaCore.identifier
        
        if Settings.userInterfaceFeatures.toasts.stateSave
        {
            let text: String
            switch saveState.type
            {
            case .general, .locked: text = NSLocalizedString("Saved State " + saveState.localizedName, comment: "")
            case .quick: text = NSLocalizedString("Quick Saved", comment: "")
            default: text = NSLocalizedString("Saved State ", comment: "")
            }
            
            if saveState.type != .auto, saveState.type != .rewind
            {
                self.presentToastView(text: text)
            }
        }
        
        if isRunning && shouldSuspendEmulation
        {
            self.resumeEmulation()
        }
    }
    
    private func load(_ saveState: SaveStateProtocol)
    {
        let isRunning = (self.emulatorCore?.state == .running)
        
        if isRunning
        {
            self.pauseEmulation()
        }
        
        // If we're loading the auto save state, we need to create a temporary copy of saveState.
        // Then, we update the auto save state, but load our copy so everything works out.
        var temporarySaveState: SaveStateProtocol? = nil
        
        if let autoSaveState = saveState as? SaveState, autoSaveState.type == .auto
        {
            let temporaryURL = FileManager.default.uniqueTemporaryURL()
            
            do
            {
                try FileManager.default.moveItem(at: saveState.fileURL, to: temporaryURL)
                temporarySaveState = DeltaCore.SaveState(fileURL: temporaryURL, gameType: saveState.gameType)
            }
            catch
            {
                print(error)
            }
        }
        
        self.updateAutoSaveState(true)
        
        do
        {
            if let temporarySaveState = temporarySaveState
            {
                try self.emulatorCore?.load(temporarySaveState)
                try FileManager.default.removeItem(at: temporarySaveState.fileURL)
            }
            else
            {
                try self.emulatorCore?.load(saveState)
            }
            
            if Settings.userInterfaceFeatures.toasts.stateLoad,
               !self.overrideToastNotification
            {
                let text: String
                if let state = saveState as? SaveState
                {
                    switch state.type
                    {
                    case .quick: text = NSLocalizedString("Quick Loaded", comment: "")
                    case .rewind: text = NSLocalizedString("Rewound to " + state.localizedName, comment: "")
                    default: text = NSLocalizedString("Loaded State " + state.localizedName, comment: "")
                    }
                    self.presentToastView(text: text)
                }
                else
                {
                    text = NSLocalizedString("Loaded State", comment: "")
                    self.presentToastView(text: text)
                }
                self.overrideToastNotification = false
            }
        }
        catch EmulatorCore.SaveStateError.doesNotExist
        {
            print("Save State does not exist.")
        }
        catch let error as NSError
        {
            print(error)
        }
        
        // delay by 0.5 so as not to interfere with other operations
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            if let rewindSaveState = saveState as? SaveState, rewindSaveState.type == .rewind
            {
                self.clearRewindSaveStates(afterDate: rewindSaveState.creationDate)
            }
            else
            {
                self.clearRewindSaveStates()
            }
        }
        
        if isRunning
        {
            self.resumeEmulation()
        }
    }
    
    //MARK: - SaveStatesViewControllerDelegate
    
    func saveStatesViewController(_ saveStatesViewController: SaveStatesViewController, updateSaveState saveState: SaveState)
    {
        let updatingExistingSaveState = FileManager.default.fileExists(atPath: saveState.fileURL.path)
        
        self.update(saveState)
        
        // Dismiss if updating an existing save state.
        // If creating a new one, don't dismiss.
        if updatingExistingSaveState
        {
            self.pauseViewController?.dismiss()
        }
    }
    
    func saveStatesViewController(_ saveStatesViewController: SaveStatesViewController, loadSaveState saveState: SaveStateProtocol)
    {
        self._isLoadingSaveState = true
        
        self.load(saveState)
        
        self.pauseViewController?.dismiss()
    }
}

//MARK: - Cheats -
/// Cheats
extension GameViewController: CheatsViewControllerDelegate
{
    func cheatsViewController(_ cheatsViewController: CheatsViewController, activateCheat cheat: Cheat)
    {
        if Settings.gameplayFeatures.cheats.isEnabled {
            self.emulatorCore?.activateCheatWithErrorLogging(cheat)
        }
    }
    
    func cheatsViewController(_ cheatsViewController: CheatsViewController, deactivateCheat cheat: Cheat)
    {
        if Settings.gameplayFeatures.cheats.isEnabled {
            self.emulatorCore?.deactivate(cheat)
        }
    }
}

//MARK: - Debug -
/// Debug
private extension GameViewController
{
    func updateDebug()
    {
        self.controllerView?.isDebugModeEnabled = Settings.advancedFeatures.skinDebug.isOn
    }
}

//MARK: - Graphics -
/// Graphics
private extension GameViewController
{
    func updateGraphics()
    {
        self.emulatorCore?.videoManager.renderingAPI = Settings.n64Features.n64graphics.isEnabled ? Settings.n64Features.n64graphics.graphicsAPI.api : EAGLRenderingAPI.openGLES2
    }
    
    func changeGraphicsAPI()
    {
        NotificationCenter.default.post(name: .graphicsRenderingAPIDidChange, object: nil, userInfo: [:])
        
        self.emulatorCore?.gameViews.forEach { $0.inputImage = nil }
        self.game = nil
    }
}

//MARK: - Audio -
/// Audio
private extension GameViewController
{
    func updateAudio()
    {
        self.emulatorCore?.audioManager.respectsSilentMode = Settings.gameplayFeatures.gameAudio.respectSilent
        self.emulatorCore?.audioManager.playWithOtherMedia = Settings.gameplayFeatures.gameAudio.playOver
        self.emulatorCore?.audioManager.audioVolume = Float(Settings.gameplayFeatures.gameAudio.volume)
    }
}

//MARK: - AirPlay Icon -
private extension GameViewController
{
    func updateAirPlayView()
    {
        guard UIApplication.shared.isExternalDisplayConnected,
              !self.isSelectingSustainedButtons,
              !Settings.controllerSkinFeatures.airPlayKeepScreen.isEnabled
        else {
            self.hideAirPlayView()
            return
        }
        
        guard Settings.localControllerPlayerIndex != nil
        else {
            if self.game?.type == .ds
            {
                self.hideAirPlayView()
            }
            else
            {
                self.showAirPlayView()
            }
            return
        }
        
        self.showAirPlayView()
    }
    
    func showAirPlayView()
    {
        self.blurScreenInFront = true
        
        let blurEffect = self.airPlayBlurView.effect
        self.airPlayBlurView.effect = nil
        
        self.airPlayContentView.isHidden = false
        
        UIView.animate(withDuration: 0.4) {
            self.airPlayBlurView.effect = blurEffect
            self.airPlayBackgroundView.alpha = 1.0
        }
    }
    
    func hideAirPlayView()
    {
        let blurEffect = self.airPlayBlurView.effect
        
        UIView.animate(withDuration: 0.4, animations: {
            self.airPlayBlurView.effect = nil
            self.airPlayBackgroundView.alpha = 0.0
        }) { (finished) in
            self.airPlayContentView.isHidden = true
            self.airPlayBlurView.effect = blurEffect
        }
        
        if !self.isSelectingSustainedButtons
        {
            self.blurScreenInFront = false
        }
    }
}

//MARK: - Sustain Buttons -
private extension GameViewController
{
    func showSustainButtonView()
    {
        guard let gameController = self.pausingGameController else { return }
        
        self.blurScreenInFront = true
        
        self.isSelectingSustainedButtons = true
        
        let sustainInputsMapping = SustainInputsMapping(gameController: gameController)
        gameController.addReceiver(self, inputMapping: sustainInputsMapping)
        
        let blurEffect = self.sustainButtonsBlurView.effect
        self.sustainButtonsBlurView.effect = nil
        
        self.sustainButtonsContentView.isHidden = false
        
        UIView.animate(withDuration: 0.4) {
            self.sustainButtonsBlurView.effect = blurEffect
            self.sustainButtonsBackgroundView.alpha = 1.0
        } completion: { _ in
            self.controllerView.becomeFirstResponder()
        }
        
        self.updateAirPlayView()
    }
    
    func hideSustainButtonView()
    {
        guard let gameController = self.pausingGameController else { return }
        
        self.isSelectingSustainedButtons = false
        
        self.updateControllers()
        self.sustainInputsMapping = nil
        
        // Activate all sustained inputs, since they will now be mapped to game inputs.
        for (input, value) in self.inputsToSustain
        {
            gameController.sustain(input, value: value)
        }
        
        let blurEffect = self.sustainButtonsBlurView.effect
        
        UIView.animate(withDuration: 0.4, animations: {
            if UIApplication.shared.isExternalDisplayConnected
            {
                self.airPlayBackgroundView.alpha = 1.0
            }
            self.sustainButtonsBlurView.effect = nil
            self.sustainButtonsBackgroundView.alpha = 0.0
        }) { (finished) in
            self.sustainButtonsContentView.isHidden = true
            self.sustainButtonsBlurView.effect = blurEffect
        }
        
        self.inputsToSustain = [:]
        
        if !UIApplication.shared.isExternalDisplayConnected
        {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                self.blurScreenInFront = false
            }
        }
        
        self.updateAirPlayView()
    }
}

//MARK: - Action Inputs -
/// Action Inputs
extension GameViewController
{
    func performRestartAction()
    {
        let alertController = UIAlertController(title: NSLocalizedString("Restart Game?", comment: ""), message: NSLocalizedString("An autosave will be made for you.", comment: ""), preferredStyle: .alert)
        alertController.addAction(UIAlertAction(title: NSLocalizedString("Restart", comment: ""), style: .destructive, handler: { (action) in
            self.updateAutoSaveState(true)
            self.game = self.game
            self.resumeEmulation()
            if Settings.userInterfaceFeatures.toasts.restart
            {
                self.presentToastView(text: NSLocalizedString("Game Restarted", comment: ""))
            }
        }))
        alertController.addAction(UIAlertAction(title: NSLocalizedString("Cancel", comment: ""), style: .cancel, handler: { (action) in
            self.resumeEmulation()
        }))
        
        if let pauseView = self.pauseViewController
        {
            pauseView.dismiss()
        }
        self.present(alertController, animated: true)
    }
    
    func performStatusBarAction()
    {
        Settings.userInterfaceFeatures.statusBar.isOn = !Settings.userInterfaceFeatures.statusBar.isOn
        
        if let pauseView = self.pauseViewController
        {
            pauseView.dismiss()
        }
        
        self.updateStatusBar()
        
        if Settings.userInterfaceFeatures.toasts.statusBar
        {
            let text: String
            if Settings.userInterfaceFeatures.statusBar.isOn
            {
                text = NSLocalizedString("Status Bar Enabled", comment: "")
            }
            else
            {
                text = NSLocalizedString("Status Bar Disabled", comment: "")
            }
            self.presentToastView(text: text)
        }
    }
    
    func performRotationLockAction()
    {
        if let pauseView = self.pauseViewController
        {
            pauseView.dismiss()
        }
        
        let text: String
        
        if self.isOrientationLocked
        {
            self.isOrientationLocked = false
            self.unlockOrientation()
            text = NSLocalizedString("Rotation Lock Disabled", comment: "")
        }
        else
        {
            self.isOrientationLocked = true
            self.lockOrientation()
            text = NSLocalizedString("Rotation Lock Enabled", comment: "")
        }
        
        if Settings.userInterfaceFeatures.toasts.rotationLock
        {
            self.presentToastView(text: text)
        }
        
        if #available(iOS 16, *)
        {
            self.setNeedsUpdateOfSupportedInterfaceOrientations()
        }
    }
    
    func lockOrientation()
    {
        guard self.lockedOrientation == nil else { return }
        
        switch UIDevice.current.orientation
        {
        case .portrait: self.lockedOrientation = .portrait
        case .landscapeLeft: self.lockedOrientation = .landscapeRight
        case .landscapeRight: self.lockedOrientation = .landscapeLeft
        case .portraitUpsideDown: self.lockedOrientation = .portraitUpsideDown
        default: self.lockedOrientation = .portrait
        }
    }
    
    func unlockOrientation()
    {
        guard !self.isOrientationLocked else { return }
        
        self.lockedOrientation = nil
    }
    
    func performScreenshotAction()
    {
        if let pauseView = self.pauseViewController
        {
            pauseView.dismiss()
        }
        
        if Settings.gameplayFeatures.screenshots.playCountdown
        {
            self.presentToastView(text: "3", duration: 1)
            
            DispatchQueue.main.asyncAfter(deadline: .now() + 1)
            {
                self.presentToastView(text: "2", duration: 1)
            }
            
            DispatchQueue.main.asyncAfter(deadline: .now() + 2)
            {
                self.presentToastView(text: "1", duration: 1)
            }
        }
        
        DispatchQueue.main.asyncAfter(deadline: .now() + (Settings.gameplayFeatures.screenshots.playCountdown ? 3 : 0))
        {
            guard let snapshot = self.emulatorCore?.videoManager.snapshot() else { return }

            let imageScale = Settings.gameplayFeatures.screenshots.size?.rawValue ?? 1.0
            let imageSize = CGSize(width: snapshot.size.width * imageScale, height: snapshot.size.height * imageScale)
            
            let screenshotData: Data
            if imageScale == 1, let data = snapshot.pngData()
            {
                screenshotData = data
            }
            else
            {
                let format = UIGraphicsImageRendererFormat()
                format.scale = 1
                
                let renderer = UIGraphicsImageRenderer(size: imageSize, format: format)
                screenshotData = renderer.pngData { (context) in
                    context.cgContext.interpolationQuality = .none
                    snapshot.draw(in: CGRect(origin: .zero, size: imageSize))
                }
            }
            
            if Settings.gameplayFeatures.screenshots.saveToPhotos
            {
                PHPhotoLibrary.runIfAuthorized
                {
                    PHPhotoLibrary.saveImageData(screenshotData)
                }
            }
            
            if Settings.gameplayFeatures.screenshots.saveToFiles
            {
                let screenshotsDirectory = FileManager.default.documentsDirectory.appendingPathComponent("Screenshots")
                
                do
                {
                    try FileManager.default.createDirectory(at: screenshotsDirectory, withIntermediateDirectories: true, attributes: nil)
                }
                catch
                {
                    print(error)
                }
                
                let date = Date()
                let dateFormatter = DateFormatter()
                dateFormatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
                
                let fileName: URL
                if let game = self.game as? Game
                {
                    let filename = game.name + "_" + dateFormatter.string(from: date) + ".png"
                    fileName = screenshotsDirectory.appendingPathComponent(filename)
                }
                else
                {
                    fileName = screenshotsDirectory.appendingPathComponent(dateFormatter.string(from: date) + ".png")
                }
                
                do
                {
                    try screenshotData.write(to: fileName)
                }
                catch
                {
                    print(error)
                }
            }
            
            if Settings.userInterfaceFeatures.toasts.screenshot
            {
                self.presentToastView(text: NSLocalizedString("Screenshot Captured", comment: ""))
            }
        }
    }
    
    func performQuickSaveAction()
    {
        guard let game = self.game as? Game else { return }
        
        let backgroundContext = DatabaseManager.shared.newBackgroundContext()
        backgroundContext.performAndWait {
            
            let game = backgroundContext.object(with: game.objectID) as! Game
            let fetchRequest = SaveState.fetchRequest(for: game, type: .quick)
            
            do
            {
                if let quickSaveState = try fetchRequest.execute().first
                {
                    self.update(quickSaveState)
                }
                else
                {
                    let saveState = SaveState(context: backgroundContext)
                    saveState.type = .quick
                    saveState.game = game
                    
                    self.update(saveState)
                }
            }
            catch
            {
                print(error)
            }
            
            backgroundContext.saveWithErrorLogging()
        }
    }
    
    func performQuickLoadAction()
    {
        guard let game = self.game as? Game else { return }
        
        let fetchRequest = SaveState.fetchRequest(for: game, type: .quick)
        
        do
        {
            if let quickSaveState = try DatabaseManager.shared.viewContext.fetch(fetchRequest).first
            {
                self.load(quickSaveState)
            }
        }
        catch
        {
            print(error)
        }
    }
    
    func performFastForwardAction(activate: Bool)
    {
        guard let emulatorCore = self.emulatorCore else { return }
        let text: String
        
        if activate
        {
            if Settings.gameplayFeatures.fastForward.prompt,
               Settings.gameplayFeatures.fastForward.toggle
            {
                if let pauseView = self.pauseViewController
                {
                    pauseView.dismiss()
                }
                
                self.promptFastForwardSpeed()
            }
            else
            {
                if Settings.gameplayFeatures.fastForward.isEnabled
                {
                    emulatorCore.rate = Settings.gameplayFeatures.fastForward.speed
                }
                else
                {
                    emulatorCore.rate = emulatorCore.deltaCore.supportedRates.upperBound
                }
                
                if Settings.userInterfaceFeatures.toasts.fastForward,
                   Settings.gameplayFeatures.fastForward.toggle
                {
                    text = NSLocalizedString("Fast Forward Enabled at " + String(format: "%.f", emulatorCore.rate * 100) + "%", comment: "")
                    self.presentToastView(text: text)
                }
            }
        }
        else
        {
            emulatorCore.rate = emulatorCore.deltaCore.supportedRates.lowerBound
            
            if Settings.userInterfaceFeatures.toasts.fastForward,
               Settings.gameplayFeatures.fastForward.toggle
            {
                text = NSLocalizedString("Fast Forward Disabled", comment: "")
                self.presentToastView(text: text)
            }
        }
    }
    
    func promptFastForwardSpeed()
    {
        let alertController = UIAlertController(title: nil, message: nil, preferredStyle: .actionSheet)
        alertController.popoverPresentationController?.sourceView = self.view
        alertController.popoverPresentationController?.sourceRect = CGRect(x: self.view.bounds.midX, y: self.view.bounds.maxY, width: 0, height: 0)
        alertController.popoverPresentationController?.permittedArrowDirections = []
        
        if Settings.gameplayFeatures.fastForward.slowmo {
            alertController.addAction(UIAlertAction(title: "25%", style: .default, handler: { (action) in
                self.setFastForwardSpeed(speed: 0.25)
            }))
            alertController.addAction(UIAlertAction(title: "50%", style: .default, handler: { (action) in
                self.setFastForwardSpeed(speed: 0.5)
            }))
        }
        alertController.addAction(UIAlertAction(title: "150%", style: .default, handler: { (action) in
            self.setFastForwardSpeed(speed: 1.5)
        }))
        alertController.addAction(UIAlertAction(title: "200%", style: .default, handler: { (action) in
            self.setFastForwardSpeed(speed: 2.0)
        }))
        alertController.addAction(UIAlertAction(title: "300%", style: .default, handler: { (action) in
            self.setFastForwardSpeed(speed: 3.0)
        }))
        alertController.addAction(UIAlertAction(title: "400%", style: .default, handler: { (action) in
            self.setFastForwardSpeed(speed: 4.0)
        }))
        if Settings.gameplayFeatures.fastForward.unsafe {
            alertController.addAction(UIAlertAction(title: "800%", style: .default, handler: { (action) in
                self.setFastForwardSpeed(speed: 8.0)
            }))
            alertController.addAction(UIAlertAction(title: "1600%", style: .default, handler: { (action) in
                self.setFastForwardSpeed(speed: 16.0)
            }))
        }
        alertController.addAction(UIAlertAction(title: "Custom: " + String(format: "%.f", Settings.gameplayFeatures.fastForward.speed * 100) + "%", style: .default, handler: { (action) in
            self.setFastForwardSpeed(speed: 4.0)
        }))
        alertController.addAction(UIAlertAction(title: "Cancel", style: .cancel, handler: { (action) in
            self.setFastForwardSpeed()
        }))
        
        self.present(alertController, animated: true, completion: nil)
    }
    
    func setFastForwardSpeed(speed: Double = 0)
    {
        if speed != 0
        {
            guard let emulatorCore = self.emulatorCore else { return }
            
            emulatorCore.rate = speed
            if Settings.userInterfaceFeatures.toasts.fastForward
            {
                let text = NSLocalizedString("Fast Forward Enabled at " + String(format: "%.f", speed * 100) + "%", comment: "")
                self.presentToastView(text: text)
            }
        }
        self.resumeEmulation()
    }
    
    func performQuickSettingsAction()
    {
        if self.isSelectingSustainedButtons
        {
            if self.presentedViewController == nil
            {
                self.pauseEmulation()
                self.controllerView.resignFirstResponder()
                self._isQuickSettingsOpen = false
                
                self.performSegue(withIdentifier: "pause", sender: self.controllerView)
            }
            
            self.hideSustainButtonView()
        }
        else
        {
            guard Settings.gameplayFeatures.quickSettings.isEnabled else { return }
            
            if self._isQuickSettingsOpen
            {
                self._isQuickSettingsOpen = false
                
                self.dismissQuickSettings()
            }
            else
            {
                if let pauseView = self.pauseViewController
                {
                    pauseView.dismiss()
                }
                
                guard #available(iOS 15.0, *) else {
                    self.presentToastView(text: "Quick Menu Requires iOS 15")
                    return
                }
                
                if let speed = self.emulatorCore?.rate,
                   let system = self.game?.type.rawValue
                {
                    let quickSettingsView = QuickSettingsView.makeViewController(system: system, speed: speed)
                    if let sheet = quickSettingsView.sheetPresentationController {
                        sheet.detents = [.medium(), .large()]
                        sheet.largestUndimmedDetentIdentifier = nil
                        sheet.prefersScrollingExpandsWhenScrolledToEdge = true
                        sheet.prefersEdgeAttachedInCompactHeight = true
                        sheet.widthFollowsPreferredContentSizeWhenEdgeAttached = false
                        sheet.prefersGrabberVisible = true
                    }
                    
                    self.present(quickSettingsView, animated: true, completion: nil)
                }
                
                self._isQuickSettingsOpen = true
                
                self.resumeEmulation()
            }
        }
    }
    
    func dismissQuickSettings()
    {
        if #available(iOS 15.0, *),
           let presentedViewController = self.sheetPresentationController
        {
            presentedViewController.presentedViewController.dismiss(animated: true)
        }
    }
    
    func performPauseAction()
    {
        self.dismissQuickSettings()
        self.pauseEmulation()
        self.controllerView.resignFirstResponder()
        self._isQuickSettingsOpen = false
        
        self.performSegue(withIdentifier: "pause", sender: self.controllerView)
    }
    
    func performMainMenuAction()
    {
        self.dismissQuickSettings()
        self.pauseEmulation()
        self.controllerView.resignFirstResponder()
        self._isQuickSettingsOpen = false
        
        DispatchQueue.main.async {
            self.transitionCoordinator?.animate(alongsideTransition: nil, completion: { (context) in
                self.performSegue(withIdentifier: "showGamesViewController", sender: nil)
            })
        }
    }
    
    func performBlurBackgroundAction()
    {
        let enabled = !Settings.controllerSkinFeatures.backgroundBlur.blurBackground
        self.blurScreenEnabled = enabled
        Settings.controllerSkinFeatures.backgroundBlur.blurBackground = enabled
        
        if let pauseView = self.pauseViewController
        {
            pauseView.dismiss()
        }
        
        if Settings.userInterfaceFeatures.toasts.backgroundBlur
        {
            let text: String
            if enabled
            {
                text = NSLocalizedString("Background Blur Enabled", comment: "")
            }
            else
            {
                text = NSLocalizedString("Background Blur Disabled", comment: "")
            }
            self.presentToastView(text: text)
        }
    }
    
    func performAltRepresentationsAction()
    {
        let enabled = !Settings.advancedFeatures.skinDebug.useAlt
        self.controllerView.isAltRepresentationsEnabled = enabled
        Settings.advancedFeatures.skinDebug.useAlt = enabled
        
        if let pauseView = self.pauseViewController
        {
            pauseView.dismiss()
        }
        
        if Settings.userInterfaceFeatures.toasts.altSkin
        {
            let text: String
            if enabled
            {
                text = NSLocalizedString("Alternate Skin Enabled", comment: "")
            }
            else
            {
                text = NSLocalizedString("Alternate Skin Disabled", comment: "")
            }
            self.presentToastView(text: text)
        }
    }
    
    func performDebugModeAction()
    {
        let enabled = !Settings.advancedFeatures.skinDebug.isOn
        Settings.advancedFeatures.skinDebug.isOn = enabled
        self.controllerView.isDebugModeEnabled = enabled
        
        if let pauseView = self.pauseViewController
        {
            pauseView.dismiss()
        }
        
        if Settings.userInterfaceFeatures.toasts.debug
        {
            let text: String
            if enabled
            {
                text = NSLocalizedString("Debug Mode Enabled", comment: "")
            }
            else
            {
                text = NSLocalizedString("Debug Mode Disabled", comment: "")
            }
            self.presentToastView(text: text)
        }
    }
    
    func performDebugDeviceAction()
    {
        if let pauseView = self.pauseViewController
        {
            pauseView.dismiss()
        }
        
        let alertController = UIAlertController(title: NSLocalizedString("Choose Device Override", comment: ""), message: NSLocalizedString("This allows you to test your skins on devices that you don't have access to.", comment: ""), preferredStyle: .actionSheet)
        alertController.popoverPresentationController?.sourceView = self.view
        alertController.popoverPresentationController?.sourceRect = CGRect(x: self.view.bounds.midX, y: self.view.bounds.maxY, width: 0, height: 0)
        alertController.popoverPresentationController?.permittedArrowDirections = []
        
        alertController.addAction(UIAlertAction(title: "iPhone", style: .default, handler: { (action) in
            Settings.advancedFeatures.skinDebug.device = .iphone
            self.resumeEmulation()
            if Settings.userInterfaceFeatures.toasts.debug
            {
                self.presentToastView(text: NSLocalizedString("Device Override set to iPhone", comment: ""))
            }
        }))
        alertController.addAction(UIAlertAction(title: "iPad", style: .default, handler: { (action) in
            Settings.advancedFeatures.skinDebug.device = .ipad
            self.resumeEmulation()
            if Settings.userInterfaceFeatures.toasts.debug
            {
                self.presentToastView(text: NSLocalizedString("Device Override set to iPad", comment: ""))
            }
        }))
        alertController.addAction(UIAlertAction(title: "AirPlay TV", style: .default, handler: { (action) in
            Settings.advancedFeatures.skinDebug.device = .tv
            self.resumeEmulation()
            if Settings.userInterfaceFeatures.toasts.debug
            {
                self.presentToastView(text: NSLocalizedString("Device Override set to AirPlay TV", comment: ""))
            }
        }))
        alertController.addAction(UIAlertAction(title: "Reset Device", style: .default, handler: { (action) in
            Settings.advancedFeatures.skinDebug.device = Settings.advancedFeatures.skinDebug.defaultDevice
            self.resumeEmulation()
            if Settings.userInterfaceFeatures.toasts.debug
            {
                self.presentToastView(text: NSLocalizedString("Device Override has been reset", comment: ""))
            }
        }))
        alertController.addAction(UIAlertAction(title: "Cancel", style: .cancel, handler: { (action) in
            self.resumeEmulation()
        }))
        self.present(alertController, animated: true, completion: nil)
    }
    
    func performDebugDisplayTypeAction()
    {
        if let pauseView = self.pauseViewController
        {
            pauseView.dismiss()
        }
        
        let alertController = UIAlertController(title: NSLocalizedString("Choose Display Type Override", comment: ""), message: NSLocalizedString("This allows you to test your skins on display types that you don't have access to.", comment: ""), preferredStyle: .actionSheet)
        alertController.popoverPresentationController?.sourceView = self.view
        alertController.popoverPresentationController?.sourceRect = CGRect(x: self.view.bounds.midX, y: self.view.bounds.maxY, width: 0, height: 0)
        alertController.popoverPresentationController?.permittedArrowDirections = []
        
        alertController.addAction(UIAlertAction(title: "Standard", style: .default, handler: { (action) in
            Settings.advancedFeatures.skinDebug.displayType = .standard
            self.resumeEmulation()
            if Settings.userInterfaceFeatures.toasts.debug
            {
                self.presentToastView(text: NSLocalizedString("Display Type Override set to Standard", comment: ""))
            }
        }))
        alertController.addAction(UIAlertAction(title: "EdgeToEdge", style: .default, handler: { (action) in
            Settings.advancedFeatures.skinDebug.displayType = .edgeToEdge
            self.resumeEmulation()
            if Settings.userInterfaceFeatures.toasts.debug
            {
                self.presentToastView(text: NSLocalizedString("Display Type Override set to EdgeToEdge", comment: ""))
            }
        }))
        alertController.addAction(UIAlertAction(title: "SplitView", style: .default, handler: { (action) in
            Settings.advancedFeatures.skinDebug.displayType = .splitView
            self.resumeEmulation()
            if Settings.userInterfaceFeatures.toasts.debug
            {
                self.presentToastView(text: NSLocalizedString("Display Type Override set to SplitView", comment: ""))
            }
        }))
        alertController.addAction(UIAlertAction(title: "Reset Device", style: .default, handler: { (action) in
            Settings.advancedFeatures.skinDebug.displayType = Settings.advancedFeatures.skinDebug.defaultDisplayType
            self.resumeEmulation()
            if Settings.userInterfaceFeatures.toasts.debug
            {
                self.presentToastView(text: NSLocalizedString("Display Type Override has been reset", comment: ""))
            }
        }))
        alertController.addAction(UIAlertAction(title: "Cancel", style: .cancel, handler: { (action) in
            self.resumeEmulation()
        }))
        self.present(alertController, animated: true, completion: nil)
    }
    
    func performPresetTraitsAction()
    {
        if let pauseView = self.pauseViewController
        {
            pauseView.dismiss()
        }
        
        let alertController = UIAlertController(title: NSLocalizedString("Choose Preset Traits", comment: ""), message: NSLocalizedString("Set your override traits based on existing device and display type combinations.", comment: ""), preferredStyle: .actionSheet)
        alertController.popoverPresentationController?.sourceView = self.view
        alertController.popoverPresentationController?.sourceRect = CGRect(x: self.view.bounds.midX, y: self.view.bounds.maxY, width: 0, height: 0)
        alertController.popoverPresentationController?.permittedArrowDirections = []
        
        alertController.addAction(UIAlertAction(title: "Standard iPhone", style: .default, handler: { (action) in
            Settings.advancedFeatures.skinDebug.device = .iphone
            Settings.advancedFeatures.skinDebug.displayType = .standard
            self.resumeEmulation()
            if Settings.userInterfaceFeatures.toasts.debug
            {
                self.presentToastView(text: NSLocalizedString("Override Traits set to Standard iPhone", comment: ""))
            }
        }))
        alertController.addAction(UIAlertAction(title: "EdgeToEdge iPhone", style: .default, handler: { (action) in
            Settings.advancedFeatures.skinDebug.device = .iphone
            Settings.advancedFeatures.skinDebug.displayType = .edgeToEdge
            self.resumeEmulation()
            if Settings.userInterfaceFeatures.toasts.debug
            {
                self.presentToastView(text: NSLocalizedString("Override Traits set to EdgeToEdge iPhone", comment: ""))
            }
        }))
        alertController.addAction(UIAlertAction(title: "Standard iPad", style: .default, handler: { (action) in
            Settings.advancedFeatures.skinDebug.device = .ipad
            Settings.advancedFeatures.skinDebug.displayType = .standard
            self.resumeEmulation()
            if Settings.userInterfaceFeatures.toasts.debug
            {
                self.presentToastView(text: NSLocalizedString("Override Traits set to Standard iPad", comment: ""))
            }
        }))
        alertController.addAction(UIAlertAction(title: "SplitView iPad", style: .default, handler: { (action) in
            Settings.advancedFeatures.skinDebug.device = .ipad
            Settings.advancedFeatures.skinDebug.displayType = .splitView
            self.resumeEmulation()
            if Settings.userInterfaceFeatures.toasts.debug
            {
                self.presentToastView(text: NSLocalizedString("Override Traits set to SplitView iPad", comment: ""))
            }
        }))
        alertController.addAction(UIAlertAction(title: "AirPlay TV", style: .default, handler: { (action) in
            Settings.advancedFeatures.skinDebug.device = .tv
            Settings.advancedFeatures.skinDebug.displayType = .standard
            self.resumeEmulation()
            if Settings.userInterfaceFeatures.toasts.debug
            {
                self.presentToastView(text: NSLocalizedString("Override Traits set to AirPlay TV", comment: ""))
            }
        }))
        alertController.addAction(UIAlertAction(title: "Cancel", style: .cancel, handler: { (action) in
            self.resumeEmulation()
        }))
        self.present(alertController, animated: true, completion: nil)
    }
    
    func performPaletteAction()
    {
        if let pauseView = self.pauseViewController
        {
            pauseView.dismiss()
        }
        
        if Settings.gbcFeatures.palettes.multiPalette
        {
            let alertController = UIAlertController(title: NSLocalizedString("Change Which Palette?", comment: ""), message: nil, preferredStyle: .actionSheet)
            alertController.popoverPresentationController?.sourceView = self.view
            alertController.popoverPresentationController?.sourceRect = CGRect(x: self.view.bounds.midX, y: self.view.bounds.maxY, width: 0, height: 0)
            alertController.popoverPresentationController?.permittedArrowDirections = []
            
            alertController.addAction(UIAlertAction(title: "Main Palette", style: .default, handler: { (action) in
                let paletteAlertController = UIAlertController(title: NSLocalizedString("Choose Main Palette", comment: ""), message: nil, preferredStyle: .actionSheet)
                paletteAlertController.popoverPresentationController?.sourceView = self.view
                paletteAlertController.popoverPresentationController?.sourceRect = CGRect(x: self.view.bounds.midX, y: self.view.bounds.maxY, width: 0, height: 0)
                paletteAlertController.popoverPresentationController?.permittedArrowDirections = []
                
                for palette in GameboyPalette.allCases
                {
                    let text = (Settings.gbcFeatures.palettes.palette.rawValue == palette.rawValue) ? ("✓ " + palette.description) : palette.description
                    paletteAlertController.addAction(UIAlertAction(title: text, style: .default, handler: { (action) in
                        Settings.gbcFeatures.palettes.palette = palette
                        self.resumeEmulation()
                        if Settings.userInterfaceFeatures.toasts.palette
                        {
                            self.presentToastView(text: NSLocalizedString("Changed Main Palette to \(palette.description)", comment: ""))
                        }
                    }))
                }
                
                paletteAlertController.addAction(.cancel)
                self.present(paletteAlertController, animated: true, completion: nil)
            }))
            alertController.addAction(UIAlertAction(title: "Sprite Palette 1", style: .default, handler: { (action) in
                let paletteAlertController = UIAlertController(title: NSLocalizedString("Choose Sprite Palette 1", comment: ""), message: nil, preferredStyle: .actionSheet)
                paletteAlertController.popoverPresentationController?.sourceView = self.view
                paletteAlertController.popoverPresentationController?.sourceRect = CGRect(x: self.view.bounds.midX, y: self.view.bounds.maxY, width: 0, height: 0)
                paletteAlertController.popoverPresentationController?.permittedArrowDirections = []
                
                for palette in GameboyPalette.allCases
                {
                    let text = (Settings.gbcFeatures.palettes.spritePalette1.rawValue == palette.rawValue) ? ("✓ " + palette.description) : palette.description
                    paletteAlertController.addAction(UIAlertAction(title: text, style: .default, handler: { (action) in
                        Settings.gbcFeatures.palettes.spritePalette1 = palette
                        self.resumeEmulation()
                        if Settings.userInterfaceFeatures.toasts.palette
                        {
                            self.presentToastView(text: NSLocalizedString("Changed Sprite Palette 1 to \(palette.description)", comment: ""))
                        }
                    }))
                }
                
                paletteAlertController.addAction(.cancel)
                self.present(paletteAlertController, animated: true, completion: nil)
            }))
            alertController.addAction(UIAlertAction(title: "Sprite Palette 2", style: .default, handler: { (action) in
                let paletteAlertController = UIAlertController(title: NSLocalizedString("Choose Sprite Palette 2", comment: ""), message: nil, preferredStyle: .actionSheet)
                paletteAlertController.popoverPresentationController?.sourceView = self.view
                paletteAlertController.popoverPresentationController?.sourceRect = CGRect(x: self.view.bounds.midX, y: self.view.bounds.maxY, width: 0, height: 0)
                paletteAlertController.popoverPresentationController?.permittedArrowDirections = []
                
                for palette in GameboyPalette.allCases
                {
                    let text = (Settings.gbcFeatures.palettes.spritePalette2.rawValue == palette.rawValue) ? ("✓ " + palette.description) : palette.description
                    paletteAlertController.addAction(UIAlertAction(title: text, style: .default, handler: { (action) in
                        Settings.gbcFeatures.palettes.spritePalette2 = palette
                        self.resumeEmulation()
                        if Settings.userInterfaceFeatures.toasts.palette
                        {
                            self.presentToastView(text: NSLocalizedString("Changed Sprite Palette 2 to \(palette.description)", comment: ""))
                        }
                    }))
                }
                
                paletteAlertController.addAction(UIAlertAction(title: "Cancel", style: .cancel, handler: { (action) in
                    self.resumeEmulation()
                }))
                self.present(paletteAlertController, animated: true, completion: nil)
            }))
            
            alertController.addAction(UIAlertAction(title: "Cancel", style: .cancel, handler: { (action) in
                self.resumeEmulation()
            }))
            self.present(alertController, animated: true, completion: nil)
        }
        else
        {
            let alertController = UIAlertController(title: NSLocalizedString("Choose Color Palette", comment: ""), message: nil, preferredStyle: .actionSheet)
            alertController.popoverPresentationController?.sourceView = self.view
            alertController.popoverPresentationController?.sourceRect = CGRect(x: self.view.bounds.midX, y: self.view.bounds.maxY, width: 0, height: 0)
            alertController.popoverPresentationController?.permittedArrowDirections = []
            
            for palette in GameboyPalette.allCases
            {
                let text = (Settings.gbcFeatures.palettes.palette.rawValue == palette.rawValue) ? ("✓ " + palette.description) : palette.description
                alertController.addAction(UIAlertAction(title: text, style: .default, handler: { (action) in
                    Settings.gbcFeatures.palettes.palette = palette
                    self.resumeEmulation()
                    if Settings.userInterfaceFeatures.toasts.palette
                    {
                        self.presentToastView(text: NSLocalizedString("Changed Palette to \(palette.description)", comment: ""))
                    }
                }))
            }
            
            alertController.addAction(UIAlertAction(title: "Cancel", style: .cancel, handler: { (action) in
                self.resumeEmulation()
            }))
            self.present(alertController, animated: true, completion: nil)
        }
    }
}

//MARK: - Toast Notifications -
/// Toast Notifications
extension GameViewController
{
    func presentToastView(text: String, duration: Double? = nil)
    {
        guard Settings.userInterfaceFeatures.toasts.isEnabled else { return }
        
        DispatchQueue.main.async {
            let toastView = RSTToastView(text: text, detailText: nil)
            toastView.edgeOffset.vertical = 8
            self.show(toastView, duration: duration ?? Settings.userInterfaceFeatures.toasts.duration)
        }
    }
}

private extension GameViewController
{
    func connectExternalDisplay(for scene: ExternalDisplayScene)
    {
        // We need to receive gameViewController(_:didUpdateGameViews) callback.
        scene.gameViewController.delegate = self
        
        self.updateControllerSkin()
        
        self.updateAirPlayView()

        // Implicitly called from updateControllerSkin()
        // self.updateExternalDisplay()
    }

    func updateExternalDisplay()
    {
        guard let scene = UIApplication.shared.externalDisplayScene else { return }

        if scene.game?.fileURL != self.game?.fileURL
        {
            scene.game = self.game
        }

        var controllerSkin: ControllerSkinProtocol?

        if let game = self.game, let traits = scene.gameViewController.controllerView.controllerSkinTraits
        {
            if Settings.controllerSkinFeatures.airPlaySkins.isEnabled,
               let preferredControllerSkin = Settings.controllerSkinFeatures.airPlaySkins.preferredAirPlayControllerSkin(for: game.type), preferredControllerSkin.supports(traits, alt: Settings.advancedFeatures.skinDebug.useAlt)
            {
                // Use preferredControllerSkin directly.
                controllerSkin = preferredControllerSkin
            }
            else if let standardSkin = DeltaCore.ControllerSkin.standardControllerSkin(for: game.type),
                    standardSkin.supports(traits)
            {
                if standardSkin.hasTouchScreen(for: traits)
                {
                    // Only use TouchControllerSkin for standard controller skins with touch screens.
                             
                    var touchControllerSkin = DeltaCore.TouchControllerSkin(controllerSkin: standardSkin)
                    touchControllerSkin.screenLayoutAxis = Settings.dsFeatures.dsAirPlay.layoutAxis

                    if Settings.dsFeatures.dsAirPlay.topScreenOnly
                    {
                        touchControllerSkin.screenPredicate = { !$0.isTouchScreen }
                    }

                    controllerSkin = touchControllerSkin
                }
                else
                {
                    controllerSkin = standardSkin
                }
            }
        }

        scene.gameViewController.controllerView.controllerSkin = controllerSkin

        // Implicitly called when assigning controllerSkin.
        // self.updateExternalDisplayGameViews()
    }

    func updateExternalDisplayGameViews()
    {
        guard let scene = UIApplication.shared.externalDisplayScene, let emulatorCore = self.emulatorCore else { return }

        for gameView in scene.gameViewController.gameViews
        {
            emulatorCore.add(gameView)
        }
    }

    func disconnectExternalDisplay(for scene: ExternalDisplayScene)
    {
        scene.gameViewController.delegate = nil
        
        for gameView in scene.gameViewController.gameViews
        {
            self.emulatorCore?.remove(gameView)
        }

        self.updateControllerSkin() // Reset TouchControllerSkin + GameViews
        
        self.updateAirPlayView()
    }
}

//MARK: - GameViewControllerDelegate -
/// GameViewControllerDelegate
extension GameViewController: GameViewControllerDelegate
{
    func gameViewController(_ gameViewController: DeltaCore.GameViewController, handleMenuInputFrom gameController: GameController)
    {
        guard gameViewController == self else { return }
        
        if let pausingGameController = self.pausingGameController
        {
            guard pausingGameController == gameController else { return }
        }
        
        if let pauseViewController = self.pauseViewController, !self.isSelectingSustainedButtons
        {
            pauseViewController.dismiss()
        }
        else if self.presentedViewController == nil
        {
            self.pauseEmulation()
            self.controllerView.resignFirstResponder()
            self._isQuickSettingsOpen = false
            
            self.performSegue(withIdentifier: "pause", sender: gameController)
        }
        
        if self.isSelectingSustainedButtons
        {
            self.hideSustainButtonView()
        }
    }
    
    func gameViewControllerShouldResumeEmulation(_ gameViewController: DeltaCore.GameViewController) -> Bool
    {
        guard gameViewController == self else { return false }
        
        var result = false
        
        rst_dispatch_sync_on_main_thread {
            result = (self.presentedViewController == nil || self.presentedViewController?.isDisappearing == true) && !self.isSelectingSustainedButtons && self.view.window != nil
        }
        
        return result
    }
    
    func gameViewController(_ gameViewController: DeltaCore.GameViewController, didUpdateGameViews gameViews: [GameView])
    {
        // gameViewController could be `self` or ExternalDisplayScene.gameViewController.
             
        if gameViewController == self
        {
            self.updateGameViews()
        }
        else
        {
            self.updateExternalDisplayGameViews()
        }
    }
}

private extension GameViewController
{
    func show(_ toastView: RSTToastView, duration: TimeInterval = 3.0)
    {
        toastView.textLabel.textAlignment = .center
        toastView.presentationEdge = .top
        toastView.show(in: self.view, duration: duration)
    }
    
    func showJITEnabledAlert()
    {
        guard !self.presentedJITAlert, self.presentedViewController == nil, self.game != nil else { return }
        self.presentedJITAlert = true
        
        func presentToastView()
        {
            let detailText: String?
            let duration: TimeInterval
            
            if UserDefaults.standard.jitEnabledAlertCount < 3
            {
                detailText = NSLocalizedString("You can now Fast Forward DS games up to 3x speed.", comment: "")
                duration = 5.0
            }
            else
            {
                detailText = nil
                duration = 2.0
            }
            
            let toastView = RSTToastView(text: NSLocalizedString("JIT Compilation Enabled", comment: ""), detailText: detailText)
            toastView.edgeOffset.vertical = 8
            self.show(toastView, duration: duration)
            
            UserDefaults.standard.jitEnabledAlertCount += 1
        }
        
        DispatchQueue.main.async {
            if let transitionCoordinator = self.transitionCoordinator
            {
                transitionCoordinator.animate(alongsideTransition: nil) { (context) in
                    presentToastView()
                }
            }
            else
            {
                presentToastView()
            }
        }
    }
}

//MARK: - Notifications -
private extension GameViewController
{
    @objc func didEnterBackground(with notification: Notification)
    {
        self.updateAutoSaveState()
    }
    
    @objc func didBecomeActiveApp(with notification: Notification)
    {
        guard let scene = notification.object as? UIWindowScene, scene == self.view.window?.windowScene else { return }
                        
        if #available(iOS 15.0, *),
           let presentedViewController = self.sheetPresentationController,
           self._isQuickSettingsOpen
        {
            presentedViewController.presentedViewController.dismiss(animated: true)
        }
        
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            self.resumeEmulation()
        }
    }
    
    @objc func managedObjectContextDidChange(with notification: Notification)
    {
        guard let deletedObjects = notification.userInfo?[NSDeletedObjectsKey] as? Set<NSManagedObject> else { return }
        guard let game = self.game as? Game else { return }
        
        if deletedObjects.contains(game)
        {
            self.emulatorCore?.gameViews.forEach { $0.inputImage = nil }
            self.game = nil
        }
    }
    
    @objc func settingsDidChange(with notification: Notification)
    {
        guard let settingsName = notification.userInfo?[Settings.NotificationUserInfoKey.name] as? Settings.Name else { return }
        
        switch settingsName
        {
        case .localControllerPlayerIndex, Settings.touchFeedbackFeatures.touchVibration.$buttonsEnabled.settingsKey, Settings.touchFeedbackFeatures.touchVibration.$sticksEnabled.settingsKey, Settings.advancedFeatures.skinDebug.$useAlt.settingsKey, Settings.controllerSkinFeatures.skinCustomization.$alwaysShow.settingsKey, Settings.controllerSkinFeatures.airPlayKeepScreen.settingsKey, Settings.controllerSkinFeatures.controller.settingsKey, Settings.advancedFeatures.skinDebug.$isOn.settingsKey, Settings.advancedFeatures.skinDebug.$device.settingsKey, Settings.advancedFeatures.skinDebug.$displayType.settingsKey, Settings.advancedFeatures.skinDebug.$traitOverride.settingsKey, Settings.touchFeedbackFeatures.touchVibration.$releaseEnabled.settingsKey, Settings.touchFeedbackFeatures.touchOverlay.settingsKey:
            self.updateControllers()

        case .preferredControllerSkin:
            guard
                let system = notification.userInfo?[Settings.NotificationUserInfoKey.system] as? System,
                let traits = notification.userInfo?[Settings.NotificationUserInfoKey.traits] as? DeltaCore.ControllerSkin.Traits
            else { return }
                        
            if system.gameType == self.game?.type && traits.orientation == self.controllerView.controllerSkinTraits?.orientation
            {
                self.updateControllerSkin()
            }
            
        case Settings.controllerSkinFeatures.controller.$triggerDeadzone.settingsKey:
            self.updateControllerTriggerDeadzone()
            
        case Settings.controllerSkinFeatures.skinCustomization.settingsKey, Settings.controllerSkinFeatures.skinCustomization.$opacity.settingsKey, Settings.controllerSkinFeatures.skinCustomization.$backgroundColor.settingsKey, Settings.controllerSkinFeatures.skinCustomization.$matchTheme.settingsKey:
            self.updateControllerSkinCustomization()
            
        case Settings.touchFeedbackFeatures.touchVibration.$strength.settingsKey:
            self.controllerView.hapticFeedbackStrength = Settings.touchFeedbackFeatures.touchVibration.strength
            
        case Settings.touchFeedbackFeatures.touchOverlay.$overlayColor.settingsKey:
            self.controllerView.touchOverlayColor = Settings.touchFeedbackFeatures.touchOverlay.themed ? UIColor.themeColor : UIColor(Settings.touchFeedbackFeatures.touchOverlay.overlayColor)
            
        case Settings.touchFeedbackFeatures.touchOverlay.$opacity.settingsKey:
            self.controllerView.touchOverlayOpacity = Settings.touchFeedbackFeatures.touchOverlay.opacity
            
        case Settings.touchFeedbackFeatures.touchOverlay.$size.settingsKey:
            self.controllerView.touchOverlaySize = Settings.touchFeedbackFeatures.touchOverlay.size
            
        case Settings.touchFeedbackFeatures.touchOverlay.$style.settingsKey:
            self.controllerView.touchOverlayStyle = Settings.touchFeedbackFeatures.touchOverlay.style
            
        case Settings.gameplayFeatures.gameAudio.$respectSilent.settingsKey, Settings.gameplayFeatures.gameAudio.$playOver.settingsKey, Settings.gameplayFeatures.gameAudio.$volume.settingsKey:
            self.updateAudio()
            
        case Settings.n64Features.n64graphics.$graphicsAPI.settingsKey:
            self.changeGraphicsAPI()
            
        case Settings.touchFeedbackFeatures.touchAudio.$sound.settingsKey:
            self.updateButtonAudioFeedbackSound()
            self.playButtonAudioFeedbackSound()
            
        case Settings.touchFeedbackFeatures.touchAudio.settingsKey, Settings.touchFeedbackFeatures.touchAudio.$useGameVolume.settingsKey, Settings.touchFeedbackFeatures.touchAudio.$buttonVolume.settingsKey:
            self.updateButtonAudioFeedbackSound()
            
        case Settings.userInterfaceFeatures.statusBar.settingsKey, Settings.userInterfaceFeatures.statusBar.$isOn.settingsKey, Settings.userInterfaceFeatures.statusBar.$useToggle.settingsKey:
            self.updateStatusBar()
            
        case Settings.gbcFeatures.palettes.$palette.settingsKey, Settings.gbcFeatures.palettes.settingsKey, Settings.gbcFeatures.palettes.$spritePalette1.settingsKey, Settings.gbcFeatures.palettes.$spritePalette2.settingsKey, Settings.gbcFeatures.palettes.$multiPalette.settingsKey, Settings.gbcFeatures.palettes.$customPalette1Color1.settingsKey, Settings.gbcFeatures.palettes.$customPalette1Color2.settingsKey, Settings.gbcFeatures.palettes.$customPalette1Color3.settingsKey, Settings.gbcFeatures.palettes.$customPalette1Color4.settingsKey, Settings.gbcFeatures.palettes.$customPalette2Color1.settingsKey, Settings.gbcFeatures.palettes.$customPalette2Color2.settingsKey, Settings.gbcFeatures.palettes.$customPalette2Color3.settingsKey, Settings.gbcFeatures.palettes.$customPalette2Color4.settingsKey, Settings.gbcFeatures.palettes.$customPalette3Color1.settingsKey, Settings.gbcFeatures.palettes.$customPalette3Color2.settingsKey, Settings.gbcFeatures.palettes.$customPalette3Color3.settingsKey, Settings.gbcFeatures.palettes.$customPalette3Color4.settingsKey:
            self.updateGameboyPalette()
            
        case Settings.gameplayFeatures.quickSettings.$fastForwardSpeed.settingsKey:
            self.updateEmulationSpeed()
            
        case Settings.gameplayFeatures.quickSettings.$performQuickSave.settingsKey:
            self.dismissQuickSettings()
            self.performQuickSaveAction()
            
        case Settings.gameplayFeatures.quickSettings.$performQuickLoad.settingsKey:
            self.dismissQuickSettings()
            self.performQuickLoadAction()
            
        case Settings.gameplayFeatures.quickSettings.$performScreenshot.settingsKey:
            self.dismissQuickSettings()
            self.performScreenshotAction()
            
        case Settings.gameplayFeatures.quickSettings.$performPause.settingsKey:
            self.performPauseAction()
            
        case Settings.gameplayFeatures.quickSettings.$performMainMenu.settingsKey:
            self.performMainMenuAction()
            
        case Settings.dsFeatures.dsAirPlay.$topScreenOnly.settingsKey: fallthrough
        case Settings.dsFeatures.dsAirPlay.$layoutAxis.settingsKey:
            self.updateExternalDisplay()
            
        case Settings.controllerSkinFeatures.airPlaySkins.settingsKey: fallthrough
        case _ where settingsName.rawValue.hasPrefix(Settings.controllerSkinFeatures.airPlaySkins.settingsKey.rawValue):
            // Update whenever any of the AirPlay skins have changed.
            self.updateExternalDisplay()
            
        default: break
        }
    }
    
    @objc func deepLinkControllerLaunchGame(with notification: Notification)
    {
        guard let game = notification.userInfo?[DeepLink.Key.game] as? Game else { return }
        
        let previousGame = self.game
        self.game = game
        
        if Settings.gameplayFeatures.saveStates.autoLoad
        {
            let fetchRequest = SaveState.rst_fetchRequest() as! NSFetchRequest<SaveState>
            fetchRequest.predicate = NSPredicate(format: "%K == %@ AND %K == %d", #keyPath(SaveState.game), game, #keyPath(SaveState.type), SaveStateType.auto.rawValue)
            fetchRequest.sortDescriptors = [NSSortDescriptor(key: #keyPath(SaveState.creationDate), ascending: true)]

            do
            {
                let saveStates = try game.managedObjectContext?.fetch(fetchRequest)
                if let autoLoadSaveState = saveStates?.last
                {
                    let temporaryURL = FileManager.default.uniqueTemporaryURL()
                    try FileManager.default.copyItem(at: autoLoadSaveState.fileURL, to: temporaryURL)
                    
                    _deepLinkResumingSaveState = DeltaCore.SaveState(fileURL: temporaryURL, gameType: game.type)
                }
            }
            catch
            {
                print(error)
            }
        }
        else if let pausedSaveState = self.pausedSaveState, game == (previousGame as? Game)
        {
            // Launching current game via deep link, so we store a copy of the paused save state to resume when emulator core is started.
            
            do
            {
                let temporaryURL = FileManager.default.uniqueTemporaryURL()
                try FileManager.default.copyItem(at: pausedSaveState.fileURL, to: temporaryURL)
                
                _deepLinkResumingSaveState = DeltaCore.SaveState(fileURL: temporaryURL, gameType: game.type)
            }
            catch
            {
                print(error)
            }
        }
        
        if let pauseViewController = self.pauseViewController
        {
            let segue = UIStoryboardSegue(identifier: "unwindFromPauseMenu", source: pauseViewController, destination: self)
            self.unwindFromPauseViewController(segue)
        }
        else if
            let navigationController = self.presentedViewController as? UINavigationController,
            let pageViewController = navigationController.topViewController?.children.first as? UIPageViewController,
            let gameCollectionViewController = pageViewController.viewControllers?.first as? GameCollectionViewController
        {
            NotificationCenter.default.post(name: .dismissSettings, object: self)
            
            let segue = UIStoryboardSegue(identifier: "unwindFromGames", source: gameCollectionViewController, destination: self)
            self.unwindFromGamesViewController(with: segue)
        }
        
        self.dismiss(animated: true, completion: nil)
    }
    
    @objc func didActivateGyro(with notification: Notification)
    {
        self.isGyroActive = true
        self.lockOrientation()
        
        if #available(iOS 16, *)
        {
            // Needs called on main thread
            DispatchQueue.main.async{
                self.setNeedsUpdateOfSupportedInterfaceOrientations()
            }
        }
        
        guard !self.presentedGyroAlert else { return }
        
        self.presentedGyroAlert = true
        
        func presentToastView()
        {
            let toastView = RSTToastView(text: NSLocalizedString("Autorotation Disabled", comment: ""), detailText: NSLocalizedString("Pause game to change orientation.", comment: ""))
            self.show(toastView)
        }
        
        DispatchQueue.main.async {
            if let transitionCoordinator = self.transitionCoordinator
            {
                transitionCoordinator.animate(alongsideTransition: nil) { (context) in
                    presentToastView()
                }
            }
            else
            {
                presentToastView()
            }
        }
    }
    
    @objc func didDeactivateGyro(with notification: Notification)
    {
        self.isGyroActive = false
        self.unlockOrientation()
        
        if #available(iOS 16, *)
        {
            // Needs called on main thread
            DispatchQueue.main.async{
                self.setNeedsUpdateOfSupportedInterfaceOrientations()
            }
        }
    }
    
    @objc func didEnableJIT(with notification: Notification)
    {
        DispatchQueue.main.async {
            self.showJITEnabledAlert()
        }
        
        DispatchQueue.global(qos: .utility).async {
            guard let emulatorCore = self.emulatorCore, let emulatorBridge = emulatorCore.deltaCore.emulatorBridge as? MelonDSEmulatorBridge, !emulatorBridge.isJITEnabled
            else { return }
            
            guard emulatorCore.state != .stopped else {
                // Emulator core is not running, which means we can set
                // isJITEnabled to true without resetting the core.
                emulatorBridge.isJITEnabled = true
                return
            }
            
            let isVideoEnabled = emulatorCore.videoManager.isEnabled
            emulatorCore.videoManager.isEnabled = false
            
            let isRunning = (emulatorCore.state == .running)
            if isRunning
            {
                self.pauseEmulation()
            }
            
            let temporaryFileURL = FileManager.default.uniqueTemporaryURL()
            
            let saveState = emulatorCore.saveSaveState(to: temporaryFileURL)
            emulatorCore.stop()
            
            emulatorBridge.isJITEnabled = true
            
            emulatorCore.start()
            emulatorCore.pause()
            
            do
            {
                try emulatorCore.load(saveState)
            }
            catch
            {
                print("Failed to load save state after enabling JIT.", error)
            }
            
            if isRunning
            {
                self.resumeEmulation()
            }
            
            emulatorCore.videoManager.isEnabled = isVideoEnabled
        }
    }
    
    @objc func emulationDidQuit(with notification: Notification)
    {
        DispatchQueue.main.async {
            guard self.presentedViewController == nil else { return }
            
            // Wait for emulation to stop completely before performing segue.
            var token: NSKeyValueObservation?
            token = self.emulatorCore?.observe(\.state, options: [.initial]) { (emulatorCore, change) in
                guard emulatorCore.state == .stopped else { return }
                
                DispatchQueue.main.async {
                    self.game = nil
                    self.performSegue(withIdentifier: "showGamesViewController", sender: nil)
                }
                
                token?.invalidate()
            }
        }
    }
    
    @objc func sceneWillConnect(with notification: Notification)
    {
        guard let scene = notification.object as? ExternalDisplayScene else { return }
        self.connectExternalDisplay(for: scene)
    }

    @objc func sceneDidDisconnect(with notification: Notification)
    {
        guard let scene = notification.object as? ExternalDisplayScene else { return }
        self.disconnectExternalDisplay(for: scene)
    }
    
    @objc func deviceDidShake(with notification: Notification)
    {
        guard Settings.advancedFeatures.skinDebug.isEnabled,
              Settings.advancedFeatures.skinDebug.traitOverride else
        {
            guard Settings.gameplayFeatures.quickSettings.shakeToOpen else { return }
            
            self.performQuickSettingsAction()
            return
        }
        
        self.pauseEmulation()
        
        let alertController = UIAlertController(title: NSLocalizedString("Override Traits Menu", comment: ""), message: NSLocalizedString("This popup was activated by shaking your device while using the Override Traits feature. You can use it to change or reset your override traits, or to recover from situations where you can't access the main menu.", comment: ""), preferredStyle: .actionSheet)
        alertController.popoverPresentationController?.sourceView = self.view
        alertController.popoverPresentationController?.sourceRect = CGRect(x: self.view.bounds.midX, y: self.view.bounds.maxY, width: 0, height: 0)
        alertController.popoverPresentationController?.permittedArrowDirections = []
        
        alertController.addAction(UIAlertAction(title: "Choose Preset Traits", style: .default, handler: { (action) in
            self.performPresetTraitsAction()
        }))
        alertController.addAction(UIAlertAction(title: "Change Device", style: .default, handler: { (action) in
            self.performDebugDeviceAction()
        }))
        alertController.addAction(UIAlertAction(title: "Change Display Type", style: .default, handler: { (action) in
            self.performDebugDisplayTypeAction()
        }))
        alertController.addAction(UIAlertAction(title: "Reset Traits", style: .default, handler: { (action) in
            Settings.advancedFeatures.skinDebug.device = Settings.advancedFeatures.skinDebug.defaultDevice
            Settings.advancedFeatures.skinDebug.displayType = Settings.advancedFeatures.skinDebug.defaultDisplayType
            self.resumeEmulation()
            if Settings.userInterfaceFeatures.toasts.debug
            {
                self.presentToastView(text: NSLocalizedString("Trait Overrides have been reset", comment: ""))
            }
        }))
        alertController.addAction(UIAlertAction(title: "Open Pause Menu", style: .default, handler: { (action) in
            self.performPauseAction()
        }))
        alertController.addAction(UIAlertAction(title: "Cancel", style: .cancel, handler: { (action) in
            self.resumeEmulation()
        }))
        self.present(alertController, animated: true, completion: nil)
    }
}

private extension UserDefaults
{
    @NSManaged var desmumeDeprecatedAlertCount: Int
    
    @NSManaged var jitEnabledAlertCount: Int
}

//MARK: - Timer -
private extension GameViewController
{
    func activateRewindTimer()
    {
        self.invalidateRewindTimer()
        guard Settings.gameplayFeatures.rewind.isEnabled else { return }
        let interval = TimeInterval(Settings.gameplayFeatures.rewind.interval)
        self.rewindTimer = Timer.scheduledTimer(timeInterval: interval, target: self, selector: #selector(rewindPollFunction), userInfo: nil, repeats: true)
    }
    
    func invalidateRewindTimer()
    {
        self.rewindTimer?.invalidate()
    }
    
    @objc func rewindPollFunction() {
        
        guard Settings.gameplayFeatures.rewind.isEnabled,
              self.emulatorCore?.state == .running,
              let game = self.game as? Game else { return }
        
        // disable on GBC. saving state without pausing emulation crashes gambette
        guard self.game?.type != .gbc else { return }
        
        let fetchRequest: NSFetchRequest<SaveState> = SaveState.fetchRequest()
        fetchRequest.returnsObjectsAsFaults = false
        fetchRequest.sortDescriptors = [NSSortDescriptor(key: #keyPath(SaveState.creationDate), ascending: true)]
        
        if let system = System(gameType: game.type)
        {
            fetchRequest.predicate = NSPredicate(format: "%K == %@ AND %K == %@ AND %K == %@", #keyPath(SaveState.game), game, #keyPath(SaveState.coreIdentifier), system.deltaCore.identifier, #keyPath(SaveState.type), NSNumber(value: SaveStateType.rewind.rawValue))
        }
        else
        {
            fetchRequest.predicate = NSPredicate(format: "%K == %@ AND %K == %@", #keyPath(SaveState.game), game, #keyPath(SaveState.type), NSNumber(value: SaveStateType.rewind.rawValue))
        }
        
        do
        {
            let rewindStateCount = try DatabaseManager.shared.viewContext.count(for: fetchRequest) + 1 // + 1 to account for state to be saved after deleting
            let rewindStatesOverLimit = rewindStateCount - Int(floor(Settings.gameplayFeatures.rewind.maxStates))
            if rewindStatesOverLimit > 0
            {
                fetchRequest.fetchLimit = rewindStatesOverLimit
                for rewindStateToDelete in try DatabaseManager.shared.viewContext.fetch(fetchRequest)
                {
                    DatabaseManager.shared.performBackgroundTask { (context) in
                        let temporarySaveState = context.object(with: rewindStateToDelete.objectID)
                        context.delete(temporarySaveState)
                        context.saveWithErrorLogging()
                    }
                }
            }
        }
        catch
        {
            print(error)
        }
        
        let backgroundContext = DatabaseManager.shared.newBackgroundContext()
        backgroundContext.perform {
            
            let game = backgroundContext.object(with: game.objectID) as! Game
            
            let saveState = SaveState(context: backgroundContext)
            saveState.type = .rewind
            saveState.game = game
            
            self.update(saveState, shouldSuspendEmulation: false)
            
            backgroundContext.saveWithErrorLogging()
        }
    }
}
