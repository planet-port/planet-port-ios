import XCTest

/// 行星详情页删除入口的 UI 回归：
/// Form 内按钮行布局与 confirmationDialog 锚定随系统版本反复变化
/// （iOS 26/27.0/27.2 各不相同），删除行改为纯视图 + 手势、确认框
/// 改走 UIKit（见 ConfirmDialog），本测试守住这条链路不再回退。
final class PlanetDeleteUITests: XCTestCase {
    func testNavigateToPlanetDeleteRow() {
        let app = XCUIApplication()
        app.launch()
        sleep(3)
        // 点行星卡片上部（图标区）：卡片底部的节点 ID 行是点击复制热区，
        // 点中部会误触复制而非进详情页
        let settingsMarker = app.staticTexts["World ID"].firstMatch
        let coord = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.22))
        for _ in 0..<5 {
            coord.tap()
            if settingsMarker.waitForExistence(timeout: 3) { break }
            sleep(1)
        }
        XCTAssertTrue(settingsMarker.exists, "点行星卡片应进入详情页")
        // 滑到底部删除区：各版本行高不一，滑动直至删除行出现
        let deleteRow = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label == %@", "删除此行星")).firstMatch
        for _ in 0..<5 where !deleteRow.exists {
            app.swipeUp()
            sleep(1)
        }
        XCTAssertTrue(deleteRow.waitForExistence(timeout: 5), "底部应存在删除入口")
        // TEMP-DIAG
        print("=====AXTREE=====")
        print(app.debugDescription)
        print("=====END=====")
        deleteRow.tap()
        // UIKit 确认框弹出：action sheet 带确认（UIAlertAction 暴露的是 label；
        // 取消按钮在部分版本查不到，按底部固定位置坐标点）
        let confirm = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "网络和卫星")).firstMatch
        XCTAssertTrue(confirm.waitForExistence(timeout: 5), "点删除应弹出确认框")
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.93)).tap()
    }
}
