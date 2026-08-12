import AppKit
import Foundation

/// One thing being measured.
///
/// A metric is a source to listen to, a set of fields kept from what that source
/// reports, a condition deciding whether an occurrence is worth keeping, and a
/// table of everything kept so far.
struct MetricDefinition: Identifiable, Codable, Hashable {
    let id: UUID
    var name: String
    var isRecording: Bool
    var source: MetricSource

    /// Field names seen the last time the source was sniffed, in the order they
    /// arrived. Kept so the table can be rebuilt without waiting for another
    /// event.
    var sniffedKeys: [String]
    /// One example of each field, purely so the table has something to show.
    var sample: [String: String]
    /// Fields the user has removed. Dropped before the condition runs and never
    /// written to the database.
    var prunedKeys: Set<String>

    /// A JavaScript condition. Empty means "keep everything".
    var condition: String

    init(id: UUID = UUID(),
         name: String = "New metric",
         isRecording: Bool = false,
         source: MetricSource = .init(),
         sniffedKeys: [String] = [],
         sample: [String: String] = [:],
         prunedKeys: Set<String> = [],
         condition: String = "") {
        self.id = id
        self.name = name
        self.isRecording = isRecording
        self.source = source
        self.sniffedKeys = sniffedKeys
        self.sample = sample
        self.prunedKeys = prunedKeys
        self.condition = condition
    }

    /// The fields that survive pruning, in their original order.
    var keptKeys: [String] {
        sniffedKeys.filter { !prunedKeys.contains($0) }
    }

    var isArmable: Bool { isRecording && source.isConfigured }
}

/// Where a metric's events come from. Every one of these is a notification the
/// system already posts.
struct MetricSource: Codable, Hashable {
    enum Kind: String, Codable, CaseIterable, Identifiable {
        case musicTrack
        case spotifyTrack
        case appActivated
        case appLaunched
        case appTerminated
        case screenLocked
        case screenUnlocked
        case custom

        var id: String { rawValue }

        var label: String {
            switch self {
            case .musicTrack: return "Apple Music Track Change"
            case .spotifyTrack: return "Spotify Track Change"
            case .appActivated: return "App Switch"
            case .appLaunched: return "App Launch"
            case .appTerminated: return "App Quit"
            case .screenLocked: return "Screen Locked"
            case .screenUnlocked: return "Screen Unlocked"
            case .custom: return "Custom Notification"
            }
        }

        var detail: String {
            switch self {
            case .musicTrack: return "com.apple.Music.playerInfo — fires on every track and state change"
            case .spotifyTrack: return "com.spotify.client.PlaybackStateChanged"
            case .appActivated: return "Whenever the frontmost application changes"
            case .appLaunched: return "Whenever an application starts"
            case .appTerminated: return "Whenever an application quits"
            case .screenLocked: return "com.apple.screenIsLocked"
            case .screenUnlocked: return "com.apple.screenIsUnlocked"
            case .custom: return "Any distributed notification name you know of"
            }
        }

        /// The distributed notification this listens on, if it is one.
        var distributedName: String? {
            switch self {
            case .musicTrack: return "com.apple.Music.playerInfo"
            case .spotifyTrack: return "com.spotify.client.PlaybackStateChanged"
            case .screenLocked: return "com.apple.screenIsLocked"
            case .screenUnlocked: return "com.apple.screenIsUnlocked"
            case .appActivated, .appLaunched, .appTerminated, .custom: return nil
            }
        }

        /// The workspace notification this listens on, if it is one.
        var workspaceName: Notification.Name? {
            switch self {
            case .appActivated: return NSWorkspace.didActivateApplicationNotification
            case .appLaunched: return NSWorkspace.didLaunchApplicationNotification
            case .appTerminated: return NSWorkspace.didTerminateApplicationNotification
            default: return nil
            }
        }
    }

    var kind: Kind = .musicTrack
    var customName: String = ""

    var isConfigured: Bool {
        kind == .custom ? !customName.isEmpty : true
    }

    var notificationName: String {
        kind == .custom ? customName : (kind.distributedName ?? kind.label)
    }
}

/// One captured occurrence, already pruned.
struct MetricRecord: Identifiable, Hashable {
    let id: Int64
    let capturedAt: Date
    let values: [String: String]
}
