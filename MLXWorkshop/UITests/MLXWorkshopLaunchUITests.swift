import XCTest

@MainActor
final class MLXWorkshopLaunchUITests: XCTestCase {
  override func setUpWithError() throws {
    continueAfterFailure = false
  }

  func testFreshLaunchShowsModelSetupSurface() throws {
    let app = XCUIApplication()
    app.launchArguments = ["-ApplePersistenceIgnoreState", "YES", "--ui-test-reset"]
    app.launch()

    XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 10))
    XCTAssertTrue(
      app.staticTexts["Set up your first optimization"].waitForExistence(timeout: 10))
    XCTAssertTrue(app.buttons["Choose model folder…"].exists)
    XCTAssertTrue(app.buttons["Choose results folder…"].exists)
  }

  func testRealTinyModelPlanRunQualificationAndSupportedNavigation() throws {
    let fixture = try makeTinyModelFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }

    let app = XCUIApplication()
    app.launchEnvironment["MLX_WORKSPACE"] = sourceRoot.path
    app.launchArguments = [
      "-ApplePersistenceIgnoreState", "YES", "--ui-test-reset",
      "--ui-test-model=\(fixture.model.path)",
      "--ui-test-workspace=\(fixture.workspace.path)",
    ]
    app.launch()

    XCTAssertTrue(app.staticTexts["Create an optimized copy"].waitForExistence(timeout: 45))
    XCTAssertFalse(app.staticTexts["Demo data"].exists)
    XCTAssertFalse(app.staticTexts["Compare"].exists)

    let primaryAction = app.buttons["workflow.primaryAction"]
    XCTAssertTrue(primaryAction.waitForExistence(timeout: 10))
    primaryAction.click()

    XCTAssertTrue(
      app.staticTexts["Confirm weight-changing run"].waitForExistence(timeout: 45))
    XCTAssertTrue(app.buttons["confirmation.decline"].exists)
    XCTAssertTrue(app.buttons["confirmation.confirm"].exists)
    app.buttons["confirmation.confirm"].click()

    let verifyResult = app.buttons["guide.nextAction"]
    XCTAssertTrue(
      verifyResult.waitForExistence(timeout: 45),
      "A successful conversion must offer verification before it is marked ready")
    let verificationReady = XCTNSPredicateExpectation(
      predicate: NSPredicate(format: "label == %@", "Verify result"),
      object: verifyResult)
    XCTAssertEqual(XCTWaiter.wait(for: [verificationReady], timeout: 45), .completed)
    verifyResult.click()
    let verificationComplete = XCTNSPredicateExpectation(
      predicate: NSPredicate(format: "label == %@", "Show result in Finder"),
      object: verifyResult)
    XCTAssertEqual(XCTWaiter.wait(for: [verificationComplete], timeout: 45), .completed)

    app.staticTexts["Runs"].firstMatch.click()
    XCTAssertTrue(app.staticTexts["Run history"].waitForExistence(timeout: 10))
    XCTAssertTrue(
      app.staticTexts["Run state: qualified; all required gates passed"].firstMatch.exists)

    app.staticTexts["Host"].firstMatch.click()
    XCTAssertTrue(app.staticTexts["This Mac"].waitForExistence(timeout: 10))
    XCTAssertTrue(app.buttons["host.refresh"].exists)
    app.buttons["host.refresh"].click()
    XCTAssertTrue(app.staticTexts["Hardware and environment"].waitForExistence(timeout: 20))
  }

  private var sourceRoot: URL {
    URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
  }

  private func makeTinyModelFixture() throws -> (root: URL, model: URL, workspace: URL) {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("mlx-workshop-ui-e2e-\(UUID().uuidString)", isDirectory: true)
    let model = sourceRoot.appendingPathComponent(
      "tests/fixtures/tiny-llama-float", isDirectory: true)
    let workspace = root.appendingPathComponent("runs", isDirectory: true)
    try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
    guard FileManager.default.fileExists(atPath: model.appendingPathComponent("config.json").path)
    else { throw XCTSkip("The checked-in deterministic tiny model fixture is missing.") }
    return (root, model, workspace)
  }
}
