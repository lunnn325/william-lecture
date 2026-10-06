import SwiftUI
import UIKit

extension Color {
    static let williamAccent = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 0.76, green: 0.83, blue: 0.93, alpha: 1)
            : UIColor(red: 0.14, green: 0.20, blue: 0.28, alpha: 1)
    })
    static let williamSecondary = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 0.66, green: 0.68, blue: 0.70, alpha: 1)
            : UIColor(red: 0.40, green: 0.42, blue: 0.44, alpha: 1)
    })
    static let williamWarning = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 1, green: 0.72, blue: 0.43, alpha: 1)
            : UIColor(red: 0.55, green: 0.23, blue: 0, alpha: 1)
    })
}
