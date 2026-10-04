import Foundation

// Only Objective-C/Foundation values cross the macOS / Mac Catalyst boundary.
@objc(MicroDesktopServices) public protocol DesktopServices: NSObjectProtocol {
    init()
    func execute(_ id: String, operation: String, arguments: Data, reply: @escaping (Data?, NSError?) -> Void)
    func cancel(_ id: String)
    func close(_ reply: @escaping () -> Void)
    func runMCP()
    func install(_ event: @escaping (String) -> Void)
    func configureWindow(_ title: String, scale: Double, floating: Bool) -> Bool
    func showWindow()
    func hideWindow()
    func centerWindow()
    func dragWindow()
    func showMenu()
}
