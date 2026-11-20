# TestFlight: the owner's guide

How NewsPaw Reader gets from this repository onto the owner's iPhone and iPads through TestFlight internal testing (spec N13; issue RD22 #143). Written on 2026-11-19 before the first upload: no step marked **(to verify)** has been tried with the owner's account yet, and the driver corrects this guide after the first run.

The repository is public. Nothing in this guide or its build log may carry the Team ID, an App Store Connect API key ID or issuer ID, an Apple ID, a device name or serial number, a tester's e-mail, or unmasked entitlements.

There are two routes. The **Xcode route** (sections 2–8) needs you at the Mac once, to sign in to Xcode. The **phone route** (section 12) needs only a phone's browser: you create an App Store Connect API key, and the driver on the Mac archives and uploads with it. Sections 6–11 apply to both, except section 6's Organizer fallback, which belongs to the Xcode route.

## 1. Who does what

| Step | Who | What it unblocks |
| --- | --- | --- |
| O1. Sign in to Xcode; send the Team ID (section 2) | Owner | Signing. The driver writes the local signing file and runs `ios/Tools/archive.sh`, which also registers the app's identifier |
| O2. Only if asked: register the iPhone (section 3) | Owner | The first signed archive |
| O3. Check the identifier; create the app record (section 4) | Owner | Uploads |
| O4. Add yourself as an internal tester (section 5) | Owner | Installing |
| O5. Authorise the upload of build N (section 6) | Owner; the driver uploads | The M1 walk |
| O6. Install on the three devices (section 7); walk the M1 sheet in [device-checks.md](device-checks.md); report (section 10) | Owner | Recording results; the fixes |
| O7. Authorise build N+1; update over N (section 8); the upgrade check | Owner | The issue's first criterion |
| O8. The other device checks, at your pace | Owner | — |

The driver never uploads without your message naming the build. Away from the Mac, use section 12 instead of O1 and O2.

## 2. Sign in to Xcode (O1) (to verify)

1. On the Mac: Xcode › Settings… › Accounts › "+" › Apple Account › Continue. Sign in with the Apple Account of the paid Apple Developer membership and enter the two-factor code.
2. The account lists a team with the role Account Holder (or Admin). If it lists several teams, the one that matters is the team of the paid membership.
3. Find the Team ID: developer.apple.com › Account › Membership details (of that paid membership). It is ten capital letters and digits. Send it to the driver. Do not take it from anywhere else.
4. Do **not** choose a team in the project's Signing & Capabilities pane: Xcode would write it into the project file, which is public. The team lives only in `ios/Config/Signing.local.xcconfig` on this Mac, which git ignores; the driver writes it.
5. While on developer.apple.com: if an agreement is waiting to be accepted, accept it. An unaccepted agreement blocks uploads.

## 3. If asked: register the iPhone (O2) (to verify)

The first signed archive may need one registered device. If the driver asks:

1. Connect the iPhone to the Mac with a cable and unlock it.
2. Tap Trust on the iPhone and enter its passcode.
3. Xcode › Window › Devices and Simulators shows it. Nothing else is needed.

## 4. Check the identifier; create the app record (O3) (to verify)

1. The driver's first archive tells whether `io.newspaw.reader` could be registered under your team. If it could not (another team owns it), choose another identifier **before anything is installed** and tell the driver; only the project's bundle identifier changes. You can also check yourself: developer.apple.com › Certificates, Identifiers & Profiles › Identifiers › "+" › App IDs › App › Explicit Bundle ID `io.newspaw.reader`, no capability.
2. appstoreconnect.apple.com › Apps › "+" › New App:
   - Platforms: iOS.
   - Name: NewsPaw. If it is taken, NewsPaw Reader. The home screen shows "NewsPaw" either way.
   - Primary Language: English (U.S.).
   - Bundle ID: `io.newspaw.reader` (or the replacement from step 1).
   - SKU: `newspaw-reader`.
   - User Access: Full Access.
   - Create.
3. Nothing else in the record is needed for internal testing.

## 5. Add yourself as an internal tester (O4) (to verify)

1. App Store Connect › the app › TestFlight › Internal Testing › "+".
2. Group name: Owner. Turn on "Enable automatic distribution". Create.
3. Testers › "+" › select yourself › Add. The invitation goes to your Apple Account's e-mail.

## 6. Authorise the upload (O5)

- **Default:** send the driver a message such as "upload 0.1.0-1012", naming the version and build the driver reported from `archive.sh`. The driver then runs `ios/Tools/upload.sh "<archive>" --confirm 0.1.0-1012`, with the value copied from your message, and records your message in the build log.
- **Fallback, by you (Xcode route only):** Xcode › Window › Organizer › Archives › "NewsPaw 0.1.0 (1012)" › Distribute App › TestFlight Internal Only › Distribute. (to verify)
- After the upload App Store Connect processes the build; it e-mails when the build is ready, usually within minutes to an hour. (to verify)
- Each build is "TestFlight internal only": it cannot go to external testers or the App Store.

## 7. Install on the three devices (O6) (to verify)

1. On each device install the TestFlight app from the App Store.
2. Open the invitation e-mail on the device, or open TestFlight signed in with the same Apple Account, and accept NewsPaw.
3. Install.
4. The first install on each device is the "fresh install" of the M1 walk. If NewsPaw was ever run on that device from Xcode, delete it first.
5. NewsPaw › Settings › About shows the version and build, for example "0.1.0 (1012)".

## 8. Upgrade over a previous build (O7) (to verify)

1. When a newer build is ready, TestFlight › NewsPaw › Update. Never delete and reinstall: that is not an upgrade and loses the library.
2. Then the upgrade check, section 2 of [device-checks.md](device-checks.md).

## 9. Debug builds on your devices

Some device checks need a debug build run from Xcode (they say so). The rule, to keep the library you use safe:

1. The debug build is built from the commit of the TestFlight build installed on that device (the build log names it).
2. Only after that device's M1 walk and upgrade check.
3. Afterwards, reinstall the TestFlight build from TestFlight.

A debug build from a later commit could carry a newer database migration and leave the library unreadable by the TestFlight build. Whether a development install over a TestFlight install keeps the app's data is not known yet. (to verify)

## 10. What to send back

Per device, in Chinese or English:

- the model (for example "iPad mini (8th generation)") and the system version (Settings › General › About);
- the build from NewsPaw › Settings › About;
- per step: pass or fail, and one neutral sentence about a failure;
- for a crash: send TestFlight's crash feedback when it offers it; the driver reads it in Xcode › Organizer › Crashes. (to verify)

Never send, and never let the driver record: a source address, a site name, a key, a model name, your Apple ID, a device's name or serial number, or a screenshot of adult-partition content.

## 11. Build log

One row per build archived. Entitlements are never pasted here unmasked, and a quoted error message (from `xcodebuild`, Xcode or App Store Connect) has the team masked as `<team>` and the API key's identifiers as `<key-id>` and `<issuer-id>`; the scripts print their output masked already. A row may say which route was used ("Xcode account" or "API key"), never the key's identifiers. "Authorised by" quotes the owner's message and its date.

| Version | Build | Commit | Archived | Uploaded | Authorised by | Processing result | Expires | Notes |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |

## 12. From a phone, without the Mac

For when you are away from the Mac with only the iPhone. Everything here is done in the phone's browser and the TestFlight app; the driver archives and uploads on the Mac. Every click path is (to verify).

**What you hand over, and the risk.** An App Store Connect API key lets whoever holds it act on your developer account with the key's role: register identifiers, create certificates and profiles, upload builds — with the Admin role, more. The driver keeps it on the Mac outside the repository (`~/.appstoreconnect/`, readable only by the Mac user), uses it only through `ios/Tools/archive.sh` and `ios/Tools/upload.sh`, and never prints it. But anyone who can read the Mac user's files can use it, and that includes the driver, an AI agent. You accepted this for the trip. You can revoke the key at any moment (step j), and it stops working at once.

a. **Team ID.** developer.apple.com › Account › Membership details (the paid membership). Ten capital letters and digits. (to verify)

b. **Register the identifier.** developer.apple.com › Certificates, Identifiers & Profiles › Identifiers › "+" › App IDs › App › Continue › Explicit Bundle ID `io.newspaw.reader`, any description, no capability › Continue › Register. If it is refused because the identifier is taken, choose another before anything else and tell the driver. (to verify)

c. **Create the app record** as in section 4, step 2. (to verify)

d. **The tester group and yourself** as in section 5. (to verify)

e. **Create the API key.** App Store Connect › Users and Access › Integrations › App Store Connect API › Team Keys. If the page asks you to request access first, do so (the Account Holder can). "+" (Generate API Key) › Name: `NewsPaw upload` › Access: **Admin** › Generate. (to verify)
   - Why Admin: the first archive must register the identifier if needed and create the development and distribution certificates and profiles through the key; whether the narrower App Manager role is enough for that is not known yet (to verify). Admin is the safe first choice. Once a build has gone through, the key can be replaced by an App Manager key (and the Admin key revoked).
   - Note the **Key ID** shown in the key's row and the **Issuer ID** shown above the list.
   - **Download** the key (a file `AuthKey_<Key ID>.p8`). Apple lets you download it **once**. Do not open it, paste it, or send its text anywhere. (to verify)
   - Safari on the iPhone saves it into a **Downloads** folder: on iCloud Drive or on the iPhone, depending on Settings › Apps › Safari › Downloads. (to verify)
   - In the Files app, create iCloud Drive › `NewsPaw-key`, then **move** the `.p8` there from Downloads (long-press the file › Move). Make sure no copy stays in Downloads. (to verify)

f. **Send the driver** the Team ID, the Key ID, the Issuer ID, and the words "the key is in iCloud Drive". Never the key's text.

g. **The driver** moves the file from iCloud Drive (`NewsPaw-key`) on the Mac to `~/.appstoreconnect/private_keys/`, writes `~/.appstoreconnect/newspaw.env` with the two identifiers and `ios/Config/Signing.local.xcconfig` with the Team ID, and tells you when it is done. On the Mac the file may at first be a placeholder that iCloud has not downloaded yet: the driver makes sure it is fully present (for example `brctl download` on it, or waiting until its size is its real size), moves it with `mv` into the private_keys folder, sets the modes (folder 700, file 600), checks that nothing is left in the iCloud folder, and never prints the file. **Then you delete**, in the Files app, the `NewsPaw-key` folder from iCloud Drive and any copy of the key left in Downloads (iCloud Drive or On My iPhone), and then empty them from Recently Deleted. (to verify)

h. **Authorise the upload** by naming the build, as in section 6. The driver's scripts say "Authentication: an App Store Connect API key" when they use it.

i. **Install** from the TestFlight app on the iPhone, as in section 7. (to verify)

j. **Revoke the key**: App Store Connect › Users and Access › Integrations › App Store Connect API › Team Keys › the `NewsPaw upload` row › Revoke. (to verify) When:
   - after the trip, once Xcode on the Mac is signed in (section 2) — the driver then deletes `~/.appstoreconnect/newspaw.env` and the key file, and the scripts use the Xcode account again;
   - at once, if the Mac or your iCloud account is in doubt.

**If the first archive stops for want of a registered device.** An automatically signed archive may need at least one device registered in the account. If it does, the phone route stops there until you are home: registering a device needs its identifier, which a phone alone does not show conveniently. Then section 3 at the Mac. (to verify)
