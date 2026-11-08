//
//  LaunchCameraTests.swift
//  SlideSnapTests
//
//  **찍으러 왔을 때의 판단.** 앱을 열면 무엇부터 보일지, 이어 찍기를 권할 발표가 있는지.
//  캘린더는 설정에서 켜지 않으면 읽지 않으므로(시험 기기에서도 꺼져 있다) 여기서는 늘 없는 것으로 본다.
//

import XCTest
@testable import SlideSnap

final class LaunchCameraTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    func test_바로_촬영과_목록부터는_늘_같다() {
        XCTAssertTrue(LaunchCamera.always.opensCamera(lastCapture: nil, hasPresentations: true, now: now))
        XCTAssertFalse(LaunchCamera.never.opensCamera(lastCapture: now, hasPresentations: true, now: now))
    }

    func test_알아서는_처음_쓰는_사람에게_카메라부터() {
        XCTAssertTrue(LaunchCamera.smart.opensCamera(lastCapture: nil, hasPresentations: false, now: now))
    }

    func test_알아서는_찍던_중이면_카메라_오래됐으면_목록() {
        let recent = now.addingTimeInterval(-30 * 60)
        let old = now.addingTimeInterval(-3 * 60 * 60)
        XCTAssertTrue(LaunchCamera.smart.opensCamera(lastCapture: recent, hasPresentations: true, now: now))
        XCTAssertFalse(LaunchCamera.smart.opensCamera(lastCapture: old, hasPresentations: true, now: now))
    }

    func test_이어_찍기는_하루_안에_찍던_발표만_권한다() {
        XCTAssertEqual(ContinueCapture.candidate(in: [presentation(lastCapture: now.addingTimeInterval(-3 * 60 * 60))], now: now)?.title, "운영체제")
        XCTAssertNil(ContinueCapture.candidate(in: [presentation(lastCapture: now.addingTimeInterval(-25 * 60 * 60))], now: now))
        XCTAssertNil(ContinueCapture.candidate(in: [], now: now))
    }

    private func presentation(lastCapture: Date) -> Presentation {
        let slide = Slide(id: UUID(), createdAt: lastCapture, originalFile: "o", correctedFile: "c", thumbFile: "t",
                          corners: nil, autoDetected: true)
        return Presentation(id: UUID(), title: "운영체제", createdAt: lastCapture, slides: [slide])
    }
}
