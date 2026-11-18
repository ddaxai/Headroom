import Foundation

let environment = ProcessInfo.processInfo.environment
guard let suiteName = environment["CODEXBAR_PREFERENCES_SUITE"],
      suiteName == "__ISOLATED_DOMAIN__",
      let defaults = UserDefaults(suiteName: suiteName)
else {
    fatalError("Missing isolated preference suite")
}

defaults.set("isolated", forKey: "probe")
guard UserDefaults(suiteName: "__HOST_DOMAIN__")?.object(forKey: "probe") == nil else {
    fatalError("Host preference domain was touched")
}
