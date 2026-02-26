import XCTest
@testable import ClaudeMonitorLib

final class TerminalFocusTests: XCTestCase {

    // MARK: - isSystemMenuItem

    func testIsSystemMenuItem_knownSystemItems() {
        let systemItems = [
            "Minimize", "Minimize All", "Zoom", "Zoom All", "Fill", "Center",
            "Move & Resize", "Full Screen Tile", "Toggle Full Screen",
            "Show/Hide All Terminals", "Show Previous Tab", "Show Next Tab",
            "Move Tab to New Window", "Merge All Windows", "Zoom Split",
            "Select Previous Split", "Select Next Split", "Select Split",
            "Resize Split", "Return To Default Size", "Float on Top",
            "Use as Default", "Bring All to Front", "Arrange in Front",
            "Remove Window from Set", "missing value", ""
        ]
        for item in systemItems {
            XCTAssertTrue(isSystemMenuItem(item), "\"\(item)\" should be a system item")
        }
    }

    func testIsSystemMenuItem_tabLikeItemsAreNotSystem() {
        let tabItems = ["claude:osc_project", "⠂ Claude Code", "tmux attach", "my-folder"]
        for item in tabItems {
            XCTAssertFalse(isSystemMenuItem(item), "\"\(item)\" should NOT be a system item")
        }
    }

    // MARK: - filterTabItems

    func testFilterTabItems_returnsOnlyRealTabs() {
        let menu = [
            "Minimize", "Minimize All", "Zoom",
            "claude:osc_project",
            "Show Previous Tab", "Show Next Tab",
            "⠂ Claude Code",
            "Toggle Full Screen",
            "tmux attach",
            "missing value", ""
        ]
        let tabs = filterTabItems(menu)
        XCTAssertEqual(tabs, ["claude:osc_project", "⠂ Claude Code", "tmux attach"])
    }

    func testFilterTabItems_carriageReturnItems() {
        // CRLF output: system items with \r must still be filtered; tab items trimmed
        let menu = ["Minimize\r", "claude:myproject\r", "Zoom\r"]
        let tabs = filterTabItems(menu)
        XCTAssertEqual(tabs.count, 1)
        XCTAssertEqual(tabs.first, "claude:myproject")
    }

    // MARK: - matchTab

    func testMatchTab_claudePrefix() {
        let tabs = ["claude:osc_project", "⠂ Claude Code", "tmux attach"]
        XCTAssertEqual(matchTab(items: tabs, cwdBasename: "osc_project"), "claude:osc_project")
    }

    func testMatchTab_folderFallback() {
        let tabs = ["⠂ Claude Code", "tmux attach", "my-folder"]
        XCTAssertEqual(matchTab(items: tabs, cwdBasename: "my-folder"), "my-folder")
    }

    func testMatchTab_noMatch() {
        let tabs = ["claude:osc_project", "⠂ Claude Code", "tmux attach"]
        XCTAssertNil(matchTab(items: tabs, cwdBasename: "unknown-folder"))
    }

    func testMatchTab_emptyCWD() {
        let tabs = ["claude:osc_project", "⠂ Claude Code"]
        XCTAssertNil(matchTab(items: tabs, cwdBasename: ""))
    }

    // MARK: - focusGhosttyWithDeps (write-then-click)

    func testFocusGhostty_writesTitleBeforeMenuLookup() {
        var callOrder: [String] = []
        var writtenTTY = ""
        var writtenBasename = ""
        var clicked = ""

        let deps = GhosttyFocusDeps(
            writeTitle: { tty, basename in
                writtenTTY = tty
                writtenBasename = basename
                callOrder.append("write")
            },
            getMenuItems: {
                callOrder.append("menu")
                return ["claude:myproject"]
            },
            clickItem: { name in clicked = name; return true },
            activateApp: { XCTFail("activateApp should not be called on success") },
            waitAfterWrite: 0
        )

        focusGhosttyWithDeps(deps, ghosttyTTY: "ttys005", projectPath: "/Users/filip/myproject")

        XCTAssertEqual(callOrder, ["write", "menu"], "write must happen before menu lookup")
        XCTAssertEqual(writtenTTY, "ttys005")
        XCTAssertEqual(writtenBasename, "myproject")
        XCTAssertEqual(clicked, "claude:myproject")
    }

    func testFocusGhostty_emptyGhosttyTTYSkipsWrite() {
        var writeCalled = false
        let deps = GhosttyFocusDeps(
            writeTitle: { _, _ in writeCalled = true },
            getMenuItems: { ["myproject"] },
            clickItem: { _ in true },
            activateApp: {},
            waitAfterWrite: 0
        )
        focusGhosttyWithDeps(deps, ghosttyTTY: "", projectPath: "/Users/filip/myproject")
        XCTAssertFalse(writeCalled, "writeTitle should NOT be called when ghosttyTTY is empty")
    }

    func testFocusGhostty_noMatch_callsActivateApp() {
        var activateCalled = false
        let deps = GhosttyFocusDeps(
            writeTitle: { _, _ in },
            getMenuItems: { ["⠂ Claude Code", "tmux attach"] },
            clickItem: { _ in return false },
            activateApp: { activateCalled = true },
            waitAfterWrite: 0
        )
        focusGhosttyWithDeps(deps, ghosttyTTY: "ttys005", projectPath: "/Users/filip/unknown-proj")
        XCTAssertTrue(activateCalled)
    }

    func testFocusGhostty_clickFails_callsActivateApp() {
        var activateCalled = false
        let deps = GhosttyFocusDeps(
            writeTitle: { _, _ in },
            getMenuItems: { ["claude:myproject"] },
            clickItem: { _ in return false },   // click returns false = not found
            activateApp: { activateCalled = true },
            waitAfterWrite: 0
        )
        focusGhosttyWithDeps(deps, ghosttyTTY: "ttys005", projectPath: "/Users/filip/myproject")
        XCTAssertTrue(activateCalled)
    }

    func testFocusGhostty_getMenuEmpty_callsActivateApp() {
        var activateCalled = false
        let deps = GhosttyFocusDeps(
            writeTitle: { _, _ in },
            getMenuItems: { [] },
            clickItem: { _ in return true },
            activateApp: { activateCalled = true },
            waitAfterWrite: 0
        )
        focusGhosttyWithDeps(deps, ghosttyTTY: "ttys005", projectPath: "/Users/filip/myproject")
        XCTAssertTrue(activateCalled)
    }
}
