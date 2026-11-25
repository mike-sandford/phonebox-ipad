import UIKit

@main
final class AppDelegate: UIResponder, UIApplicationDelegate {
    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        UIDevice.current.isBatteryMonitoringEnabled = true
        return true
    }

    func application(_ application: UIApplication, configurationForConnecting connectingSceneSession: UISceneSession,
                     options: UIScene.ConnectionOptions) -> UISceneConfiguration {
        UISceneConfiguration(name: "Default", sessionRole: connectingSceneSession.role)
    }
}

final class SceneDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?
    private var panel: PanelViewController?

    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options connectionOptions: UIScene.ConnectionOptions) {
        guard let windowScene = scene as? UIWindowScene else { return }
        let panel = PanelViewController()
        let window = UIWindow(windowScene: windowScene)
        window.backgroundColor = .black
        window.rootViewController = panel
        window.makeKeyAndVisible()
        self.window = window
        self.panel = panel
        // started from a phonebox://pair link while the app was not running
        if let url = connectionOptions.urlContexts.first?.url { panel.handlePairingURL(url) }
    }

    func scene(_ scene: UIScene, openURLContexts URLContexts: Set<UIOpenURLContext>) {
        if let url = URLContexts.first?.url { panel?.handlePairingURL(url) }
    }

    func sceneDidBecomeActive(_ scene: UIScene) { panel?.setVisible(true) }
    func sceneWillResignActive(_ scene: UIScene) { panel?.setVisible(false) }
}
