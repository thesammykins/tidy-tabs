// Asks Apple's on-device model (FoundationModels, about 3B parameters) which tabs belong together.
//
// Asking for a free-text subject per tab and grouping exact matches suits shopping and research tabs, but on everyday
// tabs (dashboards, mail, video, chat) the subjects rarely match, so most tabs stay loose. So this works in two calls,
// which a small model handles more reliably:
//   1. Plan: seeing every tab, the model names the groups worth making, each with one of Aside's preset icons.
//   2. Sort: every tab gets its own answer field (so tabs can't be mixed up) whose value is constrained by the schema
//      to one of those names or "none". The model can't invent a group or misspell one.
// Sampling is greedy, so the same tabs always give the same groups.
import Foundation
import FoundationModels

enum Model {
    static let none = "none"

    /// Why the model can't be used now, or nil when it can.
    static func unavailableReason() -> String? {
        switch SystemLanguageModel.default.availability {
        case .available: return nil
        case .unavailable(.appleIntelligenceNotEnabled): return "Apple Intelligence is off. Enable it in System Settings › Apple Intelligence & Siri."
        case .unavailable(.deviceNotEligible): return "Apple Intelligence isn't supported on this Mac."
        case .unavailable(.modelNotReady): return "The Apple Intelligence model is still downloading. Try again shortly."
        default: return "Apple Intelligence is unavailable right now."
        }
    }

    /// Step 1: the groups worth making for these tabs. `lines` are "title (address)".
    static func plan(for lines: [String]) async throws -> [(name: String, icon: String)] {
        let group = DynamicGenerationSchema(name: "Group", properties: [
            .init(name: "name", description: "1 to 3 words naming what the group's tabs have in common", schema: .init(type: String.self)),
            .init(name: "icon", description: "The icon that best fits the group",
                  schema: DynamicGenerationSchema(name: "Icon", anyOf: Grouping.icons.map(\.id))),
        ])
        let root = DynamicGenerationSchema(name: "Plan", properties: [
            .init(name: "groups", schema: DynamicGenerationSchema(arrayOf: DynamicGenerationSchema(referenceTo: "Group"), minimumElements: 1, maximumElements: 8)),
        ])
        let schema = try GenerationSchema(root: root, dependencies: [group])
        let prompt = "Tabs:\n" + lines.map { "- \($0)" }.joined(separator: "\n")
        let content = try await LanguageModelSession(instructions: """
            You organise a person's browser tabs into groups. Read every tab (its title, then its web address), then \
            name the groups that would tidy them best. Each group must fit at least two of the tabs. Group by what \
            the person is doing: tabs for the same project, trip, purchase, topic or kind of site go together, such \
            as all video sites, all mail and messaging, or all dashboards for the same servers. Use names that appear \
            in the tabs where you can. Don't make a group that fits only one tab, and don't make two groups for the \
            same thing.

            Give each group one of these icons: \(Grouping.icons.map { "\($0.id) (\($0.meaning))" }.joined(separator: ", ")).
            """).respond(to: prompt, schema: schema, options: options).content
        let groups = try content.value([GeneratedContent].self, forProperty: "groups")
        Log.write("plan: \(content.jsonString)")
        var seen = Set<String>()
        return groups.compactMap { group in
            let name = Grouping.cleanName((try? group.value(String.self, forProperty: "name")) ?? "")
            guard !name.isEmpty, name.lowercased() != none, seen.insert(name.lowercased()).inserted else { return nil }
            return (name, Grouping.icon(from: (try? group.value(String.self, forProperty: "icon")) ?? ""))
        }
    }

    /// Step 2: for each tab, the index of the planned group it belongs in, or nil.
    static func sort(_ lines: [String], into names: [String]) async throws -> [Int?] {
        let choice = DynamicGenerationSchema(name: "Choice", anyOf: names + [none])
        let answer = DynamicGenerationSchema(name: "Tab", properties: [
            .init(name: "about", description: "2 to 6 words on what the page is for", schema: .init(type: String.self)),
            .init(name: "group", description: "The group this tab belongs in, or none", schema: DynamicGenerationSchema(referenceTo: "Choice")),
        ])
        let fields = lines.indices.map {
            DynamicGenerationSchema.Property(name: "tab\($0 + 1)", description: lines[$0], schema: DynamicGenerationSchema(referenceTo: "Tab"))
        }
        let schema = try GenerationSchema(root: DynamicGenerationSchema(name: "Tabs", properties: fields), dependencies: [answer, choice])
        let prompt = "Groups: \(names.joined(separator: "; "))\n\nTabs:\n"
            + lines.indices.map { "tab\($0 + 1): \(lines[$0])" }.joined(separator: "\n")
        let content = try await LanguageModelSession(instructions: """
            Put each browser tab into one of the given groups. For each tab, say in a few words what the page is for, \
            then pick the group it belongs in. Pick none only when no group fits the tab at all.
            """).respond(to: prompt, schema: schema, options: options).content
        Log.write("sort: \(content.jsonString)")
        return lines.indices.map {
            let tab = try? content.value(GeneratedContent.self, forProperty: "tab\($0 + 1)")
            return (try? tab?.value(String.self, forProperty: "group")).flatMap { names.firstIndex(of: $0) }
        }
    }

    /// Which existing group a newly opened tab belongs in, as an index into `groups`, or nil when none fits.
    /// The answer is constrained to the group names plus "none", so the model can't invent a group.
    static func assign(tab line: String, to groups: [(title: String, tabs: [String])]) async throws -> Int? {
        // Two groups can share a name; numbering keeps each choice distinct.
        let choices = groups.indices.map { "\($0 + 1). \(groups[$0].title)" }
        let answer = DynamicGenerationSchema(name: "Answer", properties: [
            .init(name: "about", description: "2 to 6 words on what the new tab is about", schema: .init(type: String.self)),
            .init(name: "group", description: "The group the new tab belongs in, or none",
                  schema: DynamicGenerationSchema(name: "Choice", anyOf: choices + [none])),
        ])
        let schema = try GenerationSchema(root: answer, dependencies: [])
        let listing = groups.indices.map { index in
            "\(choices[index]): " + groups[index].tabs.prefix(5).map { "\"\($0)\"" }.joined(separator: ", ")
        }.joined(separator: "\n")
        let prompt = "Groups:\n\(listing)\n\nNew tab: \(line)"
        let content = try await LanguageModelSession(instructions: """
            A person keeps browser tabs in groups. Decide which group a newly opened tab belongs in. Each group is its \
            name and some of its tabs' titles. Say in a few words what the new tab is about, then pick a group only if \
            the new tab is what the group's name says. Being on the same website is not enough: a news video does not \
            belong in a group of review videos, and a cooking video does not belong in a group of music videos. When \
            unsure, pick none; a wrong group is worse than no group.
            """).respond(to: prompt, schema: schema, options: options).content
        Log.write("assign: \(content.jsonString)")
        return choices.firstIndex(of: try content.value(String.self, forProperty: "group"))
    }

    // macOS 27 renames this samplingMode; the old spelling is deprecated but still the only one macOS 26 has.
    private static var options: GenerationOptions { GenerationOptions(sampling: .greedy) }
}
