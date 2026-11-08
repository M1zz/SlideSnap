//
//  SlideThumb.swift
//  SlideSnap
//
//  장표 썸네일 한 칸. 그림이 있으면 칸을 채워 그리고, 없으면 빈 칸(필요하면 아이콘)을 그린다.
//  크기 · 모서리는 쓰는 쪽이 정한다.
//

import SwiftUI

struct SlideThumb: View {
    let image: UIImage?
    /// 그림이 없을 때 칸 가운데 아이콘. 크기는 쓰는 쪽의 `.font` 를 따른다.
    var placeholderIcon: String? = nil
    var placeholder: Color = Color(.secondarySystemBackground)

    var body: some View {
        if let image {
            Image(uiImage: image)
                .resizable()
                .scaledToFill()
        } else {
            ZStack {
                Rectangle().fill(placeholder)
                if let placeholderIcon {
                    Image(systemName: placeholderIcon)
                        .foregroundStyle(.tertiary)
                }
            }
        }
    }
}
