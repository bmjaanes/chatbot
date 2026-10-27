# Getting Next Time into the App Store

You don't need a Mac. GitHub's Mac build machines compile, sign and upload the app.
You do need an Apple Developer account, and about an hour for the one-time setup.

## Already done in this repo

| Requirement | Where |
|---|---|
| App icon (1024×1024, no transparency) | `NextTime/NextTime/Assets.xcassets/AppIcon.appiconset` |
| Location permission explanation | build setting `NSLocationWhenInUseUsageDescription` |
| Camera permission explanation | build setting `NSCameraUsageDescription` |
| Share from Google Maps | `NextTime/ShareExtension` (a Share extension) and the App Group in `NextTime/Config` |
| Privacy manifest (no tracking, no data collected) | `NextTime/NextTime/PrivacyInfo.xcprivacy` |
| Export compliance ("uses no non-exempt encryption") | build setting `ITSAppUsesNonExemptEncryption = NO` |
| Bundle ID | `com.bmjaanes.nexttime` |
| Privacy policy URL | https://bmjaanes.github.io/chatbot/privacy.html |
| Support URL | https://bmjaanes.github.io/chatbot/support.html |
| Compile check on every change | `.github/workflows/ios-build.yml` |
| Screenshots at the required 6.9" size | `.github/workflows/screenshots.yml` |
| Signed build uploaded to App Store Connect | `.github/workflows/testflight.yml` |

## One-time setup

### 1. Join the Apple Developer Program
https://developer.apple.com/programs/enroll/ costs $99 per year. Enroll as an individual unless you have a company.
Approval usually takes a day or two.

### 2. Register the App Group and the two app IDs
The app and its Google Maps share extension each need an ID, and they share saved places through an App Group.
All of this is at https://developer.apple.com/account/resources/identifiers/list.

1. Tap **+**, choose **App Groups**, and enter the description `Next Time` and the identifier `group.com.bmjaanes.nexttime`. Tap **Register**.
2. Tap **+**, choose **App IDs**, then **App**. Enter the description `Next Time` and choose **Explicit** with the Bundle ID `com.bmjaanes.nexttime`.
   Under Capabilities, tick **App Groups**. Tap **Continue**, then **Register**.
3. Repeat step 2 for the extension: description `Next Time Share`, Bundle ID `com.bmjaanes.nexttime.share`, with **App Groups** ticked.
4. Open each of the two app IDs, tap **Configure** next to App Groups, tick `group.com.bmjaanes.nexttime`, and save.

(The upload workflow often registers these automatically, but doing it by hand avoids a failed first run.)

### 3. Create the app in App Store Connect
1. Go to https://appstoreconnect.apple.com/apps, then **+**, then **New App**.
2. Fill in:
   - Platform: **iOS**
   - Name: **Next Time** (if it's taken, try **Next Time: Place Notes**)
   - Language: English (U.S.)
   - Bundle ID: `com.bmjaanes.nexttime`
   - SKU: `nexttime`
   - User Access: Full Access

### 4. Create an App Store Connect API key
This lets GitHub sign and upload builds for you.
1. Go to https://appstoreconnect.apple.com/access/integrations/api, open **Team Keys**, then **Generate API Key**
   (the first time, you'll be asked to request access; approve it).
2. Name it `GitHub`. Access must be **Admin**, because it needs permission to create signing certificates.
3. **Download** the `.p8` file. Apple only lets you download it once.
4. Note the **Key ID** (in the key's row) and the **Issuer ID** (above the table).

### 5. Find your Team ID
Go to https://developer.apple.com/account and scroll to **Membership details**. The **Team ID** is a 10-character code.

### 6. Add four secrets to GitHub
Go to https://github.com/bmjaanes/chatbot/settings/secrets/actions, choose **New repository secret**, and add:

| Name | Value |
|---|---|
| `ASC_KEY_ID` | Key ID from step 4 |
| `ASC_ISSUER_ID` | Issuer ID from step 4 |
| `ASC_KEY_P8` | The whole contents of the `.p8` file, including the `-----BEGIN PRIVATE KEY-----` and `-----END PRIVATE KEY-----` lines |
| `APPLE_TEAM_ID` | Team ID from step 5 |

On a phone, open the `.p8` file in the Files app, select all, copy, and paste it into the secret.

## Each release

### 1. Upload a build
1. Go to https://github.com/bmjaanes/chatbot/actions/workflows/testflight.yml.
2. Tap **Run workflow**, choose branch `claude/next-time-ios-app`, then **Run workflow**.
3. It takes about 10 minutes. The build then shows up in App Store Connect under **TestFlight** after Apple
   processes it (another 5 to 30 minutes).
4. Apple emails processing results to whoever uploaded the build, which here is the API key, so you won't get that email.
   To check on a build, run https://github.com/bmjaanes/chatbot/actions/workflows/testflight-status.yml. It shows each
   build's state straight from Apple, for example `IN_BETA_TESTING` when testers can install it.

### 2. Try it on your iPhone with TestFlight
1. Install **TestFlight** from the App Store.
2. In App Store Connect, open **TestFlight**, then **Internal Testing**, then **+**. Add yourself and select the build.
3. Find the invitation email (search Gmail for "TestFlight", including Promotions and Spam), open it **on the iPhone**,
   and tap **View in TestFlight**, then **Accept** and **Install**. The app doesn't appear in TestFlight until you accept.
   This is the real app: arrival reminders work in the background.
4. If there's no invitation, resend it from **Internal Testing → your group → Testers → ••• → Resend Invitation**. Also check
   that the phone's Apple ID (**Settings → [your name] → Media & Purchases**) is the one you added as a tester.

### 3. Share with friends (external testing)
Friends don't need developer accounts, just an iPhone and the free TestFlight app. Up to 10,000 people can test.
Don't add friends as *internal* testers: that makes them users on your App Store Connect account.

**Once:**
1. In App Store Connect, open the app, then **TestFlight → Test Information** (left sidebar), and fill in:
   - **Beta App Description**: Leave a note for the next time you're somewhere. Rate places, mark dishes 👍/👎, add
     photos, and get reminded when you come back. Share places from Google Maps.
   - **Feedback Email**: your email address
   - **Privacy Policy URL**: `https://bmjaanes.github.io/chatbot/privacy.html`
   - **Beta App Review Information**: your name, phone and email. Leave "Sign-in required" unchecked; the app has no login.
2. Tap **+** next to **External Testing** and create a group, for example `Friends`.

**For each build you want them to have:**
1. In the group, open **Builds**, tap **+**, choose the build, and tap **Submit for Review**.
   The first build goes through a short **Beta App Review**, usually a few hours to a day, much lighter than full App Store
   review. The status goes from *Waiting for Review* to *Testing*. Later builds are often approved automatically.
2. Invite people either way:
   - **Public link (easiest)**: in the group, tap **Enable Public Link** and text the `testflight.apple.com/join/…` link.
     You can cap how many people can join with it.
   - **By email**: under **Testers**, tap **+**, then **Add New Testers**, and enter their email addresses.

**What your friends do:** install **TestFlight**, tap your link (or **View in TestFlight** in the email), then
**Accept** and **Install**.

**Good to know**
- Each person's places, notes and photos stay on their own phone. Nobody sees anyone else's.
- Builds expire after **90 days**. Upload a new one before then and add it to the group; TestFlight tells testers it's there.
- Testers can take a screenshot in the app to send feedback, which appears under **TestFlight → Feedback**.

### 4. Get screenshots
1. Run https://github.com/bmjaanes/chatbot/actions/workflows/screenshots.yml.
2. When it finishes, download **app-store-screenshots** from the bottom of the run page.
3. It contains the list, a reminder and the add screen, in light and dark mode. Pick 3 to 6 of them.

### 5. Fill in the App Store listing
In App Store Connect, open the app, then version **1.0**:

- **Screenshots**: drag in the files under **iPhone 6.9" Display**.
- **Promotional text**: Leave a note for the next time you're somewhere, and get reminded the moment you walk back in.
- **Description**:

  > Ever walk into a restaurant and think "what did I order last time, and was it any good?" Next Time remembers for you.
  >
  > Leave yourself a note for any place, like "Don't get the fish, the burger was great". The next time you arrive, your iPhone shows it to you.
  >
  > • Save the place you're at right now with one tap
  > • Hands full? Just say "Hey Siri, add a Next Time note"
  > • Search for any restaurant, shop or address
  > • Share a place straight from Google Maps: tap Share, then Next Time
  > • Rate places 1 to 5 stars and mark each dish 👍 or 👎
  > • Snap the menu, your order, or the receipt
  > • Sort by rating, or see your \"never again\" list at a glance
  > • Get reminded every time you return, not just once
  > • Works for anything: restaurants, hardware stores, hotels, trailheads, parking garages
  >
  > Private by design: your notes stay on your iPhone. No account, no ads, no tracking. iOS handles the arrival alerts itself, so Next Time only needs location access while you're using it and has almost no effect on battery.

- **Keywords**: `restaurant,notes,reminder,rating,places,food,dishes,photos,siri,google maps,diary,dining`
- **Support URL**: `https://bmjaanes.github.io/chatbot/support.html`
- **Marketing URL**: leave blank
- **Version / Copyright**: `1.0` / `2026` followed by your name or company
- **Build**: choose the build you uploaded.
- **App Review Information**: no sign-in required. In **Notes**, paste:

  > Next Time shows a note when the user arrives at a saved place. To test: tap +, choose Near Me, pick any place, write a note and save. Allow location and notifications. The notification is delivered by iOS (UNLocationNotificationTrigger) when the device enters the area around the place, so it appears after leaving and returning, or by simulating a location change. Places can also be added via Search or by pasting a Google Maps share link. Siri: say "Add a Next Time note" (location access must be granted in the app first). Ratings, dishes and photos are on the place screen. To add from Google Maps: open a place in Google Maps, tap Share, choose Next Time.

### 6. Fill in the app-level pages (once)
- **App Privacy**: Privacy Policy URL `https://bmjaanes.github.io/chatbot/privacy.html`. Under Data Collection, choose **No, we do not collect data from this app**.
- **Age Rating**: answer "None" to everything, which gives a rating of 4+.
- **Pricing and Availability**: Free, all countries (or whichever you want).
- **App Information**: Category **Lifestyle**, secondary **Food & Drink**.

### 7. Submit
Tap **Add for Review**, then **Submit to App Review**. Reviews usually take one to two days.
If Apple sends questions, they appear in App Store Connect under **App Review**.

## Releasing an update
1. Raise `MARKETING_VERSION` in `NextTime/NextTime.xcodeproj/project.pbxproj`, for example to `1.1`.
2. Run the **Upload to TestFlight** workflow again. Build numbers increase automatically.
3. In App Store Connect, add a new version and select the new build.

## Costs and limits to know about
- The Apple Developer Program costs $99 per year.
- **GitHub Actions on a private repo:** Mac build minutes count 10× against GitHub's free monthly allowance, which works out to about 200 Mac minutes a month. Each build takes about 3 to 10 minutes. On a public repo, Actions minutes are free.
- **Support link:** the support page links to GitHub Issues, so it only works for the public if the repo is public. Otherwise, change the Contact line in `docs/support.html` to an email address.
