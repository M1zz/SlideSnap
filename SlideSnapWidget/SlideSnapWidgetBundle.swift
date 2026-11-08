//
//  SlideSnapWidgetBundle.swift
//  SlideSnapWidget
//

import WidgetKit
import SwiftUI

@main
struct SlideSnapWidgetBundle: WidgetBundle {
    var body: some Widget {
        SlideSnapCameraWidget()
        if #available(iOS 18.0, *) { SlideSnapCaptureControl() }
    }
}
