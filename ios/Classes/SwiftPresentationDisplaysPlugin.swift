import Flutter
import UIKit

// Scene delegate for external displays (iOS 16+).
// iOS creates a scene session with role .windowExternalDisplayNonInteractive
// when an external display is connected. This delegate captures the scene
// into static plugin state WITHOUT depending on any plugin instance existing
// yet, so cold-boot races (scene delegate firing before the Flutter engine
// has registered plugins) are impossible.
@available(iOS 16.0, *)
public class ExternalDisplaySceneDelegate: UIResponder, UIWindowSceneDelegate {
    public var window: UIWindow?

    public func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options connectionOptions: UIScene.ConnectionOptions) {
        guard let windowScene = scene as? UIWindowScene else {
            return
        }
        SwiftPresentationDisplaysPlugin.captureExternalScene(windowScene)
    }

    public func sceneDidDisconnect(_ scene: UIScene) {
        guard let windowScene = scene as? UIWindowScene else { return }
        SwiftPresentationDisplaysPlugin.releaseExternalScene(windowScene)
    }
}

public class SwiftPresentationDisplaysPlugin: NSObject, FlutterPlugin {
    // All state is STATIC. Flutter creates a fresh plugin instance per engine
    // registration (main engine, implicit engine, secondary display engine);
    // instance variables would split across instances and writes from the
    // scene delegate would be invisible to the instance bound to the method
    // channel. Static storage keeps a single source of truth.

    // Legacy UIScreen-based storage (iOS < 16)
    static var additionalWindows = [UIScreen: UIWindow]()
    static var screens = [UIScreen]()

    // Scene-based storage (iOS 16+)
    static var externalScenes = [UIWindowScene]()
    static var sceneBasedWindows = [UIWindowScene: UIWindow]()
    static var secondaryEngines = [UIWindowScene: FlutterEngine]()

    static var flutterEngineChannel: FlutterMethodChannel? = nil
    public static var controllerAdded: ((FlutterViewController) -> Void)?

    // Kept for any external reader; not required for correctness anymore.
    public static var shared: SwiftPresentationDisplaysPlugin?

    // Event sink used by the scene delegate to notify Dart:
    //   1 = display connected
    //   0 = display disconnected
    //   2 = secondary Flutter engine has mounted SecondaryDisplay and is ready to receive data
    static var displayEventSink: FlutterEventSink?

    private static var observersRegistered = false

    private static var useSceneBasedLifecycle: Bool {
        if #available(iOS 16.0, *) { return true }
        return false
    }

    public override init() {
        super.init()
        SwiftPresentationDisplaysPlugin.shared = self

        if !Self.screens.contains(UIScreen.main) {
            Self.screens.append(UIScreen.main)
        }

        Self.registerScreenObserversOnce()
    }

    // Register legacy UIScreen observers exactly once across all plugin
    // instances, so repeated engine registrations don't stack duplicate
    // handlers (and don't pin multiple plugin instances via NotificationCenter).
    private static func registerScreenObserversOnce() {
        guard !observersRegistered else { return }
        observersRegistered = true

        NotificationCenter.default.addObserver(forName: UIScreen.didConnectNotification,
                                               object: nil, queue: nil) { notification in
            if useSceneBasedLifecycle { return }
            guard let newScreen = notification.object as? UIScreen else { return }

            let newWindow = UIWindow(frame: newScreen.bounds)
            newWindow.screen = newScreen
            newWindow.isHidden = true

            screens.append(newScreen)
            additionalWindows[newScreen] = newWindow
        }

        NotificationCenter.default.addObserver(forName: UIScreen.didDisconnectNotification,
                                               object: nil, queue: nil) { notification in
            if useSceneBasedLifecycle { return }
            guard let screen = notification.object as? UIScreen else { return }

            for s in screens where s == screen {
                if let index = screens.firstIndex(of: s) {
                    screens.remove(at: index)
                    additionalWindows.removeValue(forKey: s)
                }
            }
        }
    }

    // MARK: - Scene capture (iOS 16+), callable without a plugin instance

    @available(iOS 16.0, *)
    public static func captureExternalScene(_ windowScene: UIWindowScene) {
        // Guard against double-capture if iOS ever calls willConnectTo twice for the same scene.
        if externalScenes.contains(where: { $0 === windowScene }) {
            return
        }
        let window = UIWindow(windowScene: windowScene)
        window.isHidden = true
        externalScenes.append(windowScene)
        sceneBasedWindows[windowScene] = window

        if displayEventSink == nil {
        } else {
        }
        displayEventSink?(1)
    }

    @available(iOS 16.0, *)
    public static func releaseExternalScene(_ windowScene: UIWindowScene) {
        sceneBasedWindows.removeValue(forKey: windowScene)
        externalScenes.removeAll { $0 === windowScene }

        // Explicitly tear down the secondary Flutter engine so we don't leak it.
        if let engine = secondaryEngines.removeValue(forKey: windowScene) {
            engine.destroyContext()
        }

        // Clear the dangling channel pointer; next show will reassign it.
        flutterEngineChannel = nil

        displayEventSink?(0)
    }

    // MARK: - Unified display count and window access

    private var totalDisplayCount: Int {
        if Self.useSceneBasedLifecycle {
            return 1 + Self.externalScenes.count
        } else {
            return Self.screens.count
        }
    }

    private func getExternalWindow(at index: Int) -> UIWindow? {
        if Self.useSceneBasedLifecycle {
            let sceneIndex = index - 1
            if sceneIndex >= 0 && sceneIndex < Self.externalScenes.count {
                return Self.sceneBasedWindows[Self.externalScenes[sceneIndex]]
            }
            return nil
        } else {
            if index > 0 && index < Self.screens.count {
                return Self.additionalWindows[Self.screens[index]]
            }
            return nil
        }
    }

    private func getExternalScene(at index: Int) -> UIWindowScene? {
        guard Self.useSceneBasedLifecycle else { return nil }
        let sceneIndex = index - 1
        guard sceneIndex >= 0 && sceneIndex < Self.externalScenes.count else { return nil }
        return Self.externalScenes[sceneIndex]
    }

    // MARK: - Flutter plugin registration

    public static func register(with registrar: FlutterPluginRegistrar) {
        let channel = FlutterMethodChannel(name: "presentation_displays_plugin", binaryMessenger: registrar.messenger())
        let instance = SwiftPresentationDisplaysPlugin()
        registrar.addMethodCallDelegate(instance, channel: channel)

        let eventChannel = FlutterEventChannel(name: "presentation_displays_plugin_events", binaryMessenger: registrar.messenger())
        let displayConnectedStreamHandler = DisplayConnectedStreamHandler()
        eventChannel.setStreamHandler(displayConnectedStreamHandler)
    }

    // MARK: - Method call handling

    public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        if call.method == "listDisplay" {
            let count = totalDisplayCount
            var jsonDisplaysList = "["
            for i in 0..<count {
                jsonDisplaysList += "{\"displayId\":\(i), \"name\":\"Screen \(i)\"},"
            }
            jsonDisplaysList = String(jsonDisplaysList.dropLast())
            jsonDisplaysList += "]"
            jsonDisplaysList = jsonDisplaysList.replacingOccurrences(of: "Screen 0", with: "Built-in Screen")
            result(jsonDisplaysList)
        }
        else if call.method == "showPresentation" {
            guard let args = call.arguments as? String,
                  let data = args.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data, options: .allowFragments),
                  let json = obj as? [String: Any] else {
                result(false)
                return
            }
            let displayId = json["displayId"] as? Int ?? 1
            let routerName = json["routerName"] as? String ?? "presentation"
            let createdNewEngine = showPresentation(index: displayId, routerName: routerName)
            // Return whether a fresh engine was created, so Dart can decide
            // whether to wait for the secondaryReady handshake.
            result(createdNewEngine)
        }
        else if call.method == "hidePresentation" {
            guard let args = call.arguments as? String,
                  let data = args.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data, options: .allowFragments),
                  let json = obj as? [String: Any] else {
                result(false)
                return
            }
            let displayId = json["displayId"] as? Int ?? 1
            hidePresentation(index: displayId)
            result(true)
        }
        else if call.method == "transferDataToPresentation" {
            Self.flutterEngineChannel?.invokeMethod("DataTransfer", arguments: call.arguments)
            result(true)
        }
        else {
            result(FlutterMethodNotImplemented)
        }
    }

    // MARK: - Presentation management

    // Returns:
    //   true  — a fresh FlutterEngine was created for the secondary display
    //   false — an existing engine/window was reused (just un-hidden)
    //   nil   — failure (no external scene / window available)
    @discardableResult
    private func showPresentation(index: Int, routerName: String) -> Bool? {
        guard let window = getExternalWindow(at: index) else {
            return nil
        }

        window.isHidden = false
        // Engine exists and is bound -> just unhide; reuse.
        if window.rootViewController is FlutterViewController {
            return false
        }

        let newEngine = FlutterEngine()
        newEngine.run(withEntrypoint: "secondaryDisplayMain", initialRoute: routerName)

        let extVC = FlutterViewController(engine: newEngine, nibName: nil, bundle: nil)
        window.rootViewController = extVC

        SwiftPresentationDisplaysPlugin.controllerAdded?(extVC)

        // Track the engine against its scene so we can destroy it on disconnect.
        if let scene = getExternalScene(at: index) {
            Self.secondaryEngines[scene] = newEngine
        }

        // Set up method channel for main<->secondary communication.
        // Outgoing: native invokes "DataTransfer" to deliver payloads to secondary.
        // Incoming: secondary invokes "secondaryReady" when its listener is live.
        let channel = FlutterMethodChannel(name: "presentation_displays_plugin_engine",
                                           binaryMessenger: extVC.binaryMessenger)
        channel.setMethodCallHandler { (call, result) in
            if call.method == "secondaryReady" {
                SwiftPresentationDisplaysPlugin.displayEventSink?(2)
                result(nil)
            } else {
                result(FlutterMethodNotImplemented)
            }
        }
        Self.flutterEngineChannel = channel
        return true
    }

    private func hidePresentation(index: Int) {
        guard let window = getExternalWindow(at: index) else { return }
        window.isHidden = true
    }
}

class DisplayConnectedStreamHandler: NSObject, FlutterStreamHandler {
    var sink: FlutterEventSink?
    var didConnectObserver: NSObjectProtocol?
    var didDisconnectObserver: NSObjectProtocol?

    func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
        sink = events
        SwiftPresentationDisplaysPlugin.displayEventSink = events

        // Legacy UIScreen notifications for iOS < 16.
        didConnectObserver = NotificationCenter.default.addObserver(
            forName: UIScreen.didConnectNotification, object: nil, queue: nil) { [weak self] _ in
                if #available(iOS 16.0, *) { return }
                self?.sink?(1)
            }
        didDisconnectObserver = NotificationCenter.default.addObserver(
            forName: UIScreen.didDisconnectNotification, object: nil, queue: nil) { [weak self] _ in
                if #available(iOS 16.0, *) { return }
                self?.sink?(0)
            }
        return nil
    }

    func onCancel(withArguments arguments: Any?) -> FlutterError? {
        sink = nil
        SwiftPresentationDisplaysPlugin.displayEventSink = nil
        if let t = didConnectObserver { NotificationCenter.default.removeObserver(t) }
        if let t = didDisconnectObserver { NotificationCenter.default.removeObserver(t) }
        didConnectObserver = nil
        didDisconnectObserver = nil
        return nil
    }
}
