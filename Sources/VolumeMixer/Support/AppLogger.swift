import OSLog

enum AppLogger {
    static let audio = Logger(subsystem: "com.ydps915.VolumeMixer", category: "audio")
    static let app = Logger(subsystem: "com.ydps915.VolumeMixer", category: "app")
}
