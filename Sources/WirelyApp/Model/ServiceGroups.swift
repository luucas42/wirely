import Foundation
import WirelyCore

/// A ready-made list of the domains one service uses (site, app, video and image hosts).
struct ServiceGroup: Identifiable, Equatable {
    let id: String
    let name: String
    let domains: [String]
    /// Normalised drafts that mean this service exactly (a dotted alias becomes the group when added).
    let aliases: [String]
}

enum ServiceGroups {
    static let all: [ServiceGroup] = [
        ServiceGroup(id: "youtube", name: "YouTube",
                     domains: ["youtube.com", "googlevideo.com", "ytimg.com", "youtu.be", "youtube-nocookie.com",
                               "youtubei.googleapis.com", "youtube.googleapis.com", "ggpht.com",
                               "yt3.googleusercontent.com"],
                     aliases: ["youtube", "youtube.com", "www.youtube.com", "m.youtube.com", "youtu.be"]),
        ServiceGroup(id: "spotify", name: "Spotify",
                     domains: ["spotify.com", "scdn.co", "spotifycdn.com", "spotifycdn.net", "pscdn.co",
                               "audio-ak-spotify-com.akamaized.net", "audio4-ak-spotify-com.akamaized.net"],
                     aliases: ["spotify", "spotify.com", "open.spotify.com", "www.spotify.com"]),
        ServiceGroup(id: "x", name: "X",
                     domains: ["x.com", "twitter.com", "twimg.com", "t.co"],
                     aliases: ["x.com", "www.x.com", "twitter", "twitter.com", "www.twitter.com"]),
        ServiceGroup(id: "netflix", name: "Netflix",
                     domains: ["netflix.com", "netflix.net", "nflxvideo.net", "nflximg.net", "nflximg.com",
                               "nflxext.com", "nflxso.net"],
                     aliases: ["netflix", "netflix.com", "www.netflix.com"]),
        ServiceGroup(id: "twitch", name: "Twitch",
                     domains: ["twitch.tv", "ttvnw.net", "jtvnw.net", "twitchcdn.net", "twitchsvc.net"],
                     aliases: ["twitch", "twitch.tv", "www.twitch.tv"]),
    ]

    static func group(id: String) -> ServiceGroup? { all.first { $0.id == id } }

    /// The draft cleaned like a rule (lowercase, scheme/path/port stripped); nil when it isn't a name.
    static func normalized(_ draft: String) -> String? {
        if case .success(.domain(let d)) = SplitRule.parse(draft) { return d }
        return nil
    }

    /// A group worth offering while typing: at least 3 characters, equal to an alias or the start of its name.
    static func suggestion(for draft: String) -> ServiceGroup? {
        guard let s = normalized(draft), s.count >= 3 else { return nil }
        return all.first { $0.aliases.contains(s) || $0.name.lowercased().hasPrefix(s) }
    }

    /// The group a finished draft stands for: only dotted aliases (`youtube.com`, not `youtube`).
    static func exactAlias(_ draft: String) -> ServiceGroup? {
        guard let s = normalized(draft), s.contains(".") else { return nil }
        return all.first { $0.aliases.contains(s) }
    }
}
