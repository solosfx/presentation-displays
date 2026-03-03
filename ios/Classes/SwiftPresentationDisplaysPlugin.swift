import Flutter
import UIKit

// Scene delegate for external displays (iOS 16+)
// iOS automatically creates a scene session with role .windowExternalDisplayNonInteractive
// when an external display is connected. This delegate handles that scene.
@available(iOS 16.0, *)
public class ExternalDisplaySceneDelegate: UIResponder, UIWindowSceneDelegate {
    public var window: UIWindow?

    public func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options connectionOptions: UIScene.ConnectionOptions) {
        guard let windowScene = scene as? UIWindowScene else { return }
        SwiftPresentationDisplaysPlugin.shared?.handleExternalSceneConnect(windowScene)
    }

    public func sceneDidDisconnect(_ scene: UIScene) {
        guard let windowScene = scene as? UIWindowScene else { return }
        SwiftPresentationDisplaysPlugin.shared?.handleExternalSceneDisconnect(windowScene)
    }
}

public class SwiftPresentationDisplaysPlugin: NSObject, FlutterPlugin {
    // Legacy UIScreen-based storage (iOS < 16)
    var additionalWindows = [UIScreen:UIWindow]()
    var screens = [UIScreen]()

    // Scene-based storage (iOS 16+)
    var externalScenes = [UIWindowScene]()
    var sceneBasedWindows = [UIWindowScene: UIWindow]()

    var flutterEngineChannel:FlutterMethodChannel?=nil
    public static var controllerAdded: ((FlutterViewController)->Void)?

    // Shared instance for scene delegate communication
    public static var shared: SwiftPresentationDisplaysPlugin?

    // Static event sink so scene delegate can notify Flutter
    static var displayEventSink: FlutterEventSink?

    private var useSceneBasedLifecycle: Bool {
        if #available(iOS 16.0, *) {
            return true
        }
        return false
    }

    public override init() {
        super.init()
        SwiftPresentationDisplaysPlugin.shared = self

        screens.append(UIScreen.main)

        // UIScreen notifications for iOS < 16 (legacy approach)
        NotificationCenter.default.addObserver(forName: UIScreen.didConnectNotification,
                                               object: nil, queue: nil) {
            notification in
            // On iOS 16+, external displays are handled via scene delegate
            if self.useSceneBasedLifecycle { return }

            guard let newScreen = notification.object as? UIScreen else {
                    return
                  }

            let screenDimensions = newScreen.bounds
            let newWindow = UIWindow(frame: screenDimensions)
            newWindow.screen = newScreen
            newWindow.isHidden = true

            self.screens.append(newScreen)
            self.additionalWindows[newScreen] = newWindow
        }

        NotificationCenter.default.addObserver(forName:
                                                UIScreen.didDisconnectNotification,
                                               object: nil,
                                               queue: nil) { notification in
            if self.useSceneBasedLifecycle { return }

            guard let screen = notification.object as? UIScreen else {
                    return
                  }

            for s in self.screens {
               if s == screen {
                 if let index = self.screens.firstIndex(of: s) {
                   self.screens.remove(at: index)
                   self.additionalWindows.removeValue(forKey: s)
                 }
               }
             }
        }
    }

    // MARK: - Scene-based external display handling (iOS 16+)

    @available(iOS 16.0, *)
    public func handleExternalSceneConnect(_ windowScene: UIWindowScene) {
        let window = UIWindow(windowScene: windowScene)
        window.isHidden = true
        externalScenes.append(windowScene)
        sceneBasedWindows[windowScene] = window

        // Notify Flutter about display connection
        SwiftPresentationDisplaysPlugin.displayEventSink?(1)
    }

    @available(iOS 16.0, *)
    public func handleExternalSceneDisconnect(_ windowScene: UIWindowScene) {
        sceneBasedWindows.removeValue(forKey: windowScene)
        externalScenes.removeAll { $0 == windowScene }

        // Notify Flutter about display disconnection
        SwiftPresentationDisplaysPlugin.displayEventSink?(0)
    }

    // MARK: - Unified display count and window access

    private var totalDisplayCount: Int {
        if useSceneBasedLifecycle {
            return 1 + externalScenes.count
        } else {
            return screens.count
        }
    }

    private func getExternalWindow(at index: Int) -> UIWindow? {
        if useSceneBasedLifecycle {
            let sceneIndex = index - 1
            if sceneIndex >= 0 && sceneIndex < externalScenes.count {
                return sceneBasedWindows[externalScenes[sceneIndex]]
            }
            return nil
        } else {
            if index > 0 && index < screens.count {
                return additionalWindows[screens[index]]
            }
            return nil
        }
    }

    private func isExternalDisplayAvailable(at index: Int) -> Bool {
        return getExternalWindow(at: index) != nil
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
            var jsonDisplaysList = "[";
            for i in 0..<count {
                jsonDisplaysList+="{\"displayId\":"+String(i)+", \"name\":\"Screen "+String(i)+"\"},"
            }
            jsonDisplaysList = String(jsonDisplaysList.dropLast())
            jsonDisplaysList+="]"
            jsonDisplaysList = jsonDisplaysList.replacingOccurrences(of: "Screen 0", with: "Built-in Screen")
            result(jsonDisplaysList)
        }
        else if call.method=="showPresentation"{
            let args = call.arguments as? String
            let data = args?.data(using: .utf8)!
            do {
                if let json = try JSONSerialization.jsonObject(with: data ?? Data(), options : .allowFragments) as? Dictionary<String,Any>
                {
                    print(json)
                    showPresentation(index:json["displayId"] as? Int ?? 1, routerName: json["routerName"] as? String ?? "presentation")
                    result(true)
                }
                else {
                    print("bad json")
                    result(false)
                }
            }
            catch let error as NSError {
                print(error)
                result(false)
            }
        }
        else if call.method=="hidePresentation"{
            let args = call.arguments as? String
            let data = args?.data(using: .utf8)!
            do {
                if let json = try JSONSerialization.jsonObject(with: data ?? Data(), options : .allowFragments) as? Dictionary<String,Any>
                {
                    print(json)
                    hidePresentation(index:json["displayId"] as? Int ?? 1)
                    result(true)
                }
                else {
                    print("bad json")
                    result(false)
                }
            }
            catch let error as NSError {
                print(error)
                result(false)
            }
        }
        else if call.method=="transferDataToPresentation"{
            self.flutterEngineChannel?.invokeMethod("DataTransfer", arguments: call.arguments)
            result(true)
        }
        else
        {
            result(FlutterMethodNotImplemented)
        }

    }

    // MARK: - Presentation management

    private func showPresentation(index:Int, routerName:String)
    {
        guard let window = getExternalWindow(at: index) else { return }

        window.isHidden = false
        if (window.rootViewController == nil || !(window.rootViewController is FlutterViewController)){
            let newEngine = FlutterEngine()
            newEngine.run(withEntrypoint: "secondaryDisplayMain", initialRoute: routerName)

            let extVC = FlutterViewController(engine: newEngine, nibName: nil, bundle: nil)
            window.rootViewController = extVC

            SwiftPresentationDisplaysPlugin.controllerAdded!(extVC)
            self.flutterEngineChannel = FlutterMethodChannel(name: "presentation_displays_plugin_engine", binaryMessenger: extVC.binaryMessenger)
        }
    }

    private func hidePresentation(index:Int)
    {
        guard let window = getExternalWindow(at: index) else { return }
        window.isHidden = true
    }

}

class DisplayConnectedStreamHandler: NSObject, FlutterStreamHandler{
    var sink: FlutterEventSink?
    var didConnectObserver: NSObjectProtocol?
    var didDisconnectObserver: NSObjectProtocol?

    func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
        sink = events
        // Store in static var so scene delegate can also send events
        SwiftPresentationDisplaysPlugin.displayEventSink = events

        // UIScreen notifications for iOS < 16
        didConnectObserver = NotificationCenter.default.addObserver(forName: UIScreen.didConnectNotification,
                            object: nil, queue: nil) { (notification) in
            if #available(iOS 16.0, *) { return }
            guard let sink = self.sink else { return }
            sink(1)
           }
        didDisconnectObserver = NotificationCenter.default.addObserver(forName: UIScreen.didDisconnectNotification,
                            object: nil, queue: nil) { (notification) in
            if #available(iOS 16.0, *) { return }
            guard let sink = self.sink else { return }
            sink(0)
           }
        return nil
    }

    func onCancel(withArguments arguments: Any?) -> FlutterError? {
        sink = nil
        SwiftPresentationDisplaysPlugin.displayEventSink = nil
        if (didConnectObserver != nil){
            NotificationCenter.default.removeObserver(didConnectObserver!)
        }
        if (didDisconnectObserver != nil){
            NotificationCenter.default.removeObserver(didDisconnectObserver!)
        }
        return nil
    }
}
