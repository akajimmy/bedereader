import AVFoundation
import Flutter
import GameController
import Network
import Photos
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    if let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "BeDeReaderScreen") {
      ScreenChannel.register(messenger: registrar.messenger())
    }
    if let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "BeDeReaderRemote") {
      RemoteLog.register(messenger: registrar.messenger())
    }
  }
}

/// The app itself (Info.plist NSPrincipalClass): every event the system sends the app passes here first, before any
/// screen or Flutter - so Settings > Remote and keys > Test the remote can tell "the system gave the app nothing"
/// from "the app was given it and lost it" (user, 2026-10-25: the Chromecast remote on the iPad). Touches and the
/// pointer's hovering aren't reported; nothing is changed or held back.
@objc(ReaderApplication)
class ReaderApplication: UIApplication {
  override func sendEvent(_ event: UIEvent) {
    if RemoteLog.on && event.type != .touches && event.type != .hover {
      switch event.type {
      case .presses:
        if let presses = (event as? UIPressesEvent)?.allPresses {
          for p in presses {
            RemoteLog.log("app press \(RemoteLog.phase(p.phase)): \(RemoteLog.describe(p))")
          }
        }
      case .remoteControl:
        RemoteLog.log("app remote-control event, subtype \(event.subtype.rawValue)")
      default:
        RemoteLog.log("app event of type \(event.type.rawValue), subtype \(event.subtype.rawValue)")
      }
    }
    super.sendEvent(event)
  }
}

/// The Flutter screen (Main.storyboard): its button presses reported before Flutter has them - Flutter drops a press
/// that has no keyboard key (an arrow or select from a TV remote, say), so the test sees what it would have missed.
class ReaderViewController: FlutterViewController {
  override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
    for p in presses { RemoteLog.log("screen press began: \(RemoteLog.describe(p))") }
    super.pressesBegan(presses, with: event)
  }

  override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
    for p in presses { RemoteLog.log("screen press ended: \(RemoteLog.describe(p))") }
    super.pressesEnded(presses, with: event)
  }
}

/// Test the remote's iOS side ("komga_reader/remote", lib/screens/remote_test.dart): while the screen is open
/// ("start" to "stop"), what the system gives the app - its events, the screen's presses (above), game controllers
/// and a keyboard as the GameController framework sees them, remote-control events, the volume - each sent to the
/// screen as a line. Off, nothing is watched or sent.
enum RemoteLog {
  static var on = false
  private static var channel: FlutterMethodChannel?
  private static var volume: NSKeyValueObservation?
  private static var observers: [NSObjectProtocol] = []

  static func register(messenger: FlutterBinaryMessenger) {
    let c = FlutterMethodChannel(name: "komga_reader/remote", binaryMessenger: messenger)
    c.setMethodCallHandler { call, result in
      switch call.method {
      case "start":
        start()
        result(nil)
      case "stop":
        stop()
        result(nil)
      default:
        result(FlutterMethodNotImplemented)
      }
    }
    channel = c
  }

  static func log(_ text: String) {
    guard on else { return }
    if Thread.isMainThread {
      channel?.invokeMethod("event", arguments: text)
    } else {
      DispatchQueue.main.async { channel?.invokeMethod("event", arguments: text) }
    }
  }

  private static func start() {
    on = true
    UIApplication.shared.beginReceivingRemoteControlEvents()
    let session = AVAudioSession.sharedInstance()
    // (ambient, mixed: any music playing goes on; the volume can only be watched with a session active)
    try? session.setCategory(.ambient, mode: .default, options: [.mixWithOthers])
    try? session.setActive(true)
    volume = session.observe(\.outputVolume, options: [.new]) { _, change in
      log("volume now \(change.newValue ?? -1)")
    }
    let controllers = GCController.controllers()
    log("listening: volume \(session.outputVolume), game controllers \(controllers.count)"
      + ", keyboard \(GCKeyboard.coalesced != nil ? "connected" : "none")")
    for c in controllers { watch(c) }
    if let k = GCKeyboard.coalesced { watch(k) }
    let center = NotificationCenter.default
    observers = [
      center.addObserver(forName: .GCControllerDidConnect, object: nil, queue: .main) { n in
        if let c = n.object as? GCController {
          log("game controller connected")
          watch(c)
        }
      },
      center.addObserver(forName: .GCKeyboardDidConnect, object: nil, queue: .main) { n in
        if let k = n.object as? GCKeyboard {
          log("keyboard connected (GameController)")
          watch(k)
        }
      },
    ]
  }

  private static func stop() {
    on = false
    volume?.invalidate()
    volume = nil
    for o in observers { NotificationCenter.default.removeObserver(o) }
    observers = []
    if #available(iOS 16.0, *) {
      for c in GCController.controllers() { c.physicalInputProfile.valueDidChangeHandler = nil }
    }
    GCKeyboard.coalesced?.keyboardInput?.keyChangedHandler = nil
    UIApplication.shared.endReceivingRemoteControlEvents()
    try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
  }

  private static func watch(_ c: GCController) {
    let name = c.vendorName ?? "?"
    log("game controller: \(name), \(c.productCategory)")
    // (its buttons watched from iPadOS 16: before, only that it's there is reported)
    if #available(iOS 16.0, *) {
      c.physicalInputProfile.valueDidChangeHandler = { _, element in
        var value = ""
        if let b = element as? GCControllerButtonInput { value = " \(b.value)" }
        log("game controller \(name): \(element.localizedName ?? "?")\(value)")
      }
    }
  }

  private static func watch(_ k: GCKeyboard) {
    k.keyboardInput?.keyChangedHandler = { _, _, code, pressed in
      log("keyboard (GameController) key 0x\(String(code.rawValue, radix: 16)) \(pressed ? "down" : "up")")
    }
  }

  static func describe(_ p: UIPress) -> String {
    var s = "type \(p.type.rawValue) (\(typeName(p.type)))"
    if let k = p.key {
      s += ", keyboard key 0x\(String(k.keyCode.rawValue, radix: 16)) \"\(k.charactersIgnoringModifiers)\""
    } else {
      s += ", no keyboard key"
    }
    return s
  }

  static func phase(_ phase: UIPress.Phase) -> String {
    switch phase {
    case .began: return "began"
    case .changed: return "changed"
    case .stationary: return "stationary"
    case .ended: return "ended"
    case .cancelled: return "cancelled"
    @unknown default: return "phase \(phase.rawValue)"
    }
  }

  private static func typeName(_ t: UIPress.PressType) -> String {
    switch t {
    case .upArrow: return "up arrow"
    case .downArrow: return "down arrow"
    case .leftArrow: return "left arrow"
    case .rightArrow: return "right arrow"
    case .select: return "select"
    case .menu: return "menu"
    case .playPause: return "play/pause"
    case .pageUp: return "page up"
    case .pageDown: return "page down"
    default: return "other"
    }
  }
}

/// The app's own platform channel (lib/screen.dart, "komga_reader/screen"), iOS side. What Android and Windows answer
/// that matters on an iPad: where the app keeps its files (downloads, eBook page counts), keeping the screen awake
/// while a book is open, the battery for the reader's clock, opening a link in the browser, and the way the screen is
/// up (the reader's rotation lock, Locked), the reader's screen brightness, mobile data or not (Downloads' Wi-Fi
/// only), and Save / Copy page (Photos, the clipboard) - as Android's (user, 2026-10-22). Full screen isn't asked for.
enum ScreenChannel {
  /// The level the reader set (nil: the screen follows the person's own), and their own level, to put back - iOS keeps
  /// an app's brightness after the app is left, Android doesn't.
  private static var ownBrightness: CGFloat?
  private static var theirBrightness: CGFloat?
  private static let paths = NWPathMonitor()
  private static var path: NWPath?

  static func register(messenger: FlutterBinaryMessenger) {
    paths.pathUpdateHandler = { p in path = p }
    paths.start(queue: DispatchQueue(label: "BeDeReader.network"))
    let center = NotificationCenter.default
    // the app left (another app, the home screen, locked): their own brightness back; back in the app: the reader's
    center.addObserver(forName: UIApplication.willResignActiveNotification, object: nil, queue: .main) { _ in
      if ownBrightness != nil, let theirs = theirBrightness { UIScreen.main.brightness = theirs }
    }
    center.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { _ in
      if let own = ownBrightness {
        theirBrightness = UIScreen.main.brightness
        UIScreen.main.brightness = own
      }
    }
    let channel = FlutterMethodChannel(name: "komga_reader/screen", binaryMessenger: messenger)
    channel.setMethodCallHandler { call, result in
      switch call.method {
      case "brightness":
        setBrightness((call.arguments as? NSNumber)?.doubleValue ?? -1)
        result(nil)
      case "getBrightness":
        result(Double(UIScreen.main.brightness))
      case "network":
        result(network())
      case "savePicture":
        savePicture(call.arguments, result)
      case "copyPicture":
        guard let args = call.arguments as? [String: Any], let bytes = args["bytes"] as? FlutterStandardTypedData,
          let image = UIImage(data: bytes.data)
        else {
          result(false)
          return
        }
        UIPasteboard.general.image = image
        result(true)
      case "storageDir":
        result(storageDir())
      case "documentsDir":
        // the app's own folder the Files app shows (On My iPad > the app's name): books copied in there by the
        // person - local libraries on this device (lib/local/device_folders.dart)
        result(FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first?.path)
      case "appVersion":
        // as Android and Windows answer (lib/screen.dart): the version and the build number - About, the update
        // check, the EPUB layouts' cache key, the remote log (never answered on iOS before: user, 2026-10-25)
        let info = Bundle.main.infoDictionary
        guard let name = info?["CFBundleShortVersionString"] as? String,
          let code = Int(info?["CFBundleVersion"] as? String ?? "")
        else {
          result(nil)
          return
        }
        result(["name": name, "code": code])
      case "excludeFromBackup":
        // the folder (and all in it) left out of iCloud and computer backups (lib/screen.dart, appStorageDir)
        guard let path = call.arguments as? String else {
          result(false)
          return
        }
        var url = URL(fileURLWithPath: path, isDirectory: true)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        do {
          try url.setResourceValues(values)
          result(true)
        } catch {
          result(false)
        }
      case "keepOn":
        UIApplication.shared.isIdleTimerDisabled = (call.arguments as? Bool) ?? false
        result(nil)
      case "battery":
        let device = UIDevice.current
        device.isBatteryMonitoringEnabled = true
        let level = device.batteryLevel  // 0...1, or -1 when unknown (the simulator)
        if level < 0 {
          result(nil)
          return
        }
        let charging = device.batteryState == .charging || device.batteryState == .full
        result(["level": Int((level * 100).rounded()), "charging": charging])
      case "openUrl":
        guard let text = call.arguments as? String, let url = URL(string: text) else {
          result(false)
          return
        }
        UIApplication.shared.open(url, options: [:]) { opened in result(opened) }
      case "fullscreen":
        result(false)  // an iPad app is always full screen
      case "currentWayUp":
        result(currentWayUp())
      default:
        result(FlutterMethodNotImplemented)
      }
    }
  }

  /// -1: the person's own level back; else the reader's (0.01...1), their own kept to put back.
  private static func setBrightness(_ value: Double) {
    if value < 0 {
      if ownBrightness != nil, let theirs = theirBrightness { UIScreen.main.brightness = theirs }
      ownBrightness = nil
      theirBrightness = nil
      return
    }
    if ownBrightness == nil { theirBrightness = UIScreen.main.brightness }
    let level = CGFloat(min(max(value, 0.01), 1))
    ownBrightness = level
    UIScreen.main.brightness = level
  }

  /// "wifi" (or a cable), "cellular", "none", "other" - as Android's answer. Not known yet: "wifi" (better a download
  /// than a queue stuck for no reason).
  private static func network() -> String {
    guard let p = path else { return "wifi" }
    if p.status != .satisfied { return "none" }
    if p.usesInterfaceType(.wifi) || p.usesInterfaceType(.wiredEthernet) { return "wifi" }
    if p.usesInterfaceType(.cellular) { return "cellular" }
    return "other"
  }

  /// Save page: into Photos (asked for once - adding only, nothing read). Answers where it went, or nil.
  private static func savePicture(_ arguments: Any?, _ result: @escaping FlutterResult) {
    guard let args = arguments as? [String: Any], let bytes = args["bytes"] as? FlutterStandardTypedData else {
      result(nil)
      return
    }
    PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
      guard status == .authorized || status == .limited else {
        DispatchQueue.main.async { result(nil) }
        return
      }
      PHPhotoLibrary.shared().performChanges({
        PHAssetCreationRequest.forAsset().addResource(with: .photo, data: bytes.data, options: nil)
      }) { saved, _ in
        DispatchQueue.main.async { result(saved ? "Photos" : nil) }
      }
    }
  }

  /// The way the screen is up now, named as Android's (lib/screen.dart, OrientationLock): portrait,
  /// reversePortrait, landscape (UIKit's landscapeLeft), reverseLandscape - or nil.
  private static func currentWayUp() -> String? {
    let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
    switch scene?.interfaceOrientation {
    case .portrait: return "portrait"
    case .portraitUpsideDown: return "reversePortrait"
    case .landscapeLeft: return "landscape"
    case .landscapeRight: return "reverseLandscape"
    default: return nil
    }
  }

  /// Application Support/BeDeReader: kept, backed up, not shown in the Files app, never cleared by the system (the
  /// temporary folder the Dart side falls back on is).
  private static func storageDir() -> String? {
    guard let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
      return nil
    }
    let dir = base.appendingPathComponent("BeDeReader", isDirectory: true)
    do {
      try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    } catch {
      return nil
    }
    return dir.path
  }
}
