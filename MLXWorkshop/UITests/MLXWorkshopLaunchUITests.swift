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
    XCTAssertTrue(app.staticTexts["Start with a local model"].waitForExistence(timeout: 10))
    XCTAssertTrue(app.buttons["Choose model…"].exists)
    XCTAssertTrue(app.buttons["Choose run workspace…"].exists)
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

    XCTAssertTrue(app.staticTexts["Uniform quantization"].waitForExistence(timeout: 45))
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

    XCTAssertTrue(
      app.buttons["run.lifecycle.qualify"].waitForExistence(timeout: 45),
      "A successful conversion must remain explicitly unqualified until gates run")
    app.buttons["run.lifecycle.qualify"].click()
    XCTAssertTrue(
      app.staticTexts["Qualified — all required gates passed"].waitForExistence(timeout: 45))

    app.staticTexts["Runs"].firstMatch.click()
    XCTAssertTrue(app.staticTexts["Run history"].waitForExistence(timeout: 10))
    XCTAssertTrue(app.staticTexts["Qualified"].firstMatch.exists)

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
