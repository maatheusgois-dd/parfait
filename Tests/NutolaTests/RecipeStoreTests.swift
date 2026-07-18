import XCTest
@testable import Nutola

final class RecipeStoreTests: XCTestCase {
    /// Each test gets a private UserDefaults suite so nothing leaks across tests
    /// or into the user's real recipe library.
    private let suiteName = "NutolaTests.RecipeStore.\(UUID().uuidString)"
    private let key = "recipes"

    private func makeStore() -> RecipeStore {
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.setPersistentDomain([:], forName: suiteName)
        return RecipeStore(defaults: defaults, key: key)
    }

    override func tearDown() {
        UserDefaults().removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    func testEmptyStore() {
        let store = makeStore()
        XCTAssertTrue(store.all().isEmpty)
        XCTAssertNil(store.recipe(named: "Anything"))
    }

    func testAddRecipe() {
        let store = makeStore()
        let recipe = store.add(name: "Weekly recap", prompt: "Summarize my week")

        XCTAssertEqual(store.all().count, 1)
        XCTAssertEqual(recipe.name, "Weekly recap")
        XCTAssertEqual(recipe.prompt, "Summarize my week")
        XCTAssertEqual(store.all().first, recipe)

        // A fresh store backed by the *same* suite should see the recipe —
        // it has to survive across instances (UserDefaults persistence).
        let defaults = UserDefaults(suiteName: suiteName)!
        let reloaded = RecipeStore(defaults: defaults, key: key)
        XCTAssertEqual(reloaded.all(), [recipe])
    }

    func testDeleteRecipe() {
        let store = makeStore()
        let recipe = store.add(name: "Action items", prompt: "List action items")
        XCTAssertEqual(store.all().count, 1)

        store.delete(id: recipe.id)
        XCTAssertTrue(store.all().isEmpty)
    }

    func testUpdateRecipe() {
        let store = makeStore()
        let original = store.add(name: "Follow-up", prompt: "Draft a follow-up")

        var updated = original
        updated.name = "Follow-up email"
        updated.prompt = "Draft a polite follow-up email"
        store.update(updated)

        let recipes = store.all()
        XCTAssertEqual(recipes.count, 1)
        XCTAssertEqual(recipes.first?.name, "Follow-up email")
        XCTAssertEqual(recipes.first?.prompt, "Draft a polite follow-up email")
        XCTAssertEqual(recipes.first?.id, original.id)
    }

    func testRecipeNamed() {
        let store = makeStore()
        _ = store.add(name: "Decisions", prompt: "What decisions came out?")

        // Case-insensitive lookup matches the TemplateStore convention.
        XCTAssertEqual(store.recipe(named: "Decisions")?.name, "Decisions")
        XCTAssertEqual(store.recipe(named: "decisions")?.name, "Decisions")
        XCTAssertEqual(store.recipe(named: "DECISIONS")?.name, "Decisions")
        XCTAssertNil(store.recipe(named: "Missing"))
    }

    func testAllSortedByName() {
        let store = makeStore()
        _ = store.add(name: "Zebra", prompt: "z")
        _ = store.add(name: "alpha", prompt: "a")
        _ = store.add(name: "Mango", prompt: "m")

        let names = store.all().map(\.name)
        XCTAssertEqual(names, ["alpha", "Mango", "Zebra"])
    }
}
