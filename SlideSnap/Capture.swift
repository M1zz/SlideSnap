//
//  Capture.swift
//  SlideSnap
//
//  장표는 iPhone · iPad 로 찍는다. Mac · Vision Pro 는 iCloud 로 넘어온 장표로 공부하는 곳이다.
//  카메라 코드(CameraCaptureView · CameraController)는 `#if os(iOS) && !targetEnvironment(macCatalyst)` 안에만 있고,
//  화면이 '찍기' 단추를 그릴지는 이 값 하나로 정한다.
//

import Foundation

enum Capture {
    #if os(iOS) && !targetEnvironment(macCatalyst)
    static let isAvailable = true
    #else
    static let isAvailable = false
    #endif
}

/// 다시 찍을 장표. 카메라를 `fullScreenCover(item:)` 로 띄울 때 쓴다.
struct RetakeTarget: Identifiable, Hashable {
    let id: UUID
    /// 화면에 적을 장표 번호(1부터)
    let number: Int
}
