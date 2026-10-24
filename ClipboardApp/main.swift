import AppKit

if CommandLine.arguments.dropFirst().first == AppRestart.helperArgument {
    do {
        try AppRestart.runHelper(arguments: CommandLine.arguments, bundleURL: Bundle.main.bundleURL)
        exit(EXIT_SUCCESS)
    } catch {
        NSLog("Clipboard restart failed: %@", error.localizedDescription)
        exit(EXIT_FAILURE)
    }
}

let application = NSApplication.shared
let delegate = AppDelegate()
application.delegate = delegate
application.run()
