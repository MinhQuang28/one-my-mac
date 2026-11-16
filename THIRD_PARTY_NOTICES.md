# Third-party notices

HiDisplay ships **no third-party code and no third-party dependencies**. `Package.swift` declares none.

The projects below were consulted for factual knowledge about undocumented macOS interfaces. No source
code was copied from any of them. They are credited because that knowledge was genuinely useful, and
because the alternative — presenting reverse-engineered facts as if discovered in isolation — would be
dishonest.

A full account of what was taken from each, and what was verified independently on hardware, is in
[docs/legal/source-audit.md](docs/legal/source-audit.md).

## MonitorControl

<https://github.com/MonitorControl/MonitorControl> — MIT License

Consulted for the existence of the `IOAVService` I2C entry points and the `DisplayServices` brightness
functions on Apple Silicon. No code reused.

## one-key-hidpi

<https://github.com/xzhih/one-key-hidpi> — MIT License

Consulted for the display-override approach: the writable override root, the vendor/product directory
naming, and the general shape of `scale-resolutions`. No code reused; that project is a shell script.

## BetterDisplay

<https://github.com/waydabber/BetterDisplay> — proprietary

Public documentation and issue discussions consulted for the problem space only. No source was available
and none was sought.

## HyperMac

<https://github.com/mrgoose000000-gif/HyperMac> — no license file in the copy consulted

Three OneMac features follow HyperMac's approach and were rewritten for this codebase: the charge limit
through the system `PowerUISmartChargeClient` (`HardwareKit/ChargeLimitClient.swift`), the CPU / RAM / GPU
sampler built on Mach host statistics and `IOAccelerator` (`HardwareKit/SystemUsageSampler.swift`), and
the reset of a stale Accessibility grant (`OneMac/AccessibilityRecovery.swift`). The battery card's limit
notch and the menu-bar statistics rows follow its layout.

## Apple

CoreGraphics, IOKit and ServiceManagement are used as documented at
<https://developer.apple.com/documentation>. Four display override files from
`/System/Library/Displays/` and `/Library/Displays/` are committed as test fixtures under
`Tests/HiDisplayTests/Fixtures/overrides/`; they are display-timing configuration data containing no
personal information, used to verify that this project's codec correctly round-trips real-world files.

## VESA MCCS

The DDC/CI wire framing implemented in `VCPCodec` follows the published VESA Monitor Control Command Set
specification, which describes a wire protocol rather than software.
