import Foundation
import Testing
@testable import CodexBar

struct HeadroomRestartTests {
    @Test
    func `relaunch command waits for the current process before opening the app`() {
        let command = HeadroomRelaunchCoordinator.relaunchCommand(
            parentProcessIdentifier: 42,
            bundlePath: "/Applications/Headroom.app")

        #expect(command.executablePath == "/bin/sh")
        #expect(command.arguments.first == "-c")
        #expect(command.arguments.dropFirst().contains("42"))
        #expect(command.arguments.last == "/Applications/Headroom.app")
        #expect(command.arguments[1].contains("kill -0 \"$1\""))
        #expect(command.arguments[1].contains("/usr/bin/open \"$2\""))
    }

    @Test
    func `restart action has a native menu icon`() {
        #expect(MenuDescriptor.MenuAction.restart.systemImageName == "arrow.clockwise.circle")
    }
}
