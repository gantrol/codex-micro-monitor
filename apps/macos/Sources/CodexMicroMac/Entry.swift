import UIKit
import Darwin

@main
struct MicroEntry {
    @MainActor static func main() {
        signal(SIGPIPE,SIG_IGN)
        if let index=CommandLine.arguments.firstIndex(of:"--export-design") {
            guard CommandLine.arguments.indices.contains(index+1) else { fputs("--export-design requires an output directory.\n",stderr); exit(2) }
            do {
                let directory=URL(fileURLWithPath:CommandLine.arguments[index+1],isDirectory:true)
                try DesignExport.write(to:directory)
                print(directory.path)
            } catch { fputs("Design export failed: \(error.localizedDescription)\n",stderr); exit(1) }
            return
        }
        if CommandLine.arguments.contains("--version") {
            print(Bundle.main.object(forInfoDictionaryKey:"CodexMicroReleaseVersion") as? String ?? "0.3.15-macos-preview.5"); return
        }
        if CommandLine.arguments.contains("--capabilities") {
            if let data=try? JSONSerialization.data(withJSONObject:MacPreviewCapabilities.description,options:[.prettyPrinted,.sortedKeys]) { FileHandle.standardOutput.write(data+Data([10])) }; return
        }
        if CommandLine.arguments.contains("--mcp") {
            guard let service=Desktop.services else { fputs("MicroDesktop.bundle could not be loaded.\n",stderr); exit(1) }
            service.runMCP(); return
        }
        UIApplicationMain(CommandLine.argc,CommandLine.unsafeArgv,nil,NSStringFromClass(MicroApplicationDelegate.self))
    }
}
final class MicroApplicationDelegate: NSObject, UIApplicationDelegate {
    func application(_ application:UIApplication,configurationForConnecting session:UISceneSession,options:UIScene.ConnectionOptions) -> UISceneConfiguration {
        let config=UISceneConfiguration(name:"Micro",sessionRole:session.role); config.delegateClass=MicroSceneDelegate.self; return config
    }
}
final class MicroSceneDelegate: NSObject, UIWindowSceneDelegate {
    var window:UIWindow?
    private var controller:MicroViewController?
    func scene(_ scene:UIScene,willConnectTo session:UISceneSession,options:UIScene.ConnectionOptions) {
        guard let scene=scene as? UIWindowScene else { return }
        scene.title="Codex Micro Monitor"
        let controller=MicroViewController(), window=UIWindow(windowScene:scene)
        self.controller=controller; self.window=window
        window.backgroundColor = .clear; window.isOpaque=false; window.overrideUserInterfaceStyle = .light
        window.rootViewController=controller; window.makeKeyAndVisible()
        if let url=options.urlContexts.first?.url { controller.open(url) }
    }
    func scene(_ scene:UIScene,openURLContexts contexts:Set<UIOpenURLContext>) { for item in contexts { controller?.open(item.url) } }
    func sceneDidDisconnect(_ scene:UIScene) { controller?.model.stop(); Task { await controller?.model.closeTransport() } }
}
