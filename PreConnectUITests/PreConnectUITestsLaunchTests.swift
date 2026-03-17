//
//  PreConnectUITestsLaunchTests.swift
//  PreConnect 的启动界面测试
//  Created by Prelina Montelli
//

import XCTest

final class PreConnectUITestsLaunchTests: XCTestCase {

    // MARK: - 测试配置

    override class var runsForEachTargetApplicationUIConfiguration: Bool {
        true
    }

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    // MARK: - 启动测试

    @MainActor
    func testLaunch() throws {
        let app = XCUIApplication()
        app.launch()

        // Insert steps here to perform after app launch but before taking a screenshot,
        // such as logging into a test account or navigating somewhere in the app

        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "Launch Screen"
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
