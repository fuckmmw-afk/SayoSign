<p align="center">
  <img src="docs/assets/icon.png" width="128" alt="SayoSign icon">
</p>

<h1 align="center">SayoSign</h1>

<p align="center">
  <b>A cute and very capable IPA signer that runs right on your iPhone.</b><br>
  Sign with a .p12 or a free Apple ID, inject tweaks with a home-made hooking engine, install offline.
</p>

<p align="center">
  <a href="https://github.com/murk-sus/SayoSign/actions"><img src="https://github.com/murk-sus/SayoSign/actions/workflows/build.yml/badge.svg" alt="Build"></a>
  <img src="https://img.shields.io/badge/iOS-15%2B-ff7e8a" alt="iOS 15+">
  <img src="https://img.shields.io/badge/license-GPL--3.0-f0566e" alt="GPL-3.0">
  <a href="README_RU.md"><img src="https://img.shields.io/badge/README-на%20русском-ffb3a7" alt="Russian"></a>
  <a href="README_ZH.md"><img src="https://img.shields.io/badge/README-简体中文-ffb3a7" alt="Chinese"></a>
</p>

---

## ✨ Features

- **On-device signing.** Its own signing engine is written from scratch in C: Mach-O (thin and fat), SHA-256 CodeDirectory, CMS signature, XML and DER entitlements, nested frameworks and extensions, `_CodeSignature/CodeResources`, and ZIP64 IPA packing. It has no OpenSSL and no zsign inside.
- **Certificates.** Import a `.p12` with its `.mobileprovision`, see the team, expiry, devices and entitlements, and check **revocation live with OCSP** against Apple.
- **Apple ID sign-in that works in 2026.** Use a free or paid developer account directly. SayoSign speaks GrandSlam (SRP-6a, 2FA by trusted device or SMS) and Apple Developer Services, and the **anisette v3** protocol with Mac-based servers, which Apple still accepts after its October 2026 crackdown (see below).
- **Tweak injection.** Accepts `.dylib`, `.deb` (gzip, xz, lzma or zstd, with its own zstd decoder) and `.framework`. Substrate, ElleKit, libhooker and substitute dependencies are rewired automatically.
- **SayoHook,** a home-made hooking framework, is shipped as `CydiaSubstrate.framework` and exports `MSHookMessageEx`, `MSHookFunction`, `MSFindSymbol`, `MSGetImageByName`, `LHHookFunctions`, `LBHookMessage` and `substitute_*`.
  - Objective-C hooks work everywhere.
  - C function hooks work on stock iOS by rebinding symbol pointers, and use real ARM64 inline trampolines with instruction relocation when JIT is available.
- **Offline installs.** A tiny HTTPS server on `localhost` and `itms-services` install the app. Trust comes from a certificate authority generated on your device; its private key never leaves the phone, so there are no leaked keys and no third-party servers.
- **Sources.** AltStore, SideStore, Feather and ESign repositories with search, screenshots and one-tap download.
- **App tweaks.** Change the name, bundle ID, version, icon and minimum iOS. You can also remove extensions, Watch apps or URL schemes, enable Files sharing, and add extra entitlements.
- **Interface.** Clean ESign-style tabs, **Light / Black / System** themes, Liquid Glass on iOS 26+, English, Russian and Simplified Chinese.

## 🍎 Apple ID and anisette in 2026

Since mid-October 2026 Apple rejects anisette that does not match its client: data from **Android** libraries (`ani.sidestore.io`, `ani.sidestore.zip`, self-hosted `anisette-v3-server`) fails with `-80045`, HTTP `503` or `401`. SayoSign 1.1:

- implements the **anisette v3** protocol (provisioning over WebSocket, `/v3/get_headers`, identity kept in the Keychain) with a v1 fallback;
- sends the anisette server's own client info and user agent on every Apple request and takes endpoints from Apple's URL bag;
- defaults to Mac-based servers (`ani.iloader.app`, `mac-ani.jkcoxson.com`, `new.ani.sidestore.io`) and moves you off rejected ones automatically;
- shows the server's protocol, client info and device ID in **Settings → Anisette server → Check server**, and explains Apple's error codes.

Have a PC? **[SayoSign Desktop](https://github.com/murk-sus/SayoSign-Desktop)** runs an anisette server on your computer: scan its QR code with the iPhone camera and SayoSign sets it up.

## 🖥 Desktop app

Signing from Linux, Windows or macOS now lives in its own repository: **[SayoSign Desktop](https://github.com/murk-sus/SayoSign-Desktop)** (Sideloadly-style app with Apple ID, tweak injection and an anisette server). It uses this repository's engine as a submodule.

## 📲 Install

1. Download `SayoSign.ipa` from [Releases](https://github.com/murk-sus/SayoSign/releases) (or the latest CI build in [Actions](https://github.com/murk-sus/SayoSign/actions)).
2. Sign it once with whatever you have: another signer, Sideloadly, AltStore, or the `sayosign` CLI from this repo (see below).
3. Open SayoSign → **Settings → Local installer setup** and follow the three steps. You only do this once.

## 🛠 Command-line signer

The same engine builds as a desktop CLI (Linux or macOS, needs OpenSSL for p12 parsing):

```sh
make
./build/sayosign sign -k cert.p12 -p 1234 -m profile.mobileprovision -i app.ipa -o signed.ipa \
    -n "My App" -l tweak.deb -H build/CydiaSubstrate.framework
./build/sayosign ocsp -k cert.p12 -p 1234
```

## 🧱 Building

The repository is built entirely by GitHub Actions; no Mac is needed.

- `make && ./tests/run.sh` builds the core and runs its tests (zstd, ZIP64, .deb, SRP-6a, AES-GCM and PBKDF2 checked against reference implementations).
- `xcodegen generate` then `xcodebuild …` builds the unsigned IPA (see `.github/workflows/build.yml`).

```
core/   C signing engine: Mach-O, CMS, ZIP, deb, zstd, X.509, OCSP, SRP, AES
hook/   SayoHook, the hooking framework shipped as CydiaSubstrate.framework
app/    SwiftUI app
cli/    desktop CLI around the core
docs/   website and AltStore source (GitHub Pages)
```

## 🧾 AltStore source

Add `https://murk-sus.github.io/SayoSign/source.json` to AltStore, SideStore, Feather or SayoSign itself.

## 🧩 Tweaks in sources

A source can list tweaks (.dylib / .deb) next to its IPAs. SayoSign shows them under Sources → Tweaks, downloads new versions whenever sources refresh (every 30 minutes when the app opens, or on pull to refresh), and adds a tweak by itself when you sign the app it is made for.

Three ways to list a tweak; other signers ignore these fields:

- a `tweaks` array inside an app entry (targets default to that app's bundle ID);
- an `apps` entry whose download is a `.dylib`/`.deb` (or has `"type": "tweak"`), with optional `targets`;
- a top-level `tweaks` array; each entry has `targets`, a list of bundle IDs or `"*"`.

Fields: `name`, `identifier`, `version`, `downloadURL` (or `versions[0]`), `targets`, and optionally `iconURL`, `localizedDescription`, `size`, `developerName`. A tweak updates when its `version` or link changes. Turn it off in Settings → Tweaks from sources, or per tweak with a long press.

## ☁️ Signing on your server

SayoSign can sign on your own server instead of the iPhone (**Settings → Signing server**, or the **iPhone / Server** switch in the sign window).

- The server downloads IPAs from their source URL itself. Apps imported from Files are uploaded in 16 MB parts, so this works behind Cloudflare and resumes after a dropped connection.
- Tweaks and the hook framework are uploaded once and reused by checksum. Tweaks already in the app can still be removed or replaced, and every option of on-device signing works.
- iOS installs the signed app straight from the server through its manifest, so the local installer is not needed. A copy is also downloaded into **Signed**, and the server deletes its copy after 24 hours.
- The certificate (its key and certificate, or the .p12) is sent for each signing and deleted when it is done. Apple ID profiles are still requested on the iPhone.

Server setup (Linux with nginx and Python 3, no extra packages): run `sudo server/install.sh https://example.com/sign`, add `server/nginx.conf` to the site, then open the printed `sayosign://server?url=…&key=…` link on the iPhone. The API is described at the top of `server/sayosign_server.py`.

## 🔍 See also

[IPALens](https://murk-sus.github.io/IPALens/) — check any IPA, .p12, profile or .deb in your browser: decrypted or not, UDID in profile, p12 ↔ profile match.

## 💖 Support

SayoSign is free and open source. If it saved you time, a tip keeps it going:

| Network | Address |
|---|---|
| USDT (TRC20) | `TCPD7jzSMtQ4zkoSxSbUZi6RFoVdKqv78w` |
| TON | `UQAVaWTuYuEF8A_qiVEcHnqhomp2UdYvW4fHxyhJVxFkQe1z` |
| BTC | `bc1qqvt25c9tzw2yfdpvf738gzzk4r5uyvkrrlz4z0` |
| ETH (ERC20) | `0xE7497CF78B691F84D2f1A2Dc30223BB53B3EF38D` |
| SOL | `DhcDnnqK23gwvkRRHtNd3TBXN9gHmT4V7LZrAPHgCR6n` |

Donation page with QR codes: **[murk-sus.github.io/donate](https://murk-sus.github.io/donate/)** · Telegram channel: [@jailbreak_IOS_and_tweaks](https://t.me/jailbreak_IOS_and_tweaks)

## ⚖️ Legal

SayoSign signs apps with **your own** certificates for **your own** devices. Do not use it to distribute pirated software. Not affiliated with Apple.

The name is a nod to Sayori. No artwork from *Doki Doki Literature Club* is used. The icon is made with [Twemoji](https://github.com/jdecked/twemoji) 🎀 ✒️ (CC-BY 4.0).

Licensed under **GPL-3.0**.
