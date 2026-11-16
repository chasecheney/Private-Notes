// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "PrivateNotesCrypto",
    platforms: [
        .macOS(.v14),
        .iOS(.v17),
    ],
    products: [
        .library(name: "PrivateNotesCrypto", targets: ["PrivateNotesCrypto"]),
        .library(name: "PrivateNotesStore", targets: ["PrivateNotesStore"]),
        .library(name: "PrivateNotesEditing", targets: ["PrivateNotesEditing"]),
    ],
    dependencies: [
        // The one approved third-party dependency. Provides Argon2id (libsodium).
        .package(url: "https://github.com/jedisct1/swift-sodium.git", exact: "0.11.0"),
    ],
    targets: [
        // All cryptography: keys, password and recovery unlock, item encryption.
        .target(
            name: "PrivateNotesCrypto",
            dependencies: [
                .product(name: "Sodium", package: "swift-sodium"),
            ]
        ),
        .testTarget(
            name: "PrivateNotesCryptoTests",
            dependencies: ["PrivateNotesCrypto"]
        ),
        // Notes, folders, and the encrypted on-disk vault. No UI.
        .target(
            name: "PrivateNotesStore",
            dependencies: ["PrivateNotesCrypto"]
        ),
        .testTarget(
            name: "PrivateNotesStoreTests",
            dependencies: ["PrivateNotesStore"]
        ),
        // How rich text looks and behaves in a text view: fonts, lists, and the
        // translation to and from the stored model. No views, so it can be tested.
        .target(
            name: "PrivateNotesEditing",
            dependencies: ["PrivateNotesStore"]
        ),
        .testTarget(
            name: "PrivateNotesEditingTests",
            dependencies: ["PrivateNotesEditing"]
        ),
    ]
)
