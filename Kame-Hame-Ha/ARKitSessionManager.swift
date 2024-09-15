import ARKit
import RealityKit
import SwiftUI
import RealityKitContent

@Observable
class ARKitSessionManager {
    let session = ARKitSession()
    let sceneReconstruction = SceneReconstructionProvider()
    let handTracking = HandTrackingProvider()

    // かめはめ波用の新しいプロパティ
    var kamehamehaEntity: ModelEntity?
    let kamehamehaDistanceThreshold: Float = 0.1 // 手首の距離のしきい値を1cmに設定

    // かめはめ波のParticleEntity
    var auraEntity: Entity?

    init() {
        Task {
            self.auraEntity = try? await Entity(named: "Aura", in: realityKitContentBundle)
            if self.auraEntity == nil {
                print("Failed to load Aura entity")
            }
        }
    }


    var dataProvidersAreSupported: Bool {
        SceneReconstructionProvider.isSupported && HandTrackingProvider.isSupported
    }

    // SceneReconstruction周り
    private var sceneMeshEntities = [UUID: ModelEntity]()
    // HandTracking周り
    // 左右の手のEntity。衝突時にEntityを削除するため
    var leftHandEntity = Entity()
    var rightHandEntity = Entity()
    // 左右の手に追従する霊弾のEntity。霊弾への参照を保持するため
    var leftHandSoulBullet: ModelEntity?
    var rightHandSoulBullet: ModelEntity?

    var errorState = false

    func setupContentEntity() {
        contentEntity.addChild(leftHandEntity)
        contentEntity.addChild(rightHandEntity)
    }

    func runSession() async {
        if dataProvidersAreSupported {
            do {
                try await session.run([sceneReconstruction, handTracking])
                setupContentEntity()
                print("Run session.")
            } catch {
                assertionFailure("Failed to run session: \(error)")
            }
        }
    }

    // ARKitSessionの権限周り
    func monitorSessionEvents() async {
        for await event in session.events {
            switch event {
            case .authorizationChanged(type: _, status: let status):
                print("Authorization changed to: \(status)")

                if status == .denied {
                    errorState = true
                }
            case .dataProviderStateChanged(dataProviders: let providers, newState: let state, error: let error):
                print("Data provider changed: \(providers), \(state)")
                if let error {
                    print("Data provider reached an error state: \(error)")
                    errorState = true
                }
            @unknown default:
                fatalError("Unhandled new event type \(event)")
            }
        }
    }

    // SceneReconstuctionのAnchorでMeshEntityやCollisionを更新
    @MainActor
    func processReconstructionUpdates() async {
        for await update in sceneReconstruction.anchorUpdates {
            let meshAnchor = update.anchor

            guard let shape = try? await ShapeResource.generateStaticMesh(from: meshAnchor) else { continue }
            switch update.event {
            case .added:
                let entity =  try! await generateModelEntity(geometry: meshAnchor.geometry)
                entity.name = "SceneReconstuction"

                entity.transform = Transform(matrix: meshAnchor.originFromAnchorTransform)
                entity.collision = CollisionComponent(shapes: [shape], isStatic: true)
                entity.physicsBody = PhysicsBodyComponent(mode: .static)

                sceneMeshEntities[meshAnchor.id] = entity
                contentEntity.addChild(entity)
            case .updated:
                guard let entity = sceneMeshEntities[meshAnchor.id] else { continue }

                entity.transform = Transform(matrix: meshAnchor.originFromAnchorTransform)
                entity.collision = CollisionComponent(shapes: [shape], isStatic: true)
                entity.physicsBody = PhysicsBodyComponent(mode: .static)

                sceneMeshEntities[meshAnchor.id] = entity
                contentEntity.addChild(entity)
            case .removed:
                sceneMeshEntities[meshAnchor.id]?.removeFromParent()
                sceneMeshEntities.removeValue(forKey: meshAnchor.id)
            }
        }
    }

    @MainActor func generateModelEntity(geometry: MeshAnchor.Geometry) async throws -> ModelEntity {
        // generate mesh
        var desc = MeshDescriptor()
        let posValues = geometry.vertices.asSIMD3(ofType: Float.self)
        desc.positions = .init(posValues)
        let normalValues = geometry.normals.asSIMD3(ofType: Float.self)
        desc.normals = .init(normalValues)
        do {
            desc.primitives = .polygons(
                (0..<geometry.faces.count).map { _ in UInt8(3) },
                (0..<geometry.faces.count * 3).map {
                    geometry.faces.buffer.contents()
                        .advanced(by: $0 * geometry.faces.bytesPerIndex)
                        .assumingMemoryBound(to: UInt32.self).pointee
                }
            )
        }
        let meshResource = try MeshResource.generate(from: [desc])
        let material = OcclusionMaterial()
        let modelEntity = ModelEntity(mesh: meshResource, materials: [material])
        return modelEntity
    }

    // HandTrackingのAnchorを更新
    func processHandUpdates() async {
        var leftWristPosition: SIMD3<Float>?
        var rightWristPosition: SIMD3<Float>?
        var leftHandTipPosition: SIMD3<Float>?
        var rightHandTipPosition: SIMD3<Float>?

        for await update in handTracking.anchorUpdates {
            switch update.event {
            case .updated:
                let anchor = update.anchor
                guard anchor.isTracked else { continue }

                let wristPosition = getWristPosition(handAnchor: anchor)
                let handTipPosition = getHandTipPosition(handAnchor: anchor)

                if anchor.chirality == .left {
                    leftWristPosition = wristPosition
                    leftHandTipPosition = handTipPosition
                } else {
                    rightWristPosition = wristPosition
                    rightHandTipPosition = handTipPosition
                }

                // 両手の位置が取得できたら、かめはめ波の処理を行う
                if let leftWrist = leftWristPosition, let rightWrist = rightWristPosition,
                   let leftTip = leftHandTipPosition, let rightTip = rightHandTipPosition {
                    await manageKamehameha(leftWrist: leftWrist, rightWrist: rightWrist,
                                           leftTip: leftTip, rightTip: rightTip)
                }
            default:
                break
            }
        }
    }

    // 手の先端位置を取得
    func getHandTipPosition(handAnchor: HandAnchor) -> SIMD3<Float> {
        guard let middleTip = handAnchor.handSkeleton?.joint(.middleFingerTip),
              let wrist = handAnchor.handSkeleton?.joint(.wrist) else {
            return SIMD3<Float>(0, 0, 0)
        }

        let middleTipPosition = simd_make_float3(middleTip.anchorFromJointTransform.columns.3)
        let wristPosition = simd_make_float3(wrist.anchorFromJointTransform.columns.3)

        // 手首から中指の先端へのベクトルを計算し、その方向に少し伸ばした位置を手の先端とする
        let handDirection = normalize(middleTipPosition - wristPosition)
        let handTip = middleTipPosition + handDirection * 0.05 // 5cm先に設定

        let handTipTransform = simd_float4x4(
            SIMD4<Float>(1, 0, 0, 0),
            SIMD4<Float>(0, 1, 0, 0),
            SIMD4<Float>(0, 0, 1, 0),
            SIMD4<Float>(handTip.x, handTip.y, handTip.z, 1)
        )

        let worldTransform = matrix_multiply(handAnchor.originFromAnchorTransform, handTipTransform)

        return worldTransform.columns.3.xyz
    }

    // 手首の位置を取得
    func getWristPosition(handAnchor: HandAnchor) -> SIMD3<Float> {
        guard let wrist = handAnchor.handSkeleton?.joint(.wrist) else {
            return SIMD3<Float>(0, 0, 0)
        }

        let wristTransform = matrix_multiply(handAnchor.originFromAnchorTransform, wrist.anchorFromJointTransform)
        return wristTransform.columns.3.xyz
    }

    // かめはめ波の管理
    @MainActor
    func manageKamehameha(leftWrist: SIMD3<Float>, rightWrist: SIMD3<Float>,
                          leftTip: SIMD3<Float>, rightTip: SIMD3<Float>) {
        let wristDistance = distance(leftWrist, rightWrist)
        let isCreatingOrUpdating = wristDistance < kamehamehaDistanceThreshold

        if isCreatingOrUpdating {
            if kamehamehaEntity == nil {
                // かめはめ波がまだない場合、作成
                let newKamehameha = generateKamehameha()
                let position = (leftTip + rightTip) / 2 // 両手の先端の中間点
                newKamehameha.position = position
                contentEntity.addChild(newKamehameha)
                kamehamehaEntity = newKamehameha

                Task {
                    let chargeSound = try await AudioFileResource(named: "Charge.mp3")
                    let audioController = kamehamehaEntity?.prepareAudio(chargeSound)
                    audioController?.gain = 30
                    audioController?.play()
                }
            } else if let kamehameha = kamehamehaEntity {
                // 既にかめはめ波がある場合、位置とサイズを更新
                let position = (leftTip + rightTip) / 2
                kamehameha.position = position

                // サイズを徐々に大きくする
                if kamehameha.scale.x < 3 {
                    kamehameha.scale += SIMD3(0.05, 0.05, 0.05)
                }
            }
        } else if let kamehameha = kamehamehaEntity {
            // かめはめ波の発射処理
            let leftArmDirection = normalize(leftTip - leftWrist)
            let rightArmDirection = normalize(rightTip - rightWrist)
            let shootDirection = normalize(leftArmDirection + rightArmDirection)

            let forcePower: Float = 500 * kamehameha.scale.x

            kamehameha.stopAllAudio()

            Task {
                let shotSound = try await AudioFileResource(named: "Shot.mp3")
                let audioController = kamehameha.prepareAudio(shotSound)
                audioController.gain = 30
                audioController.play()
            }

            kamehameha.children[0].children[0].removeFromParent()

            kamehameha.addForce(shootDirection * forcePower, relativeTo: nil)

            // 発射後の後処理
            kamehamehaEntity = nil
        }
    }

    @MainActor
    func generateKamehameha() -> ModelEntity {
        let radius: Float = 0.03

        var material = PhysicallyBasedMaterial()
        material.emissiveColor = PhysicallyBasedMaterial.EmissiveColor(color: .yellow)
        material.emissiveIntensity = 3.0

        let kamehameha = ModelEntity(
            mesh: .generateSphere(radius: radius),
            materials: [material]
        )

        kamehameha.name = "Kamehameha"
        kamehameha.collision = CollisionComponent(
            shapes: [.generateSphere(radius: radius)],
            mode: .default
        )

        kamehameha.components.set(GroundingShadowComponent(castsShadow: true))

        if let auraEntity = self.auraEntity?.clone(recursive: true) {
            kamehameha.addChild(auraEntity)
        } else {
            print("Aura entity not loaded")
        }

        kamehameha.physicsBody = PhysicsBodyComponent(
            shapes: [ShapeResource.generateSphere(radius: radius)],
            mass: 0.1,
            material: nil,
            mode: .dynamic
        )
        kamehameha.physicsBody?.isAffectedByGravity = false

        return kamehameha
    }
}
