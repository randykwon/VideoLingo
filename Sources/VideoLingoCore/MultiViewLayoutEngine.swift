import Foundation

/// 영상 감상 모드 멀티 뷰에서 1~8개 타일을 배치하는 프리셋입니다.
public enum MultiViewLayoutPreset: String, Codable, Sendable, CaseIterable, Identifiable {
    case autoGrid       // 1→1×1, 2→2×1, 3~4→2×2, 5~6→3×2, 7~8→4×2
    case dualSpotlight  // 2개 큰 화면 나란히(상단 72% 또는 2개일 때 100%) + 나머지 하단 보조 스트립
    case spotlight      // 1개 큰 메인 화면 + 나머지 보조 화면
    case twoColumns     // 2열 균등 배치
    case threeColumns   // 3열 균등 배치
    case fourColumns    // 4열 균등 배치
    case verticalStack  // 위아래 세로 분할
    case cascade        // 겹쳐진 계단식 자유 배치

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .autoGrid: "자동 격자"
        case .dualSpotlight: "2개 크게 보기"
        case .spotlight: "메인 강조"
        case .twoColumns: "2열"
        case .threeColumns: "3열"
        case .fourColumns: "4열"
        case .verticalStack: "세로 분할"
        case .cascade: "계단식"
        }
    }

    public var symbol: String {
        switch self {
        case .autoGrid: "rectangle.grid.2x2"
        case .dualSpotlight: "rectangle.split.2x1"
        case .spotlight: "rectangle.leadinghalf.inset.filled"
        case .twoColumns: "square.grid.2x2"
        case .threeColumns: "rectangle.grid.3x2"
        case .fourColumns: "square.grid.4x3.fill"
        case .verticalStack: "rectangle.split.1x2"
        case .cascade: "square.on.square"
        }
    }
}

/// 캔버스 크기(0...1) 기준의 정규화 타일 사각형입니다. (좌상단 원점)
public struct MultiViewNormalizedRect: Codable, Sendable, Equatable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    public static let full = MultiViewNormalizedRect(x: 0, y: 0, width: 1, height: 1)

    /// 캔버스 범위(0...1)와 최소 크기를 벗어나지 않도록 좌표를 보정합니다.
    public func clamped(minWidth: Double = 0.16, minHeight: Double = 0.16) -> MultiViewNormalizedRect {
        let clampedW = min(1.0, max(minWidth, width))
        let clampedH = min(1.0, max(minHeight, height))
        let clampedX = min(1.0 - clampedW, max(0.0, x))
        let clampedY = min(1.0 - clampedH, max(0.0, y))
        return MultiViewNormalizedRect(x: clampedX, y: clampedY, width: clampedW, height: clampedH)
    }

    /// 이동 델타(정규화 좌표)를 적용하고 캔버스 경계 안으로 보정합니다.
    public func moved(dx: Double, dy: Double) -> MultiViewNormalizedRect {
        MultiViewNormalizedRect(x: x + dx, y: y + dy, width: width, height: height).clamped()
    }

    /// 크기 조절 델타(정규화 좌표)를 적용하고 캔버스 경계 안으로 보정합니다.
    public func resized(dw: Double, dh: Double, minWidth: Double = 0.16, minHeight: Double = 0.16) -> MultiViewNormalizedRect {
        let maxW = max(minWidth, 1.0 - x)
        let maxH = max(minHeight, 1.0 - y)
        let nextW = min(maxW, max(minWidth, width + dw))
        let nextH = min(maxH, max(minHeight, height + dh))
        return MultiViewNormalizedRect(x: x, y: y, width: nextW, height: nextH)
    }
}

/// 1~8개 멀티 뷰 타일의 정규화 배치 좌표를 계산하는 순수 레이아웃 엔진입니다.
public enum MultiViewLayoutEngine {
    public static let maximumTileCount = 8

    public static func rects(
        for count: Int,
        preset: MultiViewLayoutPreset,
        gap: Double = 0.008
    ) -> [MultiViewNormalizedRect] {
        let clampedCount = min(maximumTileCount, max(0, count))
        guard clampedCount > 0 else { return [] }
        if clampedCount == 1 {
            return [MultiViewNormalizedRect(x: gap, y: gap, width: 1 - gap * 2, height: 1 - gap * 2)]
        }

        switch preset {
        case .autoGrid:
            let cols = recommendedColumns(for: clampedCount)
            return gridRects(count: clampedCount, columns: cols, gap: gap)

        case .dualSpotlight:
            return dualSpotlightRects(count: clampedCount, gap: gap)

        case .twoColumns:
            return gridRects(count: clampedCount, columns: min(2, clampedCount), gap: gap)

        case .threeColumns:
            return gridRects(count: clampedCount, columns: min(3, clampedCount), gap: gap)

        case .fourColumns:
            return gridRects(count: clampedCount, columns: min(4, clampedCount), gap: gap)

        case .verticalStack:
            return gridRects(count: clampedCount, columns: 1, gap: gap)

        case .spotlight:
            return spotlightRects(count: clampedCount, gap: gap)

        case .cascade:
            return cascadeRects(count: clampedCount)
        }
    }

    public static func recommendedColumns(for count: Int) -> Int {
        switch count {
        case ...1: 1
        case 2: 2
        case 3...4: 2
        case 5...6: 3
        default: 4
        }
    }

    private static func gridRects(count: Int, columns: Int, gap: Double) -> [MultiViewNormalizedRect] {
        let cols = max(1, columns)
        let rows = Int(ceil(Double(count) / Double(cols)))
        let cellH = (1.0 - gap * Double(rows + 1)) / Double(rows)
        var result: [MultiViewNormalizedRect] = []
        result.reserveCapacity(count)

        for idx in 0..<count {
            let row = idx / cols
            let col = idx % cols
            let itemsInRow = (row == rows - 1) ? (count - row * cols) : cols
            // 마지막 줄에 빈 칸이 생기면 해당 줄 타일들이 가로 폭을 깔끔하게 채웁니다.
            let rowCols = max(1, itemsInRow)
            let cellW = (1.0 - gap * Double(rowCols + 1)) / Double(rowCols)
            let x = gap + Double(col) * (cellW + gap)
            let y = gap + Double(row) * (cellH + gap)
            result.append(MultiViewNormalizedRect(x: x, y: y, width: cellW, height: cellH).clamped(minWidth: 0.08, minHeight: 0.08))
        }
        return result
    }

    /// 1번·2번 타일을 좌우로 크게 나란히 배치하고, 3개 이상일 때는 나머지를 하단 스트립에 배치합니다.
    private static func dualSpotlightRects(count: Int, gap: Double) -> [MultiViewNormalizedRect] {
        let topW = (1.0 - gap * 3) / 2.0
        if count <= 2 {
            let fullH = 1.0 - gap * 2
            return [
                MultiViewNormalizedRect(x: gap, y: gap, width: topW, height: fullH),
                MultiViewNormalizedRect(x: gap * 2 + topW, y: gap, width: topW, height: fullH)
            ]
        }
        // 3~8개: 상단 72%에 2개 큰 화면 나란히 + 하단 28%에 나머지 1~6개 보조 스트립
        let topH = 0.72 - gap * 1.5
        let bottomY = gap * 2 + topH
        let bottomH = 1.0 - bottomY - gap
        let bottomCount = count - 2
        let bottomW = (1.0 - gap * Double(bottomCount + 1)) / Double(bottomCount)

        var rects = [
            MultiViewNormalizedRect(x: gap, y: gap, width: topW, height: topH),
            MultiViewNormalizedRect(x: gap * 2 + topW, y: gap, width: topW, height: topH)
        ]
        for i in 0..<bottomCount {
            let x = gap + Double(i) * (bottomW + gap)
            rects.append(
                MultiViewNormalizedRect(x: x, y: bottomY, width: bottomW, height: bottomH)
                    .clamped(minWidth: 0.08, minHeight: 0.08)
            )
        }
        return rects
    }

    /// 1번 타일을 큰 메인 화면으로 배치하고, 나머지 1~7개를 우측(또는 우측+하단)에 배치합니다.
    private static func spotlightRects(count: Int, gap: Double) -> [MultiViewNormalizedRect] {
        if count == 2 {
            let mainW = 0.68 - gap * 1.5
            let sideW = 1.0 - mainW - gap * 3
            let fullH = 1.0 - gap * 2
            return [
                MultiViewNormalizedRect(x: gap, y: gap, width: mainW, height: fullH),
                MultiViewNormalizedRect(x: gap * 2 + mainW, y: gap, width: sideW, height: fullH)
            ]
        }
        if count <= 5 {
            // 왼쪽 68% 큰 메인 + 오른쪽 32% 세로 스택 (1+2 ~ 1+4)
            let mainW = 0.68 - gap * 1.5
            let sideW = 1.0 - mainW - gap * 3
            let sideCount = count - 1
            let sideH = (1.0 - gap * Double(sideCount + 1)) / Double(sideCount)
            var rects = [MultiViewNormalizedRect(x: gap, y: gap, width: mainW, height: 1.0 - gap * 2)]
            for i in 0..<sideCount {
                let y = gap + Double(i) * (sideH + gap)
                rects.append(MultiViewNormalizedRect(x: gap * 2 + mainW, y: y, width: sideW, height: sideH))
            }
            return rects
        } else {
            // 6~8개: 좌상단 메인(66%×68%) + 우측 3개 + 하단 2~4개
            let mainW = 0.66 - gap * 1.5
            let mainH = 0.66 - gap * 1.5
            let sideW = 1.0 - mainW - gap * 3
            let sideCount = 3
            let sideH = (mainH - gap * Double(sideCount - 1)) / Double(sideCount)
            var rects = [MultiViewNormalizedRect(x: gap, y: gap, width: mainW, height: mainH)]
            for i in 0..<sideCount {
                let y = gap + Double(i) * (sideH + gap)
                rects.append(MultiViewNormalizedRect(x: gap * 2 + mainW, y: y, width: sideW, height: sideH))
            }
            let bottomCount = count - 1 - sideCount
            let bottomY = gap * 2 + mainH
            let bottomH = 1.0 - bottomY - gap
            let bottomW = (1.0 - gap * Double(bottomCount + 1)) / Double(bottomCount)
            for i in 0..<bottomCount {
                let x = gap + Double(i) * (bottomW + gap)
                rects.append(MultiViewNormalizedRect(x: x, y: bottomY, width: bottomW, height: bottomH))
            }
            return rects
        }
    }

    private static func cascadeRects(count: Int) -> [MultiViewNormalizedRect] {
        let w = 0.56
        let h = 0.56
        let maxStepX = (1.0 - w - 0.04) / Double(max(1, count - 1))
        let maxStepY = (1.0 - h - 0.04) / Double(max(1, count - 1))
        return (0..<count).map { idx in
            MultiViewNormalizedRect(
                x: 0.02 + Double(idx) * maxStepX,
                y: 0.02 + Double(idx) * maxStepY,
                width: w,
                height: h
            ).clamped()
        }
    }
}
