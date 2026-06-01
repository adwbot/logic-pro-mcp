import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// `LogicProMCP mcu-setup` — opens Logic Pro's Control Surfaces > Setup window via
/// AppleScript menu navigation and prints step-by-step instructions for completing
/// the one-time installation of the Mackie Control surface bound to LogicProMCP-Out/-In.
///
/// Logic 12.2 will NOT honour MCU button/fader/V-Pot messages until the surface is
/// registered here. Apple's "auto-detect" claim in the docs applies only to physical
/// USB MCU hardware; virtual ports require this manual step.
enum MCUSetupCommand {
    static func run() -> Int {
        setvbuf(stdout, nil, _IOLBF, 0)

        guard ProcessUtils.isLogicProRunning else {
            print("Logic Pro is not running. Launch Logic Pro first, then re-run mcu-setup.")
            return 1
        }

        let script = """
        tell application "System Events"
            tell process "Logic Pro"
                set frontmost to true
                tell menu bar item "Logic Pro" of menu bar 1
                    tell menu 1
                        tell menu item "Control Surfaces"
                            tell menu 1
                                click menu item "Setup…"
                            end tell
                        end tell
                    end tell
                end tell
            end tell
        end tell
        """

        let p = Process()
        p.launchPath = "/usr/bin/osascript"
        p.arguments = ["-e", script]
        let errPipe = Pipe()
        p.standardError = errPipe
        do {
            try p.run()
            p.waitUntilExit()
            let err = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            if p.terminationStatus != 0 {
                print("Failed to open Setup via AppleScript: \(err.trimmingCharacters(in: .whitespacesAndNewlines))")
                print("Open the window manually: Logic Pro > Control Surfaces > Setup…")
            }
        } catch {
            print("Failed to launch osascript: \(error)")
            print("Open the window manually: Logic Pro > Control Surfaces > Setup…")
        }

        print("""

        === MCU one-time setup ===

        The Control Surfaces > Setup window should now be open in Logic Pro.
        Complete the following in Logic Pro (we cannot script this safely):

          1. Click 'New' button (top-left of the Setup window), then 'Install...'
          2. In the Install window, select 'Mackie Designs > Mackie Control'
          3. Click 'Add' (then close the Install window)
          4. The new Mackie Control surface appears in the Setup window. Select it.
          5. In the right-hand inspector, set:
               Input Port  = LogicProMCP-Out
               Output Port = LogicProMCP-In
          6. Close the Setup window. Done.

        Verify with:
          LogicProMCP mcu-verify --track 0 --op mute

        You should see PASS and the mute button on track 0 should toggle in Logic.
        """)

        return 0
    }
}
