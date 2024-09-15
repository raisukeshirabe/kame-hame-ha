//
//  ImmersiveView.swift
//  Kame-Hame-Ha
//
//  Created by RS on 2024/09/15.
//

import SwiftUI
import RealityKit
import RealityKitContent

struct ImmersiveView: View {
    @Environment(ARKitSessionManager.self) var arkitSession
    @State private var subscription: EventSubscription?

    var body: some View {
        RealityView { content in
            content.add(contentEntity)

            // 衝突判定
            subscription = content.subscribe(to: CollisionEvents.Began.self) { collisionEvent in
                // かめはめ波とシーンが衝突したら消す
                if collisionEvent.entityA.name == "Kamehameha" && collisionEvent.entityB.name == "SceneReconstuction" {

                    Task {
                        let hitSound = try await AudioFileResource(named: "CriticalHit.mp3")
                        let audioController = contentEntity.prepareAudio(hitSound)
                        audioController.gain = 15
                        audioController.play()
                    }

                    collisionEvent.entityA.removeFromParent()
                }
            }
#if targetEnvironment(simulator)
            contentEntity.components.set(InputTargetComponent(allowedInputTypes: .indirect))
            contentEntity.components.set(CollisionComponent(shapes: [ShapeResource.generateSphere(radius: 20)], isStatic: true))
#endif
        }
#if targetEnvironment(simulator)
        .gesture(
            SpatialTapGesture(count: 1)
                .targetedToAnyEntity()
                .onEnded { event in
                    let kamehameha = arkitSession.generateKamehameha()
                    kamehameha.transform.scale = SIMD3(10, 10, 10)
                    kamehameha.position.y = 1.2

                    let device = ModelEntity()
                    device.name = "Device"
                    device.components.set(CollisionComponent(
                        shapes: [.generateSphere(radius: 0.5)],
                        mode: .default
                    ))

                    device.addChild(kamehameha)
                    contentEntity.addChild(device)

                    let forceDirection = device.transform.rotation.act(SIMD3(0, 0, -1))

                    kamehameha.addForce(forceDirection * 100000, relativeTo: nil)
                }
        )
#endif
        .task {
            await arkitSession.monitorSessionEvents()
        }
        .task {
            await arkitSession.runSession()
        }
        .task {
            await arkitSession.processReconstructionUpdates()
        }
        .task {
            await arkitSession.processHandUpdates()
        }
    }
}

#Preview(immersionStyle: .mixed) {
    ImmersiveView()
        .environment(AppModel())
}
