import Testing
@testable import TidyTabsHost

@Test func choicesBecomeGroupsOfTwoOrMoreInPlanOrder() {
    let plan = [(name: "Home lab", icon: "chart"), (name: "Video", icon: "moon"), (name: "Mail", icon: "bell")]
    let groups = Grouping.groups(fromChoices: [1, 0, nil, 0, 1, 2], plan: plan)
    #expect(groups == [
        TabGroup(title: "Home lab", tabs: [2, 4], icon: "chart"),
        TabGroup(title: "Video", tabs: [1, 5], icon: "moon"),
    ])
}

@Test func unknownIconsFallBackToAPreset() {
    #expect(Grouping.icon(from: "rocket") == "rocket")
    #expect(Grouping.icon(from: "🎧") == Grouping.fallbackIcon)
}

@Test func cleanNameTrimsQuotesAndCapitalizes() {
    #expect(Grouping.cleanName(" \"japan trip\". ") == "Japan trip")
}
