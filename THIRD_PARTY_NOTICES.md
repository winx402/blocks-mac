# Third-party notices

The root MIT license applies to project-authored code and documentation. It does
not replace licenses on third-party dependencies, copied material, or assets.

Apple frameworks and system symbols remain subject to Apple's applicable terms;
they are not relicensed by this repository. External AI/translation providers
retain their own service terms, and their credentials are not included.

## Locked development dependencies

The website lockfile identifies these non-MIT components. They are not
relicensed; retain their original notices and source availability requirements
when distributing outputs that include them.

| Component | Locked version | License / source |
|---|---|---|
| caniuse-lite / Can I use data | 1.0.30001809 | CC-BY-4.0; https://github.com/browserslist/caniuse-lite and https://caniuse.com/ |
| axe-core | 4.11.4 | MPL-2.0; https://github.com/dequelabs/axe-core |
| lightningcss and its platform packages | 1.33.0 | MPL-2.0; https://github.com/parcel-bundler/lightningcss |

Exact package sources, integrity hashes, and other licenses are recorded in
`site/package-lock.json`. This includes MIT, Apache-2.0, ISC, BSD, CC0, BlueOak,
and Python-licensed packages. The website dependencies are not automatically
bundled into the native Mac app.

The schema-validator probe locks Swift Collections, Swift Syntax, and
swift-json-schema. Their Apache-2.0/MIT notices remain applicable; see the
probe's `Package.resolved` and upstream repositories:
https://github.com/apple/swift-collections,
https://github.com/swiftlang/swift-syntax,
https://github.com/ajevans99/swift-json-schema.

Dependency and asset provenance must be rechecked before every release.
An incomplete artifact audit is a release blocker, not evidence that all
dependencies can be redistributed under MIT.
