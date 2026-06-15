import ProjectDescription

// Local stable signing: set TUIST_CODESIGN_IDENTITY to a (self-signed) code-
// signing certificate so the keychain "Always Allow" grant persists across
// relaunches/rebuilds. Ad-hoc ("-", the default) has no stable identity, so
// macOS re-prompts every launch. CI and contributors who don't set it stay
// ad-hoc. Manual signing only — no team, no provisioning profile.
// (Tuist sandboxes manifest env vars to its `Environment` API, so this is read
// via TUIST_CODESIGN_IDENTITY, not a plain env var.)
let codeSignIdentityValue = Environment.codesignIdentity.getString(default: "-")
let codeSignIdentity: SettingValue = .string(codeSignIdentityValue)
let codeSignStyle: SettingValue = .string(codeSignIdentityValue == "-" ? "Automatic" : "Manual")
// SwiftUI preview / debug-dylib support injects extra nested dylibs that trip the
// "embedded binary not signed with the same certificate" check under manual
// signing. They're only needed for previews, so turn them off when signing with a
// real cert (the default ad-hoc dev build keeps them on for previews).
let previewsEnabled: SettingValue = .string(codeSignIdentityValue == "-" ? "YES" : "NO")

let project = Project(
    name: "ClaudeBar",
    options: .options(
        defaultKnownRegions: ["en"],
        developmentRegion: "en"
    ),
    settings: .settings(
        base: [
            "SWIFT_VERSION": "6.0",
            "MACOSX_DEPLOYMENT_TARGET": "15.0",
            "ENABLE_DEBUG_DYLIB": previewsEnabled,
        ],
        debug: [
            "SWIFT_ACTIVE_COMPILATION_CONDITIONS": "DEBUG MOCKING",
            "ENABLE_DEBUG_DYLIB": previewsEnabled,
        ],
        release: [
            "SWIFT_ACTIVE_COMPILATION_CONDITIONS": "MOCKING",
        ]
    ),
    targets: [
        // MARK: - Domain Layer
        .target(
            name: "Domain",
            destinations: .macOS,
            product: .staticFramework,
            bundleId: "com.tddworks.claudebar.domain",
            deploymentTargets: .macOS("15.0"),
            sources: ["Sources/Domain/**"],
            dependencies: [
                .external(name: "Mockable"),
            ],
            settings: .settings(
                base: [
                    "SWIFT_STRICT_CONCURRENCY": "complete",
                ]
            )
        ),

        // MARK: - Infrastructure Layer
        .target(
            name: "Infrastructure",
            destinations: .macOS,
            product: .staticFramework,
            bundleId: "com.tddworks.claudebar.infrastructure",
            deploymentTargets: .macOS("15.0"),
            sources: ["Sources/Infrastructure/**"],
            dependencies: [
                .target(name: "Domain"),
                .external(name: "Mockable"),
                .external(name: "SwiftTerm"),
                .external(name: "AWSCloudWatch"),
                .external(name: "AWSSTS"),
                .external(name: "AWSPricing"),
                .external(name: "AWSSDKIdentity"),
                .external(name: "AWSSSO"),
                .external(name: "AWSSSOOIDC"),
                .external(name: "SweetCookieKit"),
            ],
            settings: .settings(
                base: [
                    "SWIFT_STRICT_CONCURRENCY": "complete",
                ]
            )
        ),

        // MARK: - Widget Shared (code shared by app + widget extension)
        .target(
            name: "WidgetShared",
            destinations: .macOS,
            product: .staticFramework,
            bundleId: "com.tddworks.claudebar.widgetshared",
            deploymentTargets: .macOS("15.0"),
            sources: ["Sources/WidgetShared/**"],
            settings: .settings(
                base: [
                    "SWIFT_STRICT_CONCURRENCY": "complete",
                ]
            )
        ),

        // MARK: - Widget Extension (desktop widget; reads usage over loopback)
        .target(
            name: "ClaudeBarWidget",
            destinations: .macOS,
            product: .appExtension,
            bundleId: "com.tddworks.claudebar.widget",
            deploymentTargets: .macOS("15.0"),
            infoPlist: .extendingDefault(with: [
                "CFBundleDisplayName": "Claude Usage",
                "NSExtension": [
                    "NSExtensionPointIdentifier": "com.apple.widgetkit-extension",
                ],
            ]),
            // Compile the shared model sources directly (an app extension can't
            // depend on a static framework); JSON over loopback is the real
            // contract between app and widget, so a separate copy of the types
            // is fine.
            sources: ["Sources/Widget/**", "Sources/WidgetShared/**"],
            entitlements: .file(path: "Sources/Widget/entitlements.plist"),
            settings: .settings(
                base: [
                    // Swift 5 mode: WidgetKit's closure-based TimelineProvider
                    // completion handlers don't satisfy Swift 6 `sending` rules.
                    "SWIFT_VERSION": "5",
                    "CODE_SIGN_IDENTITY": codeSignIdentity,
                    "CODE_SIGN_STYLE": codeSignStyle,
                ]
            )
        ),

        // MARK: - Main Application
        .target(
            name: "ClaudeBar",
            destinations: .macOS,
            product: .app,
            bundleId: "com.tddworks.claudebar",
            deploymentTargets: .macOS("15.0"),
            infoPlist: .file(path: "Sources/App/Info.plist"),
            sources: ["Sources/App/**"],
            resources: [
                "Sources/App/Resources/**",
            ],
            entitlements: .file(path: "Sources/App/entitlements.plist"),
            dependencies: [
                .target(name: "Domain"),
                .target(name: "Infrastructure"),
                .target(name: "WidgetShared"),
                .target(name: "ClaudeBarWidget"),
                .external(name: "Sparkle"),
            ],
            settings: .settings(
                base: [
                    "SWIFT_STRICT_CONCURRENCY": "complete",
                    "ENABLE_DEBUG_DYLIB": previewsEnabled,
                    "ENABLE_PREVIEWS": previewsEnabled,
                    "CODE_SIGN_IDENTITY": codeSignIdentity,
                    "CODE_SIGN_STYLE": codeSignStyle,
                    "ASSETCATALOG_COMPILER_APPICON_NAME": "AppIcon",
                ],
                debug: [
                    "SWIFT_ACTIVE_COMPILATION_CONDITIONS": "DEBUG ENABLE_SPARKLE",
                ],
                release: [
                    "SWIFT_ACTIVE_COMPILATION_CONDITIONS": "ENABLE_SPARKLE",
                ]
            )
        ),

        // MARK: - Domain Tests
        .target(
            name: "DomainTests",
            destinations: .macOS,
            product: .unitTests,
            bundleId: "com.tddworks.claudebar.domain-tests",
            deploymentTargets: .macOS("15.0"),
            sources: ["Tests/DomainTests/**"],
            dependencies: [
                .target(name: "Domain"),
                .target(name: "Infrastructure"),
                .external(name: "Mockable"),
                .external(name: "AWSCloudWatch"),
                .external(name: "AWSSTS"),
                .external(name: "AWSPricing"),
                .external(name: "AWSSDKIdentity"),
                .external(name: "AWSSSO"),
                .external(name: "AWSSSOOIDC"),
            ],
            settings: .settings(
                base: [
                    "SWIFT_ACTIVE_COMPILATION_CONDITIONS": "MOCKING",
                ]
            )
        ),

        // MARK: - Infrastructure Tests
        .target(
            name: "InfrastructureTests",
            destinations: .macOS,
            product: .unitTests,
            bundleId: "com.tddworks.claudebar.infrastructure-tests",
            deploymentTargets: .macOS("15.0"),
            sources: ["Tests/InfrastructureTests/**"],
            dependencies: [
                .target(name: "Infrastructure"),
                .target(name: "Domain"),
                .external(name: "Mockable"),
                .external(name: "AWSCloudWatch"),
                .external(name: "AWSSTS"),
                .external(name: "AWSPricing"),
                .external(name: "AWSSDKIdentity"),
                .external(name: "AWSSSO"),
                .external(name: "AWSSSOOIDC"),
            ],
            settings: .settings(
                base: [
                    "SWIFT_ACTIVE_COMPILATION_CONDITIONS": "MOCKING",
                ]
            )
        ),

        // MARK: - Acceptance Tests (BDD - Outer Loop)
        .target(
            name: "AcceptanceTests",
            destinations: .macOS,
            product: .unitTests,
            bundleId: "com.tddworks.claudebar.acceptance-tests",
            deploymentTargets: .macOS("15.0"),
            sources: ["Tests/AcceptanceTests/**"],
            dependencies: [
                .target(name: "Domain"),
                .target(name: "Infrastructure"),
                .external(name: "Mockable"),
                .external(name: "AWSCloudWatch"),
                .external(name: "AWSSTS"),
                .external(name: "AWSPricing"),
                .external(name: "AWSSDKIdentity"),
                .external(name: "AWSSSO"),
                .external(name: "AWSSSOOIDC"),
            ],
            settings: .settings(
                base: [
                    "SWIFT_ACTIVE_COMPILATION_CONDITIONS": "MOCKING",
                ]
            )
        ),
    ],
    schemes: [
        .scheme(
            name: "ClaudeBar",
            shared: true,
            buildAction: .buildAction(targets: ["ClaudeBar"]),
            testAction: .targets(
                [
                    .testableTarget(target: .target("AcceptanceTests")),
                    .testableTarget(target: .target("DomainTests")),
                    .testableTarget(target: .target("InfrastructureTests")),
                ],
                configuration: .debug
            ),
            runAction: .runAction(configuration: .debug, executable: .target("ClaudeBar")),
            archiveAction: .archiveAction(configuration: .release),
            profileAction: .profileAction(configuration: .release, executable: .target("ClaudeBar")),
            analyzeAction: .analyzeAction(configuration: .debug)
        ),
    ]
)