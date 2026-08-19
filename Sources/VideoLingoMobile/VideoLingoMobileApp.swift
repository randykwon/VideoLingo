import SwiftUI

@main
struct VideoLingoMobileApp: App {
    @State private var library = MobileVideoLibrary()

    var body: some Scene {
        WindowGroup {
            MobileContentView()
                .environment(library)
        }
    }
}
