import Foundation

/// Launch arguments used by the App Store screenshot workflow:
///   -screenshots            fill the app with sample places; nothing is saved or scheduled
///   -screen list|detail|add which screen to open on launch
enum ScreenshotMode {
    static let isOn = ProcessInfo.processInfo.arguments.contains("-screenshots")

    static var screen: String? {
        let args = ProcessInfo.processInfo.arguments
        guard isOn, let i = args.firstIndex(of: "-screen"), i + 1 < args.count else { return nil }
        return args[i + 1]
    }

    static var sampleReminders: [PlaceReminder] {
        let samples: [(String, String, Double, Double, String)] = [
            ("Harbor Fish House", "1120 SW Front Ave, Portland", 45.5150, -122.6745,
             "Don't get the fish. The burger was great, ask for extra pickles."),
            ("Luna Taqueria", "3510 SE Division St, Portland", 45.5049, -122.6283,
             "Al pastor tacos + horchata. Skip the nachos."),
            ("Copper Kettle Café", "720 NW 23rd Ave, Portland", 45.5275, -122.6985,
             "Window seat has the outlet. Oat latte, not the drip."),
            ("Northside Hardware", "2215 N Williams Ave, Portland", 45.5395, -122.6670,
             "Ask Dana for the 3/8\" brass fittings. Aisle 7."),
        ]
        return samples.enumerated().map { index, sample in
            var reminder = PlaceReminder(place: PlaceCandidate(
                name: sample.0, address: sample.1, latitude: sample.2, longitude: sample.3))
            reminder.note = sample.4
            reminder.isEnabled = index != 3
            return reminder
        }
    }
}
