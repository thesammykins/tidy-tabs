// Turns the model's answers into groups. Kept free of FoundationModels so it can be unit tested.
import Foundation

struct TabGroup: Codable, Equatable {
    var title: String
    var tabs: [Int]  // 1-based positions in the request's tab list.
    var icon: String?  // One of Grouping.icons, for Aside's group icon.
}

enum Grouping {
        // Each tab's chosen group (an index into `plan`, or nil) becomes groups in plan order. Groups with fewer than two
    // tabs are dropped: a group of one tidies nothing.
    static func groups(fromChoices choices: [Int?], plan: [(name: String, icon: String)]) -> [TabGroup] {
        plan.indices.compactMap { group in
            let tabs = choices.indices.filter { choices[$0] == group }.map { $0 + 1 }
            return tabs.count >= 2 ? TabGroup(title: plan[group].name, tabs: tabs, icon: plan[group].icon) : nil
        }
    }

    // Group names show in a narrow sidebar: trim stray punctuation and quotes, cap the length.
    static func cleanName(_ name: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters).union(.symbols))
        return String(trimmed.prefix(1).uppercased() + trimmed.dropFirst()).prefix(30).trimmingCharacters(in: .whitespaces)
    }

    // Aside's group icons are a fixed set of presets, named in its icon picker (aside_icon_picker_view.cc in the Aside
    // Framework binary); its tabGroups.update ignores anything else, emoji included. The meanings steer the model.
    static let icons: [(id: String, meaning: String)] = [
        ("bubble", "chat and messages"), ("bell", "mail and notifications"), ("chart", "dashboards and stats"),
        ("banknote", "money and finance"), ("shopping_bag", "shopping"), ("suitcase", "travel and work"),
        ("map_pin", "places and maps"), ("headphones", "music, audio and video"), ("moon", "entertainment"),
        ("telescope", "research"), ("magic_book", "reading and docs"), ("pencil", "writing and notes"),
        ("palette", "design and art"), ("atom", "science and code"), ("rocket", "projects and launches"),
        ("magic_wand", "AI and tools"), ("trophy", "sport and games"), ("flame", "trending and news"),
        ("thumbs_up", "social media"), ("smile", "fun"), ("slime", "kids and play"), ("clock", "schedules"),
        ("hourglass", "waiting and later"), ("half_circle", "settings"), ("form_circle", "general"),
        ("form_square", "general"), ("form_diamond", "general"), ("form_flower", "general"),
    ]
    static let fallbackIcon = "form_circle"

    static func icon(from answer: String) -> String {
        icons.contains { $0.id == answer } ? answer : fallbackIcon
    }
}
