//
//  ContentView.swift
//  Kame-Hame-Ha
//
//  Created by RS on 2024/09/15.
//

import SwiftUI
import RealityKit
import RealityKitContent

struct ContentView: View {
    @Environment(AppModel.self) private var appModel

    var body: some View {
        VStack(spacing: 10) {
            if appModel.immersiveSpaceState == .closed {
                Image("SplashScreen")
                    .resizable()
                    .frame(width: 500, height: 100)
                    .cornerRadius(16.0)
                    .accessibilityHidden(true)
                    .padding(.bottom, 30)
            } else {
                Color.clear
                    .frame(width: 500, height: 0)
            }
            ToggleImmersiveSpaceButton()
        }
        .padding(.all, 40)
        .glassBackgroundEffect(
            in: RoundedRectangle(
                cornerRadius: 32,
                style: .continuous
            )
        )
    }
}

#Preview(windowStyle: .automatic) {
    ContentView()
        .environment(AppModel())
}
