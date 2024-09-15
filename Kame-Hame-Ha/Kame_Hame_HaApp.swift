//
//  Kame_Hame_HaApp.swift
//  Kame-Hame-Ha
//
//  Created by RS on 2024/09/15.
//

import SwiftUI

@main
struct Kame_Hame_HaApp: App {

    @State private var appModel = AppModel()
    @State private var arKitSessionManager = ARKitSessionManager()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(appModel)
        }
        .windowStyle(.plain)

        ImmersiveSpace(id: appModel.immersiveSpaceID) {
            ImmersiveView()
                .environment(appModel)
                .environment(arKitSessionManager)
                .onAppear {
                    appModel.immersiveSpaceState = .open
                }
                .onDisappear {
                    appModel.immersiveSpaceState = .closed
                }
        }
        .immersionStyle(selection: .constant(.mixed), in: .mixed)
     }
}
