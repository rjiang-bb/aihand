import XCTest
@testable import AiHand

final class SessionsPanelEscapeTests: XCTestCase {
    func testPriorityOrder() {
        XCTAssertEqual(
            SessionsPanelEscape.action(
                workspacePickerExpanded: true,
                gitPickerExpanded: true,
                editingQueued: true,
                chatOpen: true
            ),
            .dismissWorkspacePicker
        )
        XCTAssertEqual(
            SessionsPanelEscape.action(
                workspacePickerExpanded: false,
                gitPickerExpanded: true,
                editingQueued: true,
                chatOpen: true
            ),
            .dismissGitPicker
        )
        XCTAssertEqual(
            SessionsPanelEscape.action(
                workspacePickerExpanded: false,
                gitPickerExpanded: false,
                editingQueued: true,
                chatOpen: true
            ),
            .cancelQueueEdit,
            "Esc while editing a queued follow-up must not close the chat"
        )
        XCTAssertEqual(
            SessionsPanelEscape.action(
                workspacePickerExpanded: false,
                gitPickerExpanded: false,
                editingQueued: false,
                chatOpen: true
            ),
            .closeChat
        )
        XCTAssertEqual(
            SessionsPanelEscape.action(
                workspacePickerExpanded: false,
                gitPickerExpanded: false,
                editingQueued: false,
                chatOpen: false
            ),
            .hidePanel
        )
    }
}
