import XCTest
import AppKit

final class CraftUITests: XCTestCase {

    @MainActor
    func testNativeDeepLinksDeferStartupAndPreserveOpenDraft() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let base = environment["CRAFT_UI_BACKEND_URL"],
              let path = environment["CRAFT_UI_DATA_DIR"], let socket = environment["CRAFT_UI_PTY_SOCKET"] else {
            throw XCTSkip("Run macos/scripts/test-browser-ui.sh to provide the isolated fixture.")
        }
        let app = XCUIApplication()
        app.launchArguments = ["--backend-url", base, "--data-dir", path, "--pty-socket", socket]
        app.open(URL(string: "craft://app/sessions/sidebar-2")!)
        XCTAssertTrue(app.buttons["Show Changes"].waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertTrue(app.buttons["Open Terminal"].exists)
        let running = try XCTUnwrap(NSWorkspace.shared.frontmostApplication)
        XCTAssertEqual(running.bundleIdentifier, "com.alexcding.craft")
        let applicationURL = try XCTUnwrap(running.bundleURL)
        guard applicationURL.path.contains(".xctestproducts/") || applicationURL.path.contains("/.build/ui-tests/") else {
            XCTFail("URL delivery target is outside the test products: \(applicationURL.path)"); return
        }
        // XCTest.open deliberately relaunches the app. Use Launch Services against
        // this verified app path to exercise warm delivery without losing its draft.
        func deliver(_ address: String) async throws {
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.arguments = app.launchArguments
            configuration.addsToRecentItems = false
            let opened = try await NSWorkspace.shared.open([URL(string: address)!], withApplicationAt: applicationURL, configuration: configuration)
            XCTAssertEqual(opened.processIdentifier, running.processIdentifier)
        }
        app.buttons["New Project"].click()
        let draft = app.sheets.textFields["project-name"]
        XCTAssertTrue(draft.waitForExistence(timeout: 5))
        draft.click(); app.typeText("Keep deeplink draft")
        try await deliver("craft://app/settings")
        XCTAssertEqual(draft.value as? String, "Keep deeplink draft")
        app.sheets.buttons["Cancel"].click()
        XCTAssertTrue(app.radioButtons["Text Editor"].waitForExistence(timeout: 5))
        let (data, _) = try await URLSession.shared.data(from: URL(string: base + "/api/projects")!)
        let projects = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [[String: Any]])
        let projectID = try XCTUnwrap(projects.first?["id"] as? String)
        try await deliver("craft://app/projects/\(projectID)/tickets")
        XCTAssertTrue(app.descendants(matching: .any)["jira-ticket-REC-1"].firstMatch.waitForExistence(timeout: 10))
        try await deliver("craft://app/projects/\(projectID)/settings")
        XCTAssertTrue(app.buttons["Delete Project…"].waitForExistence(timeout: 5))
        app.buttons["Delete Project…"].click()
        XCTAssertTrue(app.sheets.buttons["Delete Project"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["New Project"].isEnabled)
        try await deliver("craft://app/activity")
        XCTAssertTrue(app.sheets.buttons["Delete Project"].exists)
        app.sheets.buttons["Cancel"].click()
        XCTAssertTrue(app.buttons["Clear Logs…"].waitForExistence(timeout: 5))
        try await deliver("craft://app/projects/\(projectID)/tickets")
        XCTAssertTrue(app.descendants(matching: .any)["jira-ticket-REC-1"].firstMatch.waitForExistence(timeout: 10))
        try await deliver("craft://app/sessions/removed")
        XCTAssertTrue(app.staticTexts["The linked session is no longer available."].waitForExistence(timeout: 5))
        XCTAssertTrue(app.descendants(matching: .any)["jira-ticket-REC-1"].firstMatch.exists)
        try await deliver("craft://app/sessions/sidebar-2")
        XCTAssertTrue(app.buttons["Show Changes"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Open Terminal"].exists, "Selecting a linked session must not spawn a shell")
    }

    @MainActor
    func testNativeHistoryLoadsOlderCommitsAndKeepsPatchesReadOnly() throws {
        let environment = ProcessInfo.processInfo.environment
        guard let base = environment["CRAFT_UI_BACKEND_URL"],
              let path = environment["CRAFT_UI_DATA_DIR"], let socket = environment["CRAFT_UI_PTY_SOCKET"] else {
            throw XCTSkip("Run macos/scripts/test-browser-ui.sh to provide the isolated fixture.")
        }
        let app = XCUIApplication()
        app.launchArguments = ["--backend-url", base, "--data-dir", path, "--pty-socket", socket]
        app.launch()
        let row = app.outlines["workspace-sidebar"].staticTexts["sidebar-2"].firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 10)); row.click()
        app.buttons["Show Changes"].click()
        app.radioButtons["History"].click()
        XCTAssertTrue(app.staticTexts["Fixture history unavailable"].waitForExistence(timeout: 10))
        app.buttons["Refresh History"].click()
        XCTAssertTrue(app.staticTexts["Commits ahead of release/next"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["Fixture commit unavailable"].waitForExistence(timeout: 5))
        app.buttons["Retry Commit"].click()
        XCTAssertTrue(app.webViews.staticTexts["History.swift"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.webViews.buttons["Discard"].exists)
        XCTAssertFalse(app.webViews.buttons["Open History.swift"].exists)
        let search = app.textFields["Search loaded commits"]
        app.typeKey("f", modifierFlags: .command)
        app.typeText("Oldest fixture commit")
        XCTAssertEqual(search.value as? String, "Oldest fixture commit")
        XCTAssertTrue(app.staticTexts["No loaded commits match this search."].waitForExistence(timeout: 5))
        app.buttons["Load Older Commits"].click()
        let oldest = app.staticTexts["Oldest fixture commit"].firstMatch
        XCTAssertTrue(oldest.waitForExistence(timeout: 5)); oldest.click()
        XCTAssertTrue(app.buttons["Copy Commit SHA"].waitForExistence(timeout: 5))
        app.radioButtons["Changes"].click()
        app.radioButtons["History"].click()
        XCTAssertTrue(app.textFields["Search loaded commits"].exists)
        XCTAssertTrue(app.staticTexts["Oldest fixture commit"].firstMatch.waitForExistence(timeout: 5))
        search.click(); app.typeKey("a", modifierFlags: .command); app.typeKey(.delete, modifierFlags: [])
        XCTAssertTrue(app.webViews.staticTexts["History.swift"].waitForExistence(timeout: 10))
        let screenshot = app.screenshot()
        let screenshotURL = FileManager.default.temporaryDirectory.appendingPathComponent("craft-history.png")
        try screenshot.pngRepresentation.write(to: screenshotURL)
        print("History screenshot: " + screenshotURL.path)
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    @MainActor
    func testNativeDiscardCancelFailureAndRecovery() throws {
        let environment = ProcessInfo.processInfo.environment
        guard let base = environment["CRAFT_UI_BACKEND_URL"],
              let path = environment["CRAFT_UI_DATA_DIR"], let socket = environment["CRAFT_UI_PTY_SOCKET"] else {
            throw XCTSkip("Run macos/scripts/test-browser-ui.sh to provide the isolated fixture.")
        }
        let app = XCUIApplication()
        app.launchArguments = ["--backend-url", base, "--data-dir", path, "--pty-socket", socket]
        app.launch()
        let row = app.outlines["workspace-sidebar"].staticTexts["sidebar-2"].firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 10)); row.click()
        app.buttons["Show Changes"].click()
        let discard = app.webViews.buttons["Discard"].firstMatch
        XCTAssertTrue(discard.waitForExistence(timeout: 10))
        discard.click()
        XCTAssertTrue(app.staticTexts["Fixture diff unavailable"].waitForExistence(timeout: 5))
        app.buttons["Refresh Changes"].click()
        discard.click()
        XCTAssertTrue(app.sheets.staticTexts["Discard this change block?"].waitForExistence(timeout: 5))
        app.sheets.buttons["Cancel"].click()
        XCTAssertTrue(discard.exists)
        discard.click()
        XCTAssertTrue(app.sheets.buttons["Discard Block"].waitForExistence(timeout: 5))
        app.sheets.buttons["Discard Block"].click()
        XCTAssertTrue(app.sheets.staticTexts["Fixture discard rejected"].waitForExistence(timeout: 5))
        app.sheets.buttons["Discard Block"].click()
        let closed = expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: app.sheets.firstMatch)
        wait(for: [closed], timeout: 8)
        XCTAssertTrue(app.webViews.staticTexts["No changes"].waitForExistence(timeout: 5) || app.webViews.buttons["Untracked.txt"].exists)
        XCTAssertFalse(discard.exists)
    }

    @MainActor
    func testNativeCommitAndPushKeepsSuccessfulCommitOnPushFailure() throws {
        let environment = ProcessInfo.processInfo.environment
        guard let base = environment["CRAFT_UI_BACKEND_URL"],
              let path = environment["CRAFT_UI_DATA_DIR"], let socket = environment["CRAFT_UI_PTY_SOCKET"] else {
            throw XCTSkip("Run macos/scripts/test-browser-ui.sh to provide the isolated fixture.")
        }
        let app = XCUIApplication()
        app.launchArguments = ["--backend-url", base, "--data-dir", path, "--pty-socket", socket]
        app.launch()
        let row = app.outlines["workspace-sidebar"].staticTexts["sidebar-2"].firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 10)); row.click()
        app.buttons["Show Changes"].click()
        XCTAssertTrue(app.webViews.buttons["Open Sources/Fixture.swift"].waitForExistence(timeout: 10))
        app.buttons["Commit and Push…"].click()
        XCTAssertTrue(app.sheets.staticTexts["Fixture diff unavailable"].waitForExistence(timeout: 5))
        app.sheets.buttons["Refresh"].click()
        let message = app.sheets.textFields.firstMatch
        XCTAssertTrue(message.waitForExistence(timeout: 5))
        message.click(); message.typeText("Native commit fixture")
        app.sheets.checkBoxes["Include untracked files"].click()
        app.sheets.buttons["Commit and Push"].click()
        XCTAssertTrue(app.sheets.staticTexts["Commit abc1234 is saved locally. Fixture push rejected"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.sheets.buttons["Commit and Push"].exists)
        app.sheets.buttons["Push"].click()
        XCTAssertTrue(app.sheets.staticTexts["Committed abc1234 and pushed."].waitForExistence(timeout: 10))
        XCTAssertFalse(app.sheets.buttons["Push"].isEnabled)
        app.sheets.buttons["Close"].click()
    }

    @MainActor
    func testNativeEditorSaveCancelDiscardAndHistory() throws {
        let environment = ProcessInfo.processInfo.environment
        guard let base = environment["CRAFT_UI_BACKEND_URL"],
              let path = environment["CRAFT_UI_DATA_DIR"], let socket = environment["CRAFT_UI_PTY_SOCKET"] else {
            throw XCTSkip("Run macos/scripts/test-browser-ui.sh to provide the isolated fixture.")
        }
        let file = URL(fileURLWithPath: path).appendingPathComponent("Editable.swift").standardizedFileURL
        let app = XCUIApplication()
        app.launchArguments = ["--backend-url", base, "--data-dir", path, "--pty-socket", socket]
        app.launch()
        let row = app.outlines["workspace-sidebar"].staticTexts["Editor fixture"].firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 10)); row.click()
        let editor = app.webViews.textViews.firstMatch
        XCTAssertTrue(editor.waitForExistence(timeout: 15), "Saved file tab should load the editor")
        editor.click(); app.typeKey("a", modifierFlags: .command); app.typeText("let saved = true")
        XCTAssertTrue(app.buttons["● Editable.swift"].waitForExistence(timeout: 5))
        app.typeKey("s", modifierFlags: .command)
        let saved = expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: app.buttons["● Editable.swift"])
        wait(for: [saved], timeout: 6)
        editor.click(); app.typeText(" // unsaved")
        app.outlines["workspace-sidebar"].staticTexts["Overview"].click()
        row.click()
        XCTAssertTrue(editor.waitForExistence(timeout: 10))
        XCTAssertEqual(editor.value as? String, "let saved = true // unsaved")
        XCTAssertTrue(app.buttons["● Editable.swift"].exists)
        editor.click()
        app.typeKey("w", modifierFlags: .command)
        XCTAssertTrue(app.sheets.buttons["action-button-2"].waitForExistence(timeout: 5), app.debugDescription)
        app.sheets.buttons["action-button-3"].click()
        XCTAssertTrue(editor.exists)
        app.typeKey("w", modifierFlags: .command)
        XCTAssertTrue(app.sheets.buttons["action-button-2"].waitForExistence(timeout: 5))
        app.sheets.buttons["action-button-2"].click()
        let closed = expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: editor)
        wait(for: [closed], timeout: 5)
        app.menuButtons["History"].click()
        app.menuItems[file.path].click()
        XCTAssertTrue(editor.waitForExistence(timeout: 10), app.debugDescription)
        editor.click()
        XCTAssertEqual(editor.value as? String, "let saved = true")
        XCTAssertFalse(app.webViews.staticTexts["let saved = true // unsaved"].exists)
        app.typeKey("w", modifierFlags: .command)

        app.typeKey("o", modifierFlags: .command)
        XCTAssertTrue(app.sheets.buttons["Cancel"].waitForExistence(timeout: 5))
        app.sheets.buttons["Cancel"].click()
        XCTAssertFalse(editor.exists)
        app.typeKey("o", modifierFlags: .command)
        XCTAssertTrue(app.sheets.buttons["Open"].waitForExistence(timeout: 5))
        app.typeKey("g", modifierFlags: [.command, .shift])
        let filePath = app.textFields["PathTextField"]
        XCTAssertTrue(filePath.waitForExistence(timeout: 5))
        filePath.typeKey("a", modifierFlags: .command)
        filePath.typeText(file.path)
        XCTAssertEqual(filePath.value as? String, file.path, "Select only the isolated editor fixture")
        filePath.typeKey(.return, modifierFlags: [])
        let open = app.sheets.buttons["Open"]
        XCTAssertTrue(open.waitForExistence(timeout: 5))
        let ready = expectation(for: NSPredicate(format: "enabled == true"), evaluatedWith: open)
        wait(for: [ready], timeout: 5)
        open.click()
        XCTAssertTrue(editor.waitForExistence(timeout: 10))
        XCTAssertEqual(editor.value as? String, "let saved = true")
        app.typeKey("w", modifierFlags: .command)
    }

    @MainActor
    func testFocusedWorkingDiffCollapseRefreshAndRecovery() throws {
        let environment = ProcessInfo.processInfo.environment
        guard let base = environment["CRAFT_UI_BACKEND_URL"],
              let path = environment["CRAFT_UI_DATA_DIR"], let socket = environment["CRAFT_UI_PTY_SOCKET"] else {
            throw XCTSkip("Run macos/scripts/test-browser-ui.sh to provide the isolated fixture.")
        }
        let app = XCUIApplication()
        app.launchArguments = ["--backend-url", base, "--data-dir", path, "--pty-socket", socket]
        app.launch()
        let row = app.outlines["workspace-sidebar"].staticTexts["sidebar-2"].firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 10), app.debugDescription)
        row.click()
        app.buttons["Show Changes"].click()
        let file = app.webViews.staticTexts["Sources/Fixture.swift"]
        let renderError = app.staticTexts.matching(NSPredicate(format: "value BEGINSWITH 'Could not'")).firstMatch
        XCTAssertTrue(file.waitForExistence(timeout: 10), "\(renderError.value ?? app.debugDescription)")
        let code = app.webViews.staticTexts.matching(NSPredicate(format: "value CONTAINS 'Native diff ready'")).firstMatch
        XCTAssertTrue(code.exists, app.debugDescription)
        file.click()
        let collapsed = expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: code)
        wait(for: [collapsed], timeout: 5)
        file.click()
        XCTAssertTrue(code.waitForExistence(timeout: 5))
        app.buttons["Refresh Changes"].click()
        XCTAssertTrue(app.staticTexts["Fixture diff unavailable"].waitForExistence(timeout: 5))
        XCTAssertTrue(code.exists) // A failed refresh preserves the last good diff.
        app.buttons["Refresh Changes"].click()
        let recovered = expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: app.staticTexts["Fixture diff unavailable"])
        wait(for: [recovered], timeout: 5)
        XCTAssertTrue(app.webViews.buttons["Untracked.txt"].exists)
        app.webViews.buttons["Open Sources/Fixture.swift at line 1"].click()
        let editor = app.webViews.textViews.firstMatch
        XCTAssertTrue(editor.waitForExistence(timeout: 15))
        editor.click()
        XCTAssertEqual(editor.value as? String, "let message = \"Native diff ready\"\n")
        app.typeKey("w", modifierFlags: .command)
        app.buttons["Show Changes"].click()
        XCTAssertTrue(app.webViews.buttons["Untracked.txt"].waitForExistence(timeout: 10))
        app.webViews.buttons["Untracked.txt"].click()
        XCTAssertTrue(editor.waitForExistence(timeout: 15))
        editor.click()
        XCTAssertEqual(editor.value as? String, "Untracked editor fixture\n")
        app.typeKey("w", modifierFlags: .command)
    }

    @MainActor
    func testNativeCLIStatusAndHookInstallationRecovery() throws {
        let environment = ProcessInfo.processInfo.environment
        guard let base = environment["CRAFT_UI_BACKEND_URL"],
              let path = environment["CRAFT_UI_DATA_DIR"], let socket = environment["CRAFT_UI_PTY_SOCKET"] else {
            throw XCTSkip("Run macos/scripts/test-browser-ui.sh to provide the isolated fixture.")
        }
        let app = XCUIApplication()
        app.launchArguments = ["--backend-url", base, "--data-dir", path, "--pty-socket", socket]
        app.launch()
        XCTAssertTrue(app.outlines["workspace-sidebar"].waitForExistence(timeout: 10))
        app.typeKey(",", modifierFlags: .command)
        app.radioButtons["Integrations"].click()
        XCTAssertTrue(app.staticTexts["Not signed in"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Installed; sign-in status unavailable"].exists)
        app.buttons["hook-toggle-claude"].click()
        XCTAssertTrue(app.staticTexts["Claude Code hooks installed."].waitForExistence(timeout: 5))
        app.buttons["hook-toggle-codex"].click()
        XCTAssertTrue(app.staticTexts["Fixture hook configuration rejected"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.staticTexts["hook-status-claude"].value as? String, "Installed")
        app.buttons["hook-toggle-claude"].click()
        XCTAssertTrue(app.staticTexts["Claude Code hooks removed."].waitForExistence(timeout: 5))
    }

    @MainActor
    func testNativeFontPreferencesAndCodeSizeShortcuts() throws {
        let environment = ProcessInfo.processInfo.environment
        guard let base = environment["CRAFT_UI_BACKEND_URL"],
              let path = environment["CRAFT_UI_DATA_DIR"], let socket = environment["CRAFT_UI_PTY_SOCKET"] else {
            throw XCTSkip("Run macos/scripts/test-browser-ui.sh to provide the isolated fixture.")
        }
        let app = XCUIApplication()
        app.launchArguments = ["--backend-url", base, "--data-dir", path, "--pty-socket", socket]
        app.launch()
        XCTAssertTrue(app.outlines["workspace-sidebar"].waitForExistence(timeout: 10))
        app.typeKey(",", modifierFlags: .command)
        // The app theme is under General; the code font is under Text Editor.
        let theme = app.popUpButtons["settings-theme"]
        XCTAssertTrue(theme.waitForExistence(timeout: 5))
        theme.click(); app.menuItems["Dark"].click()
        XCTAssertEqual(theme.value as? String, "Dark")
        app.radioButtons["Text Editor"].click()
        let family = app.popUpButtons["settings-diff-font-family"]
        XCTAssertTrue(family.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertTrue(app.descendants(matching: .any)["settings-editor-preview"].waitForExistence(timeout: 5))
        family.click(); app.menuItems["Menlo"].click()
        app.menuBarItems["View"].menuItems["Actual Size"].click()
        app.typeKey("=", modifierFlags: .command)
        XCTAssertTrue(app.staticTexts["Code and diffs size: 13"].waitForExistence(timeout: 5), app.debugDescription)
        app.menuBarItems["View"].menuItems["Actual Size"].click()
        XCTAssertTrue(app.staticTexts["Code and diffs size: 12"].waitForExistence(timeout: 5))
        // The terminal font has its own tab now, and the font keys follow whichever tab is up.
        app.radioButtons["Terminal"].click()
        XCTAssertTrue(app.staticTexts["Terminal size: 13"].waitForExistence(timeout: 5), app.debugDescription)
        let smoothing = app.checkBoxes["settings-terminal-thicken"]
        XCTAssertTrue(smoothing.waitForExistence(timeout: 5))
        XCTAssertEqual(smoothing.value as? Int, 1, "Smoothing is on by default, matching the standalone Ghostty app")
        app.typeKey("=", modifierFlags: .command)
        XCTAssertTrue(app.staticTexts["Terminal size: 14"].waitForExistence(timeout: 5))
        app.menuBarItems["View"].menuItems["Actual Size"].click()
        XCTAssertTrue(app.staticTexts["Terminal size: 13"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["Code and diffs size: 12"].exists, "The code font stays on Text Editor")
        app.radioButtons["Text Editor"].click()
        app.typeKey("1", modifierFlags: .command)
        app.typeKey(",", modifierFlags: .command)
        let retained = expectation(for: NSPredicate(format: "value == 'Menlo' OR title == 'Menlo'"), evaluatedWith: family)
        wait(for: [retained], timeout: 5)
        app.radioButtons["General"].click()
        XCTAssertEqual(theme.value as? String, "Dark")
        theme.click(); app.menuItems["Light"].click()
        XCTAssertEqual(theme.value as? String, "Light")
        theme.click(); app.menuItems["System"].click()
        XCTAssertEqual(theme.value as? String, "System")
    }

    @MainActor
    func testNativeResourcesShowAppAndBackendAndResumeAfterNavigation() throws {
        let environment = ProcessInfo.processInfo.environment
        guard let base = environment["CRAFT_UI_BACKEND_URL"],
              let path = environment["CRAFT_UI_DATA_DIR"], let socket = environment["CRAFT_UI_PTY_SOCKET"] else {
            throw XCTSkip("Run macos/scripts/test-browser-ui.sh to provide the isolated fixture.")
        }
        let app = XCUIApplication()
        app.launchArguments = ["--backend-url", base, "--data-dir", path, "--pty-socket", socket]
        app.launch()
        XCTAssertTrue(app.outlines["workspace-sidebar"].waitForExistence(timeout: 10))
        app.typeKey(",", modifierFlags: .command)
        app.radioButtons["System"].click()
        let table = app.outlines["resources-processes"]
        XCTAssertTrue(table.staticTexts["App"].firstMatch.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertTrue(table.staticTexts["Backend"].firstMatch.waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["PTY helper is not running."].waitForExistence(timeout: 5))
        let cpu = app.staticTexts["resources-cpu"]
        let measured = expectation(for: NSPredicate(format: "value CONTAINS %@", "%"), evaluatedWith: cpu)
        wait(for: [measured], timeout: 8)
        app.buttons["resources-refresh"].click()
        app.radioButtons["Text Editor"].click()
        XCTAssertFalse(table.exists)
        app.radioButtons["System"].click()
        XCTAssertTrue(table.staticTexts["Backend"].firstMatch.waitForExistence(timeout: 5))
        XCTAssertFalse(app.webViews.firstMatch.exists)
    }

    @MainActor
    func testNativeWorkflowEditorOrdersSavesAndPreservesDraftAcrossNavigation() throws {
        let environment = ProcessInfo.processInfo.environment
        guard let base = environment["CRAFT_UI_BACKEND_URL"],
              let path = environment["CRAFT_UI_DATA_DIR"], let socket = environment["CRAFT_UI_PTY_SOCKET"] else {
            throw XCTSkip("Run macos/scripts/test-browser-ui.sh to provide the isolated fixture.")
        }
        let app = XCUIApplication()
        app.launchArguments = ["--backend-url", base, "--data-dir", path, "--pty-socket", socket]
        app.launch()
        XCTAssertTrue(app.outlines["workspace-sidebar"].waitForExistence(timeout: 10))
        let project = app.outlines["workspace-sidebar"].staticTexts["Native integration fixture"]
        XCTAssertTrue(project.waitForExistence(timeout: 10)); project.click()
        app.radioButtons["Workflows"].click()
        app.buttons["New Workflow"].click()
        let name = app.textFields["workflow-name"].firstMatch
        XCTAssertTrue(name.waitForExistence(timeout: 5))
        name.click(); app.typeKey("a", modifierFlags: .command); app.typeText("Native review")
        app.popUpButtons["workflow-cli"].click(); app.popUpButtons["workflow-cli"].menuItems["Codex"].click()
        let commands = app.descendants(matching: .any).matching(identifier: "workflow-step-command")
        commands.element(boundBy: 0).click(); app.typeText("/review {url}")
        app.textFields["workflow-step-goal"].firstMatch.click(); app.typeText("Review complete")
        XCTAssertTrue(app.staticTexts["Sample: /review https://example.atlassian.net/browse/REC-123"].waitForExistence(timeout: 5))
        app.buttons["Add Step"].click()
        commands.element(boundBy: 1).click(); app.typeText("/test")
        app.buttons.matching(identifier: "Move Step Up").element(boundBy: 1).click()
        XCTAssertEqual(commands.element(boundBy: 0).value as? String, "/test")
        app.buttons["Save Workflows"].click()
        XCTAssertTrue(app.staticTexts["Workflows saved"].waitForExistence(timeout: 5), app.debugDescription)
        let screenshot = app.screenshot()
        let screenshotURL = FileManager.default.temporaryDirectory.appendingPathComponent("craft-workflows.png")
        try screenshot.pngRepresentation.write(to: screenshotURL)
        print("Workflow screenshot: " + screenshotURL.path)
        let attachment = XCTAttachment(screenshot: screenshot); attachment.lifetime = .keepAlways; add(attachment)
        name.click(); app.typeKey("a", modifierFlags: .command); app.typeText("Unsaved review")
        app.typeKey("1", modifierFlags: .command)
        project.click()
        XCTAssertEqual(name.value as? String, "Unsaved review")
        app.buttons["Revert Workflows"].click()
        XCTAssertEqual(name.value as? String, "Native review")
        app.buttons["Delete Workflow"].click()
        XCTAssertTrue(app.staticTexts["No workflows configured."].waitForExistence(timeout: 5))
        app.buttons["Revert Workflows"].click()
        XCTAssertEqual(name.value as? String, "Native review")
        XCTAssertFalse(app.webViews.firstMatch.exists)
    }

    @MainActor
    func testNativeAutomationTemplateSaveAndDraftRecovery() throws {
        let environment = ProcessInfo.processInfo.environment
        guard let base = environment["CRAFT_UI_BACKEND_URL"],
              let path = environment["CRAFT_UI_DATA_DIR"], let socket = environment["CRAFT_UI_PTY_SOCKET"] else {
            throw XCTSkip("Run macos/scripts/test-browser-ui.sh to provide the isolated fixture.")
        }
        let app = XCUIApplication()
        app.launchArguments = ["--backend-url", base, "--data-dir", path, "--pty-socket", socket]
        app.launch()
        XCTAssertTrue(app.outlines["workspace-sidebar"].waitForExistence(timeout: 10))
        let entry = app.outlines["workspace-sidebar"].staticTexts["Automation"]
        XCTAssertTrue(entry.waitForExistence(timeout: 10)); entry.click()
        XCTAssertTrue(app.descendants(matching: .any)["automation-screen"].firstMatch.waitForExistence(timeout: 5))
        // The project page no longer carries its own automation tab.
        let project = app.outlines["workspace-sidebar"].staticTexts["Native integration fixture"]
        XCTAssertTrue(project.waitForExistence(timeout: 10)); project.click()
        XCTAssertFalse(app.radioButtons["Automation"].exists)
        entry.click()
        app.descendants(matching: .any)["automation-new"].firstMatch.click()
        app.menuItems["Auto-approve trusted authors"].click()
        let name = app.textFields["automation-name"]
        XCTAssertTrue(name.waitForExistence(timeout: 5))
        name.click(); app.typeKey("a", modifierFlags: .command); app.typeText("Approve fixture bots")
        app.buttons["automation-save"].click()
        XCTAssertTrue(app.descendants(matching: .any)["automation-saved"].firstMatch.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertTrue(app.descendants(matching: .any)["automation-list"].firstMatch.staticTexts["Approve fixture bots"].waitForExistence(timeout: 5))
        let screenshot = app.screenshot()
        let screenshotURL = FileManager.default.temporaryDirectory.appendingPathComponent("craft-automation.png")
        try screenshot.pngRepresentation.write(to: screenshotURL)
        print("Automation screenshot: " + screenshotURL.path)
        let attachment = XCTAttachment(screenshot: screenshot); attachment.lifetime = .keepAlways; add(attachment)
        name.click(); app.typeKey("a", modifierFlags: .command); app.typeText("Unsaved name")
        project.click(); entry.click()
        XCTAssertEqual(name.value as? String, "Unsaved name")
        app.buttons["Revert"].click()
        XCTAssertEqual(name.value as? String, "Approve fixture bots")
        XCTAssertFalse(app.webViews.firstMatch.exists)
    }

    @MainActor
    func testNativeWorkflowRunnerRequiresHooksBeforeOpeningTerminal() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let base = environment["CRAFT_UI_BACKEND_URL"],
              let path = environment["CRAFT_UI_DATA_DIR"], let socket = environment["CRAFT_UI_PTY_SOCKET"] else {
            throw XCTSkip("Run macos/scripts/test-browser-ui.sh to provide the isolated fixture.")
        }
        // Seed through the real API so this runner test is independent of editor
        // keyboard focus. The separate editor test covers typing and saving.
        let projectsURL = try XCTUnwrap(URL(string: base + "/api/projects"))
        let (data, _) = try await URLSession.shared.data(from: projectsURL)
        let projects = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [[String: Any]])
        let id = try XCTUnwrap(projects.first(where: { $0["name"] as? String == "Native integration fixture" })?["id"] as? String)
        var request = URLRequest(url: projectsURL.appendingPathComponent(id))
        request.httpMethod = "PUT"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["workflows": [
            ["id": "native-runner", "name": "Native review", "cli": "claude", "steps": [["command": "/review", "title": "Review complete"]]]
        ]])
        let (_, response) = try await URLSession.shared.data(for: request)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        var pageRequest = URLRequest(url: try XCTUnwrap(URL(string: base + "/api/tabs")))
        pageRequest.httpMethod = "POST"
        pageRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        pageRequest.httpBody = try JSONSerialization.data(withJSONObject: [
            "url": base + "/browse/REC-3", "kind": "jira", "title": "Workflow ticket"
        ])
        let (_, pageResponse) = try await URLSession.shared.data(for: pageRequest)
        XCTAssertEqual((pageResponse as? HTTPURLResponse)?.statusCode, 200)
        let app = XCUIApplication()
        app.launchArguments = ["--backend-url", base, "--data-dir", path, "--pty-socket", socket]
        app.launch()
        XCTAssertTrue(app.outlines["workspace-sidebar"].waitForExistence(timeout: 10))
        app.outlines["workspace-sidebar"].staticTexts["sidebar-2"].click()
        XCTAssertTrue(app.buttons["Run Workflow"].waitForExistence(timeout: 5))
        app.buttons["Run Workflow"].click()
        XCTAssertTrue(app.staticTexts["Install Claude hooks in Settings → CLIs before running a workflow."].waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertTrue(app.buttons["Open Terminal"].exists)
        XCTAssertTrue(app.buttons["Run Workflow"].isEnabled)
        XCTAssertFalse(app.webViews.firstMatch.exists)
        let screenshot = app.screenshot()
        try screenshot.pngRepresentation.write(to: FileManager.default.temporaryDirectory.appendingPathComponent("craft-workflow-runner.png"))
        let attachment = XCTAttachment(screenshot: screenshot); attachment.lifetime = .keepAlways; add(attachment)
        app.buttons["Open CLI Settings"].click()
        XCTAssertTrue(app.buttons["hook-toggle-claude"].waitForExistence(timeout: 5))
        let ticket = app.outlines["workspace-sidebar"].staticTexts["Workflow ticket"]
        XCTAssertTrue(ticket.waitForExistence(timeout: 5)); ticket.click()
        XCTAssertTrue(app.buttons["Create Session"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Run Workflow"].waitForExistence(timeout: 5))
        app.buttons["Run Workflow"].click()
        XCTAssertTrue(app.staticTexts["Install Claude hooks in Settings → CLIs before running a workflow."].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Create Session"].exists)
        let pageScreenshot = XCTAttachment(screenshot: app.screenshot())
        pageScreenshot.lifetime = .keepAlways; add(pageScreenshot)
        let (sessionData, _) = try await URLSession.shared.data(from: try XCTUnwrap(URL(string: base + "/api/tasks")))
        let sessions = try XCTUnwrap(JSONSerialization.jsonObject(with: sessionData) as? [[String: Any]])
        XCTAssertFalse(sessions.contains { $0["url"] as? String == base + "/browse/REC-3" })
    }

    @MainActor
    func testNativeActivityToastRoutesAndDismissesWithoutRequestingPermission() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let base = environment["CRAFT_UI_BACKEND_URL"], let path = environment["CRAFT_UI_DATA_DIR"],
              let socket = environment["CRAFT_UI_PTY_SOCKET"] else {
            throw XCTSkip("Run macos/scripts/test-browser-ui.sh with the isolated notification fixture.")
        }
        let app = XCUIApplication()
        app.launchArguments = ["--backend-url", base, "--data-dir", path, "--pty-socket", socket]
        app.launch()
        XCTAssertTrue(app.outlines["workspace-sidebar"].waitForExistence(timeout: 10))
        app.outlines["workspace-sidebar"].staticTexts["Overview"].click()
        XCTAssertTrue(app.staticTexts["My pull requests"].waitForExistence(timeout: 10), app.debugDescription)
        app.activate()
        func emitActivity() async throws {
            var request = URLRequest(url: URL(string: base + "/fixture/activity-notification")!)
            request.httpMethod = "POST"
            let (_, response) = try await URLSession.shared.data(for: request)
            XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        }
        try await emitActivity()
        let toast = app.buttons["activity-toast-open"]
        XCTAssertTrue(toast.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertTrue(toast.label.contains("Sample notification acceptance check"), toast.label)
        toast.click()
        XCTAssertFalse(toast.exists, app.debugDescription)
        XCTAssertTrue(app.buttons["Clear Logs…"].waitForExistence(timeout: 5), app.debugDescription)
        app.outlines["workspace-sidebar"].staticTexts["Overview"].click()
        try await emitActivity()
        XCTAssertTrue(toast.waitForExistence(timeout: 5), app.debugDescription)
        app.buttons["Dismiss activity"].click()
        XCTAssertFalse(toast.exists)
        XCTAssertTrue(app.staticTexts["My pull requests"].exists)
    }

    @MainActor
    func testNativeGitClientPreferencesAndLaunchFailureRecovery() throws {
        let environment = ProcessInfo.processInfo.environment
        guard let base = environment["CRAFT_UI_BACKEND_URL"],
              let path = environment["CRAFT_UI_DATA_DIR"], let socket = environment["CRAFT_UI_PTY_SOCKET"] else {
            throw XCTSkip("Run macos/scripts/test-browser-ui.sh to provide the isolated fixture.")
        }
        let app = XCUIApplication()
        app.launchArguments = ["--backend-url", base, "--data-dir", path, "--pty-socket", socket]
        app.launch()
        XCTAssertTrue(app.outlines["workspace-sidebar"].waitForExistence(timeout: 10))
        app.typeKey(",", modifierFlags: .command)
        app.radioButtons["General"].click()
        let picker = app.popUpButtons["settings-git-client"]
        XCTAssertTrue(picker.waitForExistence(timeout: 5), app.debugDescription)
        picker.click(); app.menuItems["Custom…"].click()
        let command = app.textFields["settings-git-client-command"]
        XCTAssertTrue(command.waitForExistence(timeout: 5))
        command.click(); app.typeKey("a", modifierFlags: .command); app.typeText("tool 'unfinished")
        app.buttons["Save Command"].click()
        XCTAssertTrue(app.staticTexts["Close the quote in the command template."].waitForExistence(timeout: 5))
        command.click(); app.typeKey("a", modifierFlags: .command); app.typeText("/craft-fixture/missing-client {path}")
        app.buttons["Save Command"].click()
        let session = app.outlines["workspace-sidebar"].staticTexts["sidebar-1"].firstMatch
        session.click()
        let launch = app.buttons["Open in Custom Git Client"]
        XCTAssertTrue(launch.waitForExistence(timeout: 5), app.debugDescription)
        launch.click()
        let failure = app.staticTexts["workspace-launch-error"]
        XCTAssertTrue(failure.waitForExistence(timeout: 5))
        XCTAssertEqual(failure.value as? String, "Could not find executable ‘/craft-fixture/missing-client’. Check the custom command and PATH.")
        app.typeKey(",", modifierFlags: .command)
        command.click(); app.typeKey("a", modifierFlags: .command); app.typeText("/usr/bin/true {path}")
        app.buttons["Save Command"].click()
        session.click(); launch.click()
        let recovered = expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: failure)
        wait(for: [recovered], timeout: 5)
        let finished = expectation(for: NSPredicate(format: "enabled == true"), evaluatedWith: launch)
        wait(for: [finished], timeout: 5)
        XCTAssertFalse(failure.exists)
    }

    @MainActor
    func testNativeDiagnosticsInspectSnapshotsAndNavigateBack() throws {
        let environment = ProcessInfo.processInfo.environment
        guard let base = environment["CRAFT_UI_BACKEND_URL"],
              let path = environment["CRAFT_UI_DATA_DIR"], let socket = environment["CRAFT_UI_PTY_SOCKET"] else {
            throw XCTSkip("Run macos/scripts/test-browser-ui.sh to provide the isolated fixture.")
        }
        let app = XCUIApplication()
        app.launchArguments = ["--backend-url", base, "--data-dir", path, "--pty-socket", socket]
        app.launch()
        XCTAssertTrue(app.outlines["workspace-sidebar"].waitForExistence(timeout: 10))
        app.typeKey(",", modifierFlags: .command)
        app.radioButtons["System"].click()
        XCTAssertTrue(app.staticTexts["PR–Jira links: 0"].waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertTrue(app.staticTexts["GitHub CLI · since backend startup"].exists)
        XCTAssertTrue(app.staticTexts["Jira tickets"].exists)
        XCTAssertTrue(app.staticTexts["Sprint board"].exists)
        XCTAssertTrue(app.staticTexts["3 tickets"].firstMatch.exists)
        XCTAssertFalse(app.webViews.firstMatch.exists)
        app.buttons["diagnostics-refresh"].click()
        app.radioButtons["Integrations"].click()
        XCTAssertTrue(app.textFields["settings-poll-interval"].waitForExistence(timeout: 5))
        app.radioButtons["System"].click()
        XCTAssertTrue(app.staticTexts["3 tickets"].firstMatch.waitForExistence(timeout: 5))
    }

    @MainActor
    func testNativeSettingsSaveRevertAndMenuNavigation() throws {
        let environment = ProcessInfo.processInfo.environment
        guard let base = environment["CRAFT_UI_BACKEND_URL"],
              let path = environment["CRAFT_UI_DATA_DIR"], let socket = environment["CRAFT_UI_PTY_SOCKET"] else {
            throw XCTSkip("Run macos/scripts/test-browser-ui.sh to provide the isolated fixture.")
        }
        let app = XCUIApplication()
        app.launchArguments = ["--backend-url", base, "--data-dir", path, "--pty-socket", socket]
        app.launch()
        XCTAssertTrue(app.outlines["workspace-sidebar"].waitForExistence(timeout: 10))
        app.typeKey(",", modifierFlags: .command)
        XCTAssertTrue(app.radioButtons["Integrations"].waitForExistence(timeout: 5))
        app.radioButtons["Integrations"].click()
        let interval = app.textFields["settings-poll-interval"]
        XCTAssertTrue(interval.waitForExistence(timeout: 5))
        interval.click(); app.typeKey("a", modifierFlags: .command); app.typeText("0")
        XCTAssertTrue(app.staticTexts["PR polling must be between 15 and 86400 seconds."].exists)
        XCTAssertFalse(app.buttons["settings-save"].isEnabled)
        interval.click(); app.typeKey("a", modifierFlags: .command); app.typeText("90")
        app.buttons["settings-save"].click()
        XCTAssertTrue(app.staticTexts["Settings saved"].waitForExistence(timeout: 5))
        interval.click(); app.typeKey("a", modifierFlags: .command); app.typeText("120")
        app.typeKey("1", modifierFlags: .command)
        app.typeKey(",", modifierFlags: .command)
        XCTAssertEqual(interval.value as? String, "120")
        app.buttons["settings-revert"].click()
        XCTAssertEqual(interval.value as? String, "90")
        app.radioButtons["Integrations"].click()
        XCTAssertTrue(app.descendants(matching: .any)["settings-default-agent"].firstMatch.waitForExistence(timeout: 5), app.debugDescription)
    }

    @MainActor
    func testNativeJiraTicketsSearchTransitionAndOpen() throws {
        let environment = ProcessInfo.processInfo.environment
        guard let base = environment["CRAFT_UI_BACKEND_URL"],
              let path = environment["CRAFT_UI_DATA_DIR"], let socket = environment["CRAFT_UI_PTY_SOCKET"] else {
            throw XCTSkip("Run macos/scripts/test-browser-ui.sh to provide the isolated fixture.")
        }
        let app = XCUIApplication()
        app.launchArguments = ["--backend-url", base, "--data-dir", path, "--pty-socket", socket]
        app.launch()
        let project = app.outlines["workspace-sidebar"].staticTexts["Native integration fixture"]
        XCTAssertTrue(project.waitForExistence(timeout: 10))
        project.click(); app.radioButtons["Tickets"].click()
        let ticket = app.descendants(matching: .any)["jira-ticket-REC-1"].firstMatch
        XCTAssertTrue(ticket.waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertFalse(app.webViews.firstMatch.exists)
        let status = app.descendants(matching: .any)["jira-status-REC-1"].firstMatch
        XCTAssertTrue(status.waitForExistence(timeout: 5), app.debugDescription)
        status.click(); app.menuItems["Blocked"].click()
        XCTAssertTrue(app.staticTexts["Fixture transition rejected"].waitForExistence(timeout: 5))
        status.click(); app.menuItems["Done"].click()
        let changed = expectation(for: NSPredicate(format: "title == 'Done'"), evaluatedWith: status)
        wait(for: [changed], timeout: 5)
        let query = app.textFields["jira-query"]
        query.click(); app.typeText("rec-2"); app.buttons["Search Jira"].click()
        XCTAssertTrue(app.staticTexts["Search results: rec-2"].waitForExistence(timeout: 5))
        XCTAssertFalse(ticket.exists)
        XCTAssertTrue(app.descendants(matching: .any)["jira-ticket-REC-2"].firstMatch.exists)
        app.buttons["Clear Search"].click()
        XCTAssertTrue(ticket.waitForExistence(timeout: 5))
        status.click(); app.menuItems["To Do"].click()
        let restored = expectation(for: NSPredicate(format: "title == 'To Do'"), evaluatedWith: status)
        wait(for: [restored], timeout: 5)
        ticket.click()
        XCTAssertTrue(app.webViews.staticTexts["Native ticket fixture"].waitForExistence(timeout: 10))
    }

    @MainActor
    func testNativeProjectTicketOpenCancelsAcrossSectionChanges() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let base = environment["CRAFT_UI_BACKEND_URL"],
              let path = environment["CRAFT_UI_DATA_DIR"], let socket = environment["CRAFT_UI_PTY_SOCKET"] else {
            throw XCTSkip("Run macos/scripts/test-browser-ui.sh with its isolated project action fixture.")
        }
        func post(_ route: String) async throws {
            var request = URLRequest(url: URL(string: base + route)!); request.httpMethod = "POST"
            _ = try await URLSession.shared.data(for: request)
        }
        let app = XCUIApplication()
        app.launchArguments = ["--backend-url", base, "--data-dir", path, "--pty-socket", socket]
        app.launch()
        let project = app.outlines["workspace-sidebar"].staticTexts["Native integration fixture"].firstMatch
        XCTAssertTrue(project.waitForExistence(timeout: 10)); project.click()
        app.radioButtons["Tickets"].click()
        let ticket = app.descendants(matching: .any)["jira-ticket-REC-1"].firstMatch
        XCTAssertTrue(ticket.waitForExistence(timeout: 10), app.debugDescription)
        let query = app.textFields["jira-query"]
        query.click(); app.typeText("Keep ticket query")
        try await post("/fixture/arm-ticket-open")
        ticket.click()
        var held = false
        for _ in 0..<100 {
            let (data, _) = try await URLSession.shared.data(from: URL(string: base + "/fixture/project-opens")!)
            held = (try JSONSerialization.jsonObject(with: data) as? [String: Any])?["held"] as? Bool == true
            if held { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertTrue(held)
        app.radioButtons["Sprint Board"].click()
        XCTAssertTrue(app.webViews.staticTexts["Native board integration"].waitForExistence(timeout: 10))
        try await post("/fixture/release-project-open")
        XCTAssertFalse(app.webViews.staticTexts["Native ticket fixture"].exists)
        app.radioButtons["Tickets"].click()
        XCTAssertEqual(query.value as? String, "Keep ticket query")
        app.radioButtons["Sprint Board"].click()
        XCTAssertTrue(app.webViews.links["REC-1"].waitForExistence(timeout: 10))
        app.webViews.links["REC-1"].click()
        XCTAssertTrue(app.webViews.staticTexts["Native ticket fixture"].waitForExistence(timeout: 10))
        let (data, _) = try await URLSession.shared.data(from: URL(string: base + "/fixture/project-opens")!)
        XCTAssertEqual((try JSONSerialization.jsonObject(with: data) as? [String: Any])?["opens"] as? Int, 2)
    }

    @MainActor
    func testWebSprintBoardMovesAssignsAndOpensNativeTicketContext() throws {
        let environment = ProcessInfo.processInfo.environment
        guard let base = environment["CRAFT_UI_BACKEND_URL"],
              let path = environment["CRAFT_UI_DATA_DIR"], let socket = environment["CRAFT_UI_PTY_SOCKET"] else {
            throw XCTSkip("Run macos/scripts/test-browser-ui.sh to provide the isolated fixture.")
        }
        let app = XCUIApplication()
        app.launchArguments = ["--backend-url", base, "--data-dir", path, "--pty-socket", socket]
        app.launch()
        let project = app.outlines["workspace-sidebar"].staticTexts["Native integration fixture"]
        XCTAssertTrue(project.waitForExistence(timeout: 10))
        project.click()
        app.radioButtons["Sprint Board"].click()
        XCTAssertTrue(app.webViews.staticTexts["Native board integration"].waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertTrue(app.webViews.staticTexts["Fixture sprint"].exists)
        app.webViews.buttons["Move REC-1"].click()
        app.webViews.buttons["Blocked"].click()
        XCTAssertTrue(app.webViews.staticTexts["Fixture transition rejected"].waitForExistence(timeout: 5))
        app.webViews.buttons["Move REC-1"].click()
        app.webViews.buttons["Done"].click()
        XCTAssertTrue(app.webViews.staticTexts["REC-1 → Done"].waitForExistence(timeout: 5))
        app.webViews.buttons["Assign"].firstMatch.click()
        app.webViews.buttons["Alice"].click()
        XCTAssertTrue(app.webViews.staticTexts["REC-1 → Alice"].waitForExistence(timeout: 5))
        app.webViews.links["REC-1"].click()
        XCTAssertTrue(app.webViews.staticTexts["Native ticket fixture"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["Create Session"].exists)
        project.click()
        XCTAssertTrue(app.webViews.staticTexts["Native board integration"].waitForExistence(timeout: 10))
    }

    @MainActor
    func testNativeActivityFiltersAndConfirmsClear() throws {
        let environment = ProcessInfo.processInfo.environment
        guard let base = environment["CRAFT_UI_BACKEND_URL"],
              let path = environment["CRAFT_UI_DATA_DIR"], let socket = environment["CRAFT_UI_PTY_SOCKET"] else {
            throw XCTSkip("Run macos/scripts/test-browser-ui.sh to provide the isolated fixture.")
        }
        let app = XCUIApplication()
        app.launchArguments = ["--backend-url", base, "--data-dir", path, "--pty-socket", socket]
        app.launch()
        XCTAssertTrue(app.outlines["workspace-sidebar"].waitForExistence(timeout: 10))
        app.outlines["workspace-sidebar"].staticTexts["Activity"].click()
        XCTAssertTrue(app.staticTexts["Native Activity"].waitForExistence(timeout: 10))
        app.checkBoxes["Errors only"].click()
        XCTAssertTrue(app.staticTexts["Native Failure"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.staticTexts["Native Activity"].exists)
        app.buttons["Clear Logs…"].click()
        XCTAssertTrue(app.sheets.buttons["Clear Logs"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.sheets.staticTexts["Clear Activity?"].exists)
        XCTAssertTrue(app.sheets.staticTexts["This deletes every entry in this category, including entries hidden by search or Errors only."].exists)
        XCTAssertFalse(app.buttons["New Project"].isEnabled)
        app.sheets.buttons["Cancel"].click()
        XCTAssertTrue(app.staticTexts["Native Failure"].exists)
        app.buttons["Clear Logs…"].click()
        app.sheets.buttons["Clear Logs"].click()
        XCTAssertTrue(app.staticTexts["No matching entries."].waitForExistence(timeout: 10))
    }

    @MainActor
    func testNativeProjectCreateEditAndDelete() throws {
        let environment = ProcessInfo.processInfo.environment
        guard let base = environment["CRAFT_UI_BACKEND_URL"],
              let path = environment["CRAFT_UI_DATA_DIR"], let socket = environment["CRAFT_UI_PTY_SOCKET"] else {
            throw XCTSkip("Run macos/scripts/test-browser-ui.sh to provide the isolated fixture.")
        }
        let app = XCUIApplication()
        app.launchArguments = ["--backend-url", base, "--data-dir", path, "--pty-socket", socket]
        app.launch()
        let create = app.buttons["New Project"]
        XCTAssertTrue(create.waitForExistence(timeout: 10))
        let enabled = expectation(for: NSPredicate(format: "enabled == true"), evaluatedWith: create)
        wait(for: [enabled], timeout: 10)
        create.click()
        let name = app.textFields["project-name"]
        XCTAssertTrue(name.waitForExistence(timeout: 5))
        name.click(); app.typeText("Cancelled draft")
        app.sheets.buttons["Cancel"].click()
        let dismissed = expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: app.sheets.firstMatch)
        wait(for: [dismissed], timeout: 5)
        create.click()
        XCTAssertTrue(name.waitForExistence(timeout: 5))
        XCTAssertEqual(name.value as? String, "")
        name.click(); app.typeText("UI project")
        app.sheets.buttons["Save"].click()
        let row = app.outlines["workspace-sidebar"].staticTexts["UI project"]
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        row.click()
        XCTAssertTrue(app.radioButtons["Settings"].waitForExistence(timeout: 5), app.debugDescription)
        app.radioButtons["Settings"].click()
        XCTAssertTrue(name.waitForExistence(timeout: 5))
        name.click(); app.typeKey("a", modifierFlags: .command); app.typeText("Renamed UI project")
        app.buttons["Save Project"].click()
        XCTAssertTrue(app.outlines["workspace-sidebar"].staticTexts["Renamed UI project"].waitForExistence(timeout: 10))
        app.buttons["Delete Project…"].click()
        XCTAssertTrue(app.sheets.buttons["Delete Project"].waitForExistence(timeout: 5))
        app.sheets.buttons["Cancel"].click()
        XCTAssertTrue(app.outlines["workspace-sidebar"].staticTexts["Renamed UI project"].exists)
        app.buttons["Delete Project…"].click()
        app.sheets.buttons["Delete Project"].click()
        let removed = expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: app.outlines["workspace-sidebar"].staticTexts["Renamed UI project"])
        wait(for: [removed], timeout: 10)
    }

    @MainActor
    func testNativeProjectPullRequestCancelsLateNavigationAndRetriesWithReviewMetadata() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let base = environment["CRAFT_UI_BACKEND_URL"],
              let path = environment["CRAFT_UI_DATA_DIR"], let socket = environment["CRAFT_UI_PTY_SOCKET"] else {
            throw XCTSkip("Run macos/scripts/test-browser-ui.sh with its isolated project action fixture.")
        }
        let app = XCUIApplication()
        app.launchArguments = ["--backend-url", base, "--data-dir", path, "--pty-socket", socket]
        app.launch()
        let project = app.outlines["workspace-sidebar"].staticTexts["Native integration fixture"].firstMatch
        XCTAssertTrue(project.waitForExistence(timeout: 10)); project.click()
        let review = app.buttons["dashboard-pr-2"]
        XCTAssertTrue(review.waitForExistence(timeout: 10), app.debugDescription)
        var arm = URLRequest(url: URL(string: base + "/fixture/arm-project-open")!)
        arm.httpMethod = "POST"
        _ = try await URLSession.shared.data(for: arm)
        review.click()
        var held = false
        for _ in 0..<100 {
            let (data, _) = try await URLSession.shared.data(from: URL(string: base + "/fixture/project-opens")!)
            held = (try JSONSerialization.jsonObject(with: data) as? [String: Any])?["held"] as? Bool == true
            if held { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertTrue(held)
        app.buttons["New Project"].click()
        let draft = app.sheets.textFields["project-name"]
        XCTAssertTrue(draft.waitForExistence(timeout: 5))
        draft.click(); app.typeText("Keep pending-open draft")
        var release = URLRequest(url: URL(string: base + "/fixture/release-project-open")!)
        release.httpMethod = "POST"
        _ = try await URLSession.shared.data(for: release)
        XCTAssertEqual(draft.value as? String, "Keep pending-open draft")
        app.sheets.buttons["Cancel"].click()
        XCTAssertTrue(app.textFields["Search project pull requests"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.webViews.staticTexts["Native browser fixture"].exists)
        XCTAssertTrue(review.isEnabled); review.click()
        XCTAssertTrue(app.webViews.staticTexts["Native browser fixture"].waitForExistence(timeout: 10))
        let (tabData, _) = try await URLSession.shared.data(from: URL(string: base + "/api/tabs")!)
        let tabs = (try JSONSerialization.jsonObject(with: tabData) as? [String: Any])?["tabs"] as? [[String: Any]]
        let saved = try XCTUnwrap(tabs?.first { ($0["url"] as? String)?.hasSuffix("?pr=2") == true })
        XCTAssertEqual(saved["category"] as? String, "review")
        let (openData, _) = try await URLSession.shared.data(from: URL(string: base + "/fixture/project-opens")!)
        XCTAssertEqual((try JSONSerialization.jsonObject(with: openData) as? [String: Any])?["opens"] as? Int, 2)
    }

    @MainActor
    func testNativeProjectPullRequestSnapshotsRefreshThroughSSEAndRecover() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let base = environment["CRAFT_UI_BACKEND_URL"],
              let path = environment["CRAFT_UI_DATA_DIR"], let socket = environment["CRAFT_UI_PTY_SOCKET"] else {
            throw XCTSkip("Run macos/scripts/test-browser-ui.sh with its isolated fixture.")
        }
        func post(_ route: String) async throws {
            var request = URLRequest(url: URL(string: base + route)!); request.httpMethod = "POST"
            _ = try await URLSession.shared.data(for: request)
        }
        try await post("/fixture/arm-pr-scopes")
        let app = XCUIApplication()
        app.launchArguments = ["--backend-url", base, "--data-dir", path, "--pty-socket", socket]
        app.launch()
        let project = app.outlines["workspace-sidebar"].staticTexts["Native integration fixture"].firstMatch
        XCTAssertTrue(project.waitForExistence(timeout: 10)); project.click()
        XCTAssertTrue(app.buttons["dashboard-pr-2"].waitForExistence(timeout: 10))
        let picker = app.popUpButtons["project-pr-state"]
        XCTAssertTrue(picker.waitForExistence(timeout: 5), app.debugDescription)
        picker.click(); app.menuItems["Merged"].click()
        XCTAssertTrue(app.staticTexts["Refreshing pull requests…"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["No matching pull requests."].exists)
        picker.click(); app.menuItems["Open"].click()
        try await post("/fixture/release-pr-scope")
        XCTAssertTrue(app.buttons["dashboard-pr-2"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["dashboard-pr-101"].exists)
        picker.click(); app.menuItems["Merged"].click()
        XCTAssertTrue(app.buttons["dashboard-pr-101"].waitForExistence(timeout: 5))
        picker.click(); app.menuItems["All"].click()
        XCTAssertTrue(app.staticTexts["Fixture PR snapshot unavailable"].waitForExistence(timeout: 5))
        app.buttons["Retry pull requests"].click()
        XCTAssertTrue(app.buttons["dashboard-pr-102"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["Fixture PR snapshot unavailable"].exists)
        let (data, _) = try await URLSession.shared.data(from: URL(string: base + "/fixture/pr-scope-calls")!)
        let calls = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(calls["merged"] as? Int, 1); XCTAssertEqual(calls["all"] as? Int, 2)
    }

    @MainActor
    func testNativeDashboardPendingOpenDoesNotInterruptDraft() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let base = environment["CRAFT_UI_BACKEND_URL"],
              let path = environment["CRAFT_UI_DATA_DIR"], let socket = environment["CRAFT_UI_PTY_SOCKET"] else {
            throw XCTSkip("Run macos/scripts/test-browser-ui.sh with its isolated action fixture.")
        }
        func post(_ route: String) async throws {
            var request = URLRequest(url: URL(string: base + route)!); request.httpMethod = "POST"
            _ = try await URLSession.shared.data(for: request)
        }
        let app = XCUIApplication()
        app.launchArguments = ["--backend-url", base, "--data-dir", path, "--pty-socket", socket]
        app.launch()
        XCTAssertTrue(app.scrollViews["native-dashboard"].waitForExistence(timeout: 10))
        let review = app.buttons["dashboard-pr-2"]
        XCTAssertTrue(review.waitForExistence(timeout: 10))
        try await post("/fixture/arm-project-open")
        review.click()
        var held = false
        for _ in 0..<100 {
            let (data, _) = try await URLSession.shared.data(from: URL(string: base + "/fixture/project-opens")!)
            held = (try JSONSerialization.jsonObject(with: data) as? [String: Any])?["held"] as? Bool == true
            if held { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertTrue(held)
        app.buttons["New Project"].click()
        let draft = app.sheets.textFields["project-name"]
        XCTAssertTrue(draft.waitForExistence(timeout: 5)); draft.click(); app.typeText("Keep dashboard draft")
        try await post("/fixture/release-project-open")
        XCTAssertEqual(draft.value as? String, "Keep dashboard draft")
        app.sheets.buttons["Cancel"].click()
        XCTAssertTrue(app.scrollViews["native-dashboard"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.webViews.staticTexts["Native browser fixture"].exists)
        XCTAssertTrue(review.isEnabled); review.click()
        XCTAssertTrue(app.webViews.staticTexts["Native browser fixture"].waitForExistence(timeout: 10))
        let (data, _) = try await URLSession.shared.data(from: URL(string: base + "/fixture/project-opens")!)
        XCTAssertEqual((try JSONSerialization.jsonObject(with: data) as? [String: Any])?["opens"] as? Int, 2)
    }

    @MainActor
    func testNativeDashboardOpensContextPage() throws {
        let environment = ProcessInfo.processInfo.environment
        guard let base = environment["CRAFT_UI_BACKEND_URL"],
              let path = environment["CRAFT_UI_DATA_DIR"], let socket = environment["CRAFT_UI_PTY_SOCKET"] else {
            throw XCTSkip("Run macos/scripts/test-browser-ui.sh to provide the isolated dashboard fixture.")
        }
        let app = XCUIApplication()
        app.launchArguments = ["--backend-url", base, "--data-dir", path, "--pty-socket", socket]
        app.launch()
        XCTAssertTrue(app.outlines["workspace-sidebar"].waitForExistence(timeout: 10))
        app.outlines["workspace-sidebar"].staticTexts["Overview"].click()
        XCTAssertTrue(app.scrollViews["native-dashboard"].waitForExistence(timeout: 10))
        let reviewed = app.buttons["dashboard-pr-2"]
        XCTAssertTrue(reviewed.waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertTrue(app.buttons["dashboard-pr-1"].exists)
        XCTAssertTrue(app.buttons["dashboard-pr-3"].exists)
        reviewed.click()
        XCTAssertTrue(app.webViews.staticTexts["Native browser fixture"].waitForExistence(timeout: 10))
        app.typeKey("1", modifierFlags: .command)
        XCTAssertTrue(app.scrollViews["native-dashboard"].waitForExistence(timeout: 5))
    }

    @MainActor
    private func openBrowserDialogFixture() throws -> (app: XCUIApplication, base: String, path: String) {
        let environment = ProcessInfo.processInfo.environment
        guard let base = environment["CRAFT_UI_BACKEND_URL"], let path = environment["CRAFT_UI_DATA_DIR"],
              let socket = environment["CRAFT_UI_PTY_SOCKET"] else {
            throw XCTSkip("Run macos/scripts/test-browser-ui.sh for the isolated browser fixture.")
        }
        let app = XCUIApplication()
        app.launchArguments = ["--backend-url", base, "--data-dir", path, "--pty-socket", socket]
        app.launch()
        let row = app.outlines["workspace-sidebar"].outlineRows.containing(.staticText, identifier: "sidebar-1").element(boundBy: 0)
        XCTAssertTrue(row.waitForExistence(timeout: 10), app.debugDescription); row.click()
        let address = app.textFields["Page address"]
        XCTAssertTrue(address.waitForExistence(timeout: 10))
        address.click(); address.typeKey("a", modifierFlags: .command); address.typeText(base + "/fixture/dialogs")
        XCTAssertEqual(address.value as? String, base + "/fixture/dialogs", "Address input must finish before navigation")
        address.typeKey(.return, modifierFlags: [])
        XCTAssertTrue(app.webViews.staticTexts["Browser dialog fixture"].waitForExistence(timeout: 10))
        return (app, base, path)
    }

    @MainActor
    func testNativeBrowserDialogDisablesProjectCreation() throws {
        let (app, _, _) = try openBrowserDialogFixture()
        app.webViews.buttons["Prompt fixture"].click()
        let dialog = app.descendants(matching: .any)["browser-dialog"].firstMatch
        XCTAssertTrue(dialog.textFields["browser-dialog-input"].waitForExistence(timeout: 5))
        // The native modal owns accessibility focus. Its paused web content must
        // leave the tree and return when the request completes.
        XCTAssertFalse(app.webViews.firstMatch.exists)
        // Scoped to the toolbar, not to a window title: the window is titled by the active page.
        let newProject = app.toolbars.buttons["New Project"]
        XCTAssertFalse(newProject.isEnabled)
        dialog.buttons["Cancel"].click()
        XCTAssertTrue(app.webViews.staticTexts["Prompt cancelled"].waitForExistence(timeout: 5))
        XCTAssertTrue(newProject.isEnabled)
    }

    @MainActor
    func testNativeBrowserPromptsConfirmationsAndFileUpload() async throws {
        let (app, base, path) = try openBrowserDialogFixture()
        let prompt = app.webViews.buttons["Prompt fixture"]
        prompt.click()
        let dialog = app.descendants(matching: .any)["browser-dialog"].firstMatch
        let input = dialog.textFields["browser-dialog-input"]
        XCTAssertTrue(input.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertEqual(input.value as? String, "Original value")
        input.click(); input.typeKey("a", modifierFlags: .command); input.typeText("Changed value")
        dialog.buttons["OK"].click()
        XCTAssertTrue(app.webViews.staticTexts["Prompt: Changed value"].waitForExistence(timeout: 5))
        prompt.click(); XCTAssertTrue(input.waitForExistence(timeout: 5))
        dialog.buttons["Cancel"].click()
        XCTAssertTrue(app.webViews.staticTexts["Prompt cancelled"].waitForExistence(timeout: 5))
        prompt.click(); XCTAssertTrue(input.waitForExistence(timeout: 5))
        input.click(); input.typeKey("a", modifierFlags: .command); input.typeKey(.delete, modifierFlags: [])
        dialog.buttons["OK"].click()
        XCTAssertTrue(app.webViews.staticTexts["Prompt: empty"].waitForExistence(timeout: 5))
        let confirm = app.webViews.buttons["Confirm fixture"]
        confirm.click(); XCTAssertTrue(dialog.buttons["Cancel"].waitForExistence(timeout: 5))
        dialog.buttons["Cancel"].click()
        XCTAssertTrue(app.webViews.staticTexts["Confirmation cancelled"].waitForExistence(timeout: 5))
        confirm.click(); XCTAssertTrue(dialog.buttons["OK"].waitForExistence(timeout: 5))
        dialog.buttons["OK"].click()
        XCTAssertTrue(app.webViews.staticTexts["Confirmation accepted"].waitForExistence(timeout: 5))
        app.webViews.buttons["Alert fixture"].click()
        XCTAssertTrue(dialog.buttons["OK"].waitForExistence(timeout: 5))
        dialog.buttons["OK"].click()
        XCTAssertTrue(app.webViews.staticTexts["Alert dismissed"].waitForExistence(timeout: 5))
        let upload = app.webViews.buttons["Upload fixture file"]
        XCTAssertTrue(upload.waitForExistence(timeout: 5), app.debugDescription)
        upload.click()
        XCTAssertTrue(app.sheets.buttons["Open"].waitForExistence(timeout: 5), app.debugDescription)
        app.typeKey("g", modifierFlags: [.command, .shift])
        let filePath = app.textFields["PathTextField"]
        XCTAssertTrue(filePath.waitForExistence(timeout: 5))
        filePath.typeKey("a", modifierFlags: .command)
        let fixturePath = URL(fileURLWithPath: path).appendingPathComponent("browser-upload-fixture.txt").path
        filePath.typeText(fixturePath)
        XCTAssertEqual(filePath.value as? String, fixturePath, "Only the generated fixture may be selected")
        filePath.typeKey(.return, modifierFlags: [])
        let open = app.sheets.buttons["Open"]
        XCTAssertTrue(open.waitForExistence(timeout: 5))
        let ready = expectation(for: NSPredicate(format: "enabled == true"), evaluatedWith: open)
        await fulfillment(of: [ready], timeout: 5)
        open.click()
        XCTAssertTrue(app.webViews.staticTexts["Fixture upload received"].waitForExistence(timeout: 10), app.debugDescription)
        upload.click(); XCTAssertTrue(app.sheets.buttons["Cancel"].waitForExistence(timeout: 5))
        app.sheets.buttons["Cancel"].click()
        let (data, _) = try await URLSession.shared.data(from: URL(string: base + "/fixture/browser-upload-count")!)
        let result = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Int])
        XCTAssertEqual(result["uploads"], 1)
        XCTAssertFalse(app.sheets.firstMatch.exists)
    }

    @MainActor
    func testContextPageFindNavigationCloseAndNewSessionSheet() throws {
        let environment = ProcessInfo.processInfo.environment
        guard let base = environment["CRAFT_UI_BACKEND_URL"],
              let path = environment["CRAFT_UI_DATA_DIR"], let socket = environment["CRAFT_UI_PTY_SOCKET"] else {
            throw XCTSkip("Run macos/scripts/test-browser-ui.sh to provide the isolated browser fixture.")
        }
        let directory = URL(fileURLWithPath: path)
        let app = XCUIApplication()
        app.launchArguments = ["--backend-url", base, "--data-dir", directory.path, "--pty-socket", socket]
        app.launch()
        let session = app.outlines["workspace-sidebar"].outlineRows.containing(.staticText, identifier: "sidebar-1").element(boundBy: 0)
        XCTAssertTrue(session.waitForExistence(timeout: 10))
        session.click()
        XCTAssertTrue(app.webViews.firstMatch.waitForExistence(timeout: 10))
        XCTAssertTrue(app.webViews.staticTexts["Native browser fixture"].waitForExistence(timeout: 10))
        app.buttons["Add Page"].click()
        let newAddress = app.textFields["Web address (example.com)"]
        XCTAssertTrue(newAddress.waitForExistence(timeout: 5))
        newAddress.click(); newAddress.typeKey("a", modifierFlags: .command); newAddress.typeText("file:///tmp/private")
        XCTAssertFalse(app.sheets.buttons["Open"].isEnabled)
        newAddress.click(); newAddress.typeKey("a", modifierFlags: .command); newAddress.typeText(base + "/fixture/next?coordinator=1")
        app.sheets.buttons["Open"].click()
        XCTAssertTrue(app.webViews.staticTexts["Next page"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.sheets.firstMatch.exists)
        app.typeKey("w", modifierFlags: .command)
        XCTAssertTrue(app.webViews.staticTexts["Native browser fixture"].waitForExistence(timeout: 5))
        app.typeKey("f", modifierFlags: .command)
        XCTAssertTrue(app.textFields["Find in page"].waitForExistence(timeout: 5))
        app.textFields["Find in page"].click()
        app.textFields["Find in page"].typeText("quokka\n")
        XCTAssertFalse(app.staticTexts["No match"].exists)
        app.buttons["Close Find"].click()
        app.webViews.links["Next page"].click()
        XCTAssertTrue(app.webViews.staticTexts["Next page"].waitForExistence(timeout: 5))
        app.menuBarItems["Go"].menuItems["Back"].click()
        XCTAssertTrue(app.webViews.staticTexts["Native browser fixture"].waitForExistence(timeout: 5))
        app.typeKey("w", modifierFlags: .command)
        XCTAssertTrue(app.buttons["Open Terminal"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.webViews.firstMatch.exists)
        XCTAssertNotEqual(app.state, .notRunning)
        app.typeKey("n", modifierFlags: .command)
        XCTAssertTrue(app.sheets.staticTexts.matching(NSPredicate(format: "value BEGINSWITH 'New session on '")).firstMatch.waitForExistence(timeout: 5))
        XCTAssertFalse(app.sheets.popUpButtons["Project"].exists) // the project is fixed by where the sheet opened
        let sessionBranch = app.textFields["session-branch"]
        XCTAssertTrue(sessionBranch.waitForExistence(timeout: 5), app.debugDescription)
        let editableBranch = expectation(for: NSPredicate(format: "enabled == true"), evaluatedWith: sessionBranch)
        wait(for: [editableBranch], timeout: 5)
        sessionBranch.click(); sessionBranch.typeText("cancelled-session")
        app.buttons["Cancel"].click()
        let dismissed = expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: app.sheets.firstMatch)
        wait(for: [dismissed], timeout: 5)
        app.typeKey("n", modifierFlags: .command)
        XCTAssertTrue(sessionBranch.waitForExistence(timeout: 5))
        XCTAssertEqual(sessionBranch.value as? String, "")
        app.buttons["Cancel"].click()
        app.buttons["Remove Session"].click()
        XCTAssertTrue(app.buttons["Forget Session"].waitForExistence(timeout: 10))
        app.sheets.buttons["Cancel"].click()
        let removalDismissed = expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: app.sheets.firstMatch)
        wait(for: [removalDismissed], timeout: 5)
        XCTAssertTrue(session.exists)
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.appendingPathComponent("sidebar-1").path))
        app.buttons["Remove Session"].click()
        XCTAssertTrue(app.buttons["Forget Session"].waitForExistence(timeout: 10))
        app.buttons["Forget Session"].click()
        let removed = expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: session)
        wait(for: [removed], timeout: 10)
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.appendingPathComponent("sidebar-1").path))
    }

    @MainActor
    func testNativeRealBuildLaunchStopPreservesSessionTerminal() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["CRAFT_UI_REAL_BUILD"] == "1",
              let base = environment["CRAFT_UI_BACKEND_URL"], let path = environment["CRAFT_UI_DATA_DIR"],
              let socket = environment["CRAFT_UI_PTY_SOCKET"], let helper = environment["CRAFT_UI_PTYD_PATH"] else {
            throw XCTSkip("Run the explicit real build acceptance fixture with a simulator and probe template.")
        }
        func state() async throws -> [String: Any] {
            let (data, response) = try await URLSession.shared.data(from: URL(string: base + "/fixture/real-build-state")!)
            XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
            return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        }
        let app = XCUIApplication()
        app.launchArguments = ["--backend-url", base, "--data-dir", path, "--pty-socket", socket, "--ptyd-path", helper]
        app.launch()
        let session = app.outlines["workspace-sidebar"].staticTexts["sidebar-2"].firstMatch
        XCTAssertTrue(session.waitForExistence(timeout: 10)); session.click()
        XCTAssertTrue(app.buttons["Open Terminal"].waitForExistence(timeout: 5)); app.buttons["Open Terminal"].click()
        let originalPID = app.staticTexts["terminal-shell-pid"].firstMatch
        XCTAssertTrue(originalPID.waitForExistence(timeout: 10))
        let before = try await state()
        let original = try XCTUnwrap((before["terms"] as? [[String: Any]])?.first { $0["pairKey"] as? String == "sidebar-2" })
        let shellPID = try XCTUnwrap(original["pid"] as? Int)
        var previousAppPID: Int?
        for attempt in 0..<2 {
            app.activate()
            XCTAssertTrue(app.buttons["Run…"].waitForExistence(timeout: 10)); app.buttons["Run…"].click()
            let run = app.sheets.buttons["Run"]
            let ready = expectation(for: NSPredicate(format: "exists == true AND enabled == true"), evaluatedWith: run)
            await fulfillment(of: [ready], timeout: 100)
            XCTAssertEqual(app.sheets.popUpButtons["build-scheme"].value as? String, "CraftBuildProbe")
            run.click()
            let deadline = ContinuousClock.now + .seconds(240)
            var launched: [String: Any] = [:]
            while ContinuousClock.now < deadline {
                launched = try await state()
                if let pid = launched["pid"] as? Int, pid != previousAppPID, launched["alive"] as? Bool == true { break }
                try await Task.sleep(for: .milliseconds(500))
            }
            let appPID = try XCTUnwrap(launched["pid"] as? Int, "Real build/install/launch did not report readiness")
            XCTAssertNotEqual(appPID, previousAppPID)
            XCTAssertEqual(launched["alive"] as? Bool, true)
            XCTAssertEqual((launched["launches"] as? [Int])?.count, attempt + 1)
            let terms = try XCTUnwrap(launched["terms"] as? [[String: Any]])
            XCTAssertTrue(terms.contains { $0["pairKey"] as? String == "sidebar-2" && $0["pid"] as? Int == shellPID && $0["alive"] as? Bool == true })
            XCTAssertTrue(terms.contains { ($0["pairKey"] as? String)?.hasPrefix("build:") == true && $0["pid"] as? Int != shellPID })
            app.activate() // Simulator opening must not prevent Stop in Craft.
            XCTAssertTrue(app.buttons["Stop Build"].waitForExistence(timeout: 10)); app.buttons["Stop Build"].click()
            let stopped = ContinuousClock.now + .seconds(15)
            var after = try await state()
            while after["alive"] as? Bool == true && ContinuousClock.now < stopped {
                try await Task.sleep(for: .milliseconds(200)); after = try await state()
            }
            XCTAssertEqual(after["alive"] as? Bool, false, "Stop must terminate the launched simulator app, not only its console client")
            XCTAssertTrue((after["terms"] as? [[String: Any]])?.contains { $0["pairKey"] as? String == "sidebar-2" && $0["pid"] as? Int == shellPID && $0["alive"] as? Bool == true } == true)
            previousAppPID = appPID
        }
        app.activate()
        app.typeKey("q", modifierFlags: .command)
        let exited = expectation(for: NSPredicate(format: "state == %d", XCUIApplication.State.notRunning.rawValue), evaluatedWith: app)
        await fulfillment(of: [exited], timeout: 15)
    }

    @MainActor
    func testNativeBuildDestinationRetainsSelectionAndKeepsFailureForRetry() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let base = environment["CRAFT_UI_BACKEND_URL"],
              let path = environment["CRAFT_UI_DATA_DIR"], let socket = environment["CRAFT_UI_PTY_SOCKET"] else {
            throw XCTSkip("Run macos/scripts/test-browser-ui.sh with its isolated build fixture.")
        }
        let app = XCUIApplication()
        app.launchArguments = ["--backend-url", base, "--data-dir", path, "--pty-socket", socket]
        app.launch()
        let session = app.outlines["workspace-sidebar"].staticTexts["sidebar-2"].firstMatch
        XCTAssertTrue(session.waitForExistence(timeout: 10)); session.click()
        let open = app.buttons["Run…"]
        XCTAssertTrue(open.waitForExistence(timeout: 5)); open.click()
        let scheme = app.sheets.popUpButtons["build-scheme"]
        let simulator = app.sheets.popUpButtons["build-simulator"]
        XCTAssertTrue(scheme.waitForExistence(timeout: 5))
        let enabled = expectation(for: NSPredicate(format: "enabled == true"), evaluatedWith: app.sheets.buttons["Run"])
        await fulfillment(of: [enabled], timeout: 10)
        scheme.click(); app.menuItems["Fixture Beta"].click()
        simulator.click(); app.menuItems["Fixture B · Fixture OS"].click()
        app.sheets.buttons["Cancel"].click()
        let dismissed = expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: app.sheets.firstMatch)
        await fulfillment(of: [dismissed], timeout: 5)
        open.click()
        XCTAssertTrue(scheme.waitForExistence(timeout: 5))
        XCTAssertEqual(scheme.value as? String, "Fixture Beta")
        XCTAssertEqual(simulator.value as? String, "Fixture B · Fixture OS")
        app.sheets.buttons["Run"].click()
        XCTAssertTrue(app.sheets.staticTexts["Fixture build preparation rejected"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.sheets.buttons["Run"].isEnabled)
        XCTAssertEqual(scheme.value as? String, "Fixture Beta")
        app.sheets.buttons["Cancel"].click()
        XCTAssertTrue(app.buttons["Open Terminal"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["Stop Build"].exists)
        let (data, _) = try await URLSession.shared.data(from: URL(string: base + "/fixture/build-requests")!)
        let requests = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Int])
        XCTAssertEqual(requests["settings"], 1)
        XCTAssertEqual(requests["schemes"], 2)
        XCTAssertEqual(requests["simulators"], 2)
    }

    @MainActor
    func testWorkspaceCoordinatorPreservesShellUntilConfirmedRestart() throws {
        let environment = ProcessInfo.processInfo.environment
        guard let base = environment["CRAFT_UI_BACKEND_URL"],
              let path = environment["CRAFT_UI_DATA_DIR"], let socket = environment["CRAFT_UI_PTY_SOCKET"],
              let helper = environment["CRAFT_UI_PTYD_PATH"] else {
            throw XCTSkip("Run macos/scripts/test-browser-ui.sh with its isolated fixture and PTY socket.")
        }
        let app = XCUIApplication()
        app.launchArguments = ["--backend-url", base, "--data-dir", path, "--pty-socket", socket, "--ptyd-path", helper]
        app.launch()
        // Command-Q owns this fixture's daemon and shells. Also attempt cleanup
        // if a UI assertion exits the test early.
        defer {
            if app.state != .notRunning {
                app.activate()
                app.typeKey("q", modifierFlags: .command)
            }
        }
        let row = app.outlines["workspace-sidebar"].staticTexts["sidebar-2"]
        XCTAssertTrue(row.waitForExistence(timeout: 10)); row.click()
        XCTAssertTrue(app.buttons["Open Terminal"].waitForExistence(timeout: 5))
        app.buttons["Open Terminal"].click()
        let pid = app.staticTexts["terminal-shell-pid"].firstMatch
        XCTAssertTrue(pid.waitForExistence(timeout: 15), app.debugDescription)
        let original = try XCTUnwrap(pid.value as? String)
        XCTAssertTrue(original.hasPrefix("PID "))
        app.outlines["workspace-sidebar"].staticTexts["Overview"].click()
        row.click()
        XCTAssertTrue(pid.waitForExistence(timeout: 5))
        XCTAssertEqual(pid.value as? String, original)
        let visibility = app.descendants(matching: .any).matching(identifier: "terminal-visibility").firstMatch
        XCTAssertTrue(visibility.waitForExistence(timeout: 5))
        visibility.click()
        XCTAssertTrue(app.staticTexts["terminal-hidden"].waitForExistence(timeout: 5))
        XCTAssertEqual(pid.value as? String, original)
        visibility.click()
        let shown = expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: app.staticTexts["terminal-hidden"])
        wait(for: [shown], timeout: 5)
        // Showing the ready surface returns keyboard focus to this fixture shell.
        let marker = URL(fileURLWithPath: path).appendingPathComponent("terminal-focus.txt")
        let quoted = "'" + marker.path.replacingOccurrences(of: "'", with: "'\\''") + "'"
        app.typeText("printf 'presentation-focus' > " + quoted + "\n")
        let input = expectation(for: NSPredicate { _, _ in FileManager.default.fileExists(atPath: marker.path) }, evaluatedWith: nil)
        wait(for: [input], timeout: 5)
        XCTAssertEqual(try String(contentsOf: marker, encoding: .utf8), "presentation-focus")
        app.buttons["Restart Session"].click()
        XCTAssertTrue(app.sheets.buttons["Cancel"].waitForExistence(timeout: 5), app.debugDescription)
        app.sheets.buttons["Cancel"].click()
        XCTAssertEqual(pid.value as? String, original)
        app.buttons["Restart Session"].click()
        XCTAssertTrue(app.sheets.buttons["Restart Session"].waitForExistence(timeout: 5), app.debugDescription)
        app.sheets.buttons["Restart Session"].click()
        let replaced = expectation(for: NSPredicate(format: "exists == true AND value != %@", original), evaluatedWith: pid)
        wait(for: [replaced], timeout: 15)
        XCTAssertTrue((pid.value as? String)?.hasPrefix("PID ") == true)
        XCTAssertTrue(row.exists)
        app.activate()
        app.typeKey("q", modifierFlags: .command)
        let stopped = expectation(for: NSPredicate(format: "state == %d", XCUIApplication.State.notRunning.rawValue), evaluatedWith: app)
        wait(for: [stopped], timeout: 10)
    }

    override func setUpWithError() throws {
        // Put setup code here. This method is called before the invocation of each test method in the class.

        // In UI tests it is usually best to stop immediately when a failure occurs.
        continueAfterFailure = false

        // In UI tests it’s important to set the initial state - such as interface orientation - required for your tests before they run. The setUp method is a good place to do this.
    }

    override func tearDownWithError() throws {
        // Put teardown code here. This method is called after the invocation of each test method in the class.
    }

    @MainActor
    func testNativeWindowShowsBackendFailure() throws {
        // UI tests must launch the application that they test.
        let app = XCUIApplication()
        app.launchArguments = ["--backend-url", "http://127.0.0.1:1"]
        app.launch()

        // Use XCTAssert and related functions to verify your tests produce the correct results.
        XCTAssertTrue(app.outlines["workspace-sidebar"].waitForExistence(timeout: 5))
        app.outlines["workspace-sidebar"].staticTexts["Overview"].click()
        XCTAssertTrue(app.staticTexts["My pull requests"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Reconnect"].waitForExistence(timeout: 15))
    }

    @MainActor
    func testTrayOpensOfflineAndEscapeDismisses() throws {
        let environment = ProcessInfo.processInfo.environment
        guard let path = environment["CRAFT_UI_DATA_DIR"], let socket = environment["CRAFT_UI_PTY_SOCKET"] else {
            throw XCTSkip("Run macos/scripts/test-browser-ui.sh with isolated storage.")
        }
        let app = XCUIApplication()
        app.launchArguments = ["--backend-url", "http://127.0.0.1:1", "--data-dir", path, "--pty-socket", socket]
        app.launch()
        let status = app.descendants(matching: .any)["craft-status-item"].firstMatch
        XCTAssertTrue(status.waitForExistence(timeout: 5))
        status.click()
        XCTAssertTrue(app.menuItems["Quit Craft"].waitForExistence(timeout: 5)) // the tray ends with Quit Craft
        // Offline there is nothing to review, and no line stands in for the section.
        XCTAssertFalse(app.menuItems["Review requested"].exists)
        XCTAssertFalse(app.menuItems["Nothing to review"].exists)
        XCTAssertFalse(app.menuItems["Connect to load review requests"].exists)
        // The first row picks whose plan the usage block shows.
        XCTAssertTrue(app.descendants(matching: .any)["tray-agent-claude"].firstMatch.exists)
        XCTAssertTrue(app.descendants(matching: .any)["tray-agent-codex"].firstMatch.exists)
        app.typeKey(.escape, modifierFlags: [])
        let dismissed = expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: app.menuItems["Quit Craft"])
        wait(for: [dismissed], timeout: 5)
        XCTAssertTrue(status.exists)
        status.rightClick() // either click opens the menu
        XCTAssertTrue(app.menuItems["Quit Craft"].waitForExistence(timeout: 5))
        app.typeKey(.escape, modifierFlags: [])
    }

    @MainActor
    func testNativeTrayListsOnlyPageTabsAndPreservesOpenDraft() throws {
        let environment = ProcessInfo.processInfo.environment
        guard let base = environment["CRAFT_UI_BACKEND_URL"], let path = environment["CRAFT_UI_DATA_DIR"],
              let socket = environment["CRAFT_UI_PTY_SOCKET"] else {
            throw XCTSkip("Run macos/scripts/test-browser-ui.sh with the isolated fixture.")
        }
        let app = XCUIApplication()
        app.launchArguments = ["--backend-url", base, "--data-dir", path, "--pty-socket", socket]
        app.launch()
        let status = app.descendants(matching: .any)["craft-status-item"].firstMatch
        XCTAssertTrue(status.waitForExistence(timeout: 10))
        status.rightClick()
        XCTAssertTrue(app.menuItems["Quit Craft"].waitForExistence(timeout: 10), app.debugDescription)
        // The tray lists review requests only, never the open pages.
        XCTAssertFalse(app.menuItems["Browser fixture"].exists)
        XCTAssertFalse(app.menuItems["Next page"].exists)
        app.typeKey(.escape, modifierFlags: [])
        app.buttons["New Project"].click()
        let draft = app.sheets.textFields["project-name"]
        XCTAssertTrue(draft.waitForExistence(timeout: 5))
        draft.click(); app.typeText("Keep this tray draft")
        status.rightClick()
        XCTAssertTrue(app.menuItems["Quit Craft"].waitForExistence(timeout: 5), app.debugDescription)
        app.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(draft.waitForExistence(timeout: 5))
        XCTAssertEqual(draft.value as? String, "Keep this tray draft")
        app.sheets.buttons["Cancel"].click()
        // The sidebar bell is today's activity (events-popover.js), not the tray.
        app.buttons["Today's activity"].click()
        XCTAssertTrue(app.descendants(matching: .any)["today-activity-popover"].firstMatch.waitForExistence(timeout: 5))
        XCTAssertFalse(app.menuItems["Quit Craft"].exists)
    }

    @MainActor
    func testNativeMenusNavigateAndCommandQQuits() throws {
        let environment = ProcessInfo.processInfo.environment
        guard let path = environment["CRAFT_UI_DATA_DIR"], let socket = environment["CRAFT_UI_PTY_SOCKET"] else {
            throw XCTSkip("Run macos/scripts/test-browser-ui.sh to provide isolated storage.")
        }
        let app = XCUIApplication()
        app.launchArguments = ["--backend-url", "http://127.0.0.1:1", "--data-dir", path, "--pty-socket", socket]
        app.launch()
        XCTAssertTrue(app.outlines["workspace-sidebar"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.menuBars.menuBarItems["Edit"].waitForExistence(timeout: 5), app.debugDescription)
        app.menuBars.menuBarItems["Craft"].click()
        XCTAssertTrue(app.menuItems["Check for Updates…"].waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertFalse(app.menuItems["Check for Updates…"].isEnabled)
        app.typeKey(.escape, modifierFlags: [])
        app.typeKey("1", modifierFlags: .command)
        XCTAssertTrue(app.staticTexts["My pull requests"].waitForExistence(timeout: 5))
        app.typeKey("q", modifierFlags: .command)
        let stopped = expectation(for: NSPredicate(format: "state == %d", XCUIApplication.State.notRunning.rawValue), evaluatedWith: app)
        wait(for: [stopped], timeout: 10)
    }
}
