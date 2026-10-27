# Next Time

An iPhone app for leaving notes to your future self about places.
Save *"Don't get the fish"* at a restaurant and the next time you walk in, your phone reminds you.

## How it works

1. **Pick a place**, three ways:
   - **Near Me**: lists restaurants, shops, etc. around you right now (the "I'm sitting here, don't get the fish" case), plus your exact spot.
   - **Search**: type a name or address (Apple Maps search, no API key needed).
   - **Google Maps**: in the Google Maps app, open the place, tap **Share → Copy**, then paste the link into Next Time. Short links (`maps.app.goo.gl/...`), full `google.com/maps/place/...` links, and `?q=` links are all supported.
2. **Write the note** and choose how close you need to be (100–500 m).
3. **Walk back in, get a notification.** It fires on every visit, not just the next one. Tap it to open the note.

From any saved reminder you can tap **Open in Google Maps** to jump back to the place.

### Ratings, dishes and photos

Each place has a 1–5 star rating, a list of dishes marked 👍 (get again) or 👎 (skip), and photos from the camera or
photo library, such as menus, receipts or screenshots. The arrival notification shows the stars and the dishes. On the home
screen you can sort by rating and filter to "Loved" (4–5 ★) or "Never Again" (1–2 ★) places. Photos are stored on the
phone next to the reminders, downscaled to 2048 px.

### Share from Google Maps

In Google Maps, open a place, tap **Share**, then **Next Time**. The Share extension (`ShareExtension/`) reads the
link Google Maps shares, finds the place, and lets you add a rating and note without opening the app. The app and the
extension share code (`Shared/`) and data (an App Group, `group.com.bmjaanes.nexttime`).

### iCloud backup and sync

Places, ratings, dishes and photos are copied to the user's own iCloud Drive (a private app container that doesn't show
in the Files app) and synced across their devices (`NextTime/Sync/CloudSync.swift`). Each place is one JSON file and each
photo one JPEG, so edits to different places never conflict; for the same place, the newer edit wins. The app always works
from its local copy. A line at the bottom of the list shows when it last backed up; tap it to back up now. It needs the
user signed in to iCloud with iCloud Drive on.

### Share a place with a friend

**Share with a Friend** (on a place, or long-press it in the list) sends a link to `docs/share.html` with the place's
name, location, rating, note and dishes encoded after the `#` (`Shared/Models/SharedPlace.swift`; never photos). The page
shows the place and offers **Save in the Next Time app** (`nexttime://import#p=…`, opening a prefilled new place) or
**Save in the web app**. The web app reads and writes the same format.

### Siri

Say **"Hey Siri, add a Next Time note"** (or "Remember this place in Next Time"), or **"Rate this place 4 stars in Next Time"**. Siri asks what to remember,
then the note is saved for the business you're at. If there's no business within 60 m, it's saved for the street
address. If you already have a note within 40 m, the new one is added to it. This also works from the Shortcuts app
and the Action button. Location access has to be allowed in the app once first, because Siri can't show that prompt.

### Under the hood

- **Geofencing is done by iOS**, using `UNLocationNotificationTrigger`. The app doesn't run in the background, doesn't track you, and only needs *"While Using the App"* location permission.
- **All data stays on the phone** (a JSON file in Application Support). No accounts, no servers.
- **Google Maps links are parsed locally** (`GoogleMapsLinkParser.swift`). The parser prefers the place's exact pin (`!3d…!4d…`) over where the map happened to be centered (`@lat,lng`). If a link has no coordinates, the place is looked up by name with Apple Maps.

## Publishing to the App Store

See [`APP_STORE.md`](../APP_STORE.md): builds, signing, screenshots and upload all run on GitHub Actions, so no Mac is required.

## Running it

Requirements: a Mac with **Xcode 16 or newer**, and an iPhone on **iOS 17 or newer**.

1. Open `NextTime/NextTime.xcodeproj` in Xcode.
2. Select the **NextTime** target, open **Signing & Capabilities**, and pick your **Team** (a free Apple ID works for running on your own phone).
   If Xcode complains about the bundle ID, change `com.bmjaanes.nexttime` to something unique.
3. Plug in your iPhone, select it as the run destination, and press **⌘R**.
4. On the phone, allow **Location (While Using)** and **Notifications** when asked.

### Testing without leaving your desk

In the Simulator: save a reminder for a place, then use **Features → Location → Custom Location…** to move somewhere far away, and then back to the place's coordinates. The notification should appear when you "arrive". (On a real phone, geofences usually trigger within a minute or two of walking in.)

## Limits worth knowing

- iOS allows **64 scheduled notifications per app**, so at most 64 places are active at once. Extra reminders are saved but stay silent until you turn others off.
- Geofences are approximate. Very small radii are less reliable, which is why the smallest option is 100 m. Next door to a place you'll sometimes get a false alarm.
- If you save a reminder while standing inside the place, iOS usually waits until you leave and come back before notifying you.

## Project layout

```
NextTime/
├── NextTimeApp.swift              App entry, notification tap handling
├── Models/PlaceReminder.swift     The reminder + picked-place types
├── Services/
│   ├── ReminderStore.swift        Saves reminders, keeps notifications in sync
│   ├── NotificationScheduler.swift  Location-triggered notifications
│   ├── LocationService.swift      "Where am I?" (one-shot)
│   ├── PlaceFinder.swift          Apple Maps nearby/search/reverse-geocode
│   ├── GoogleMapsLinkParser.swift Pulls name/coords from Google Maps URLs
│   └── GoogleMapsImporter.swift   Expands short links, turns a link into a place
└── Views/
    ├── RemindersListView.swift    Home screen
    ├── AddReminderView.swift      Near Me / Search / Google Maps pickers
    └── ReminderEditorView.swift   Note, radius, map preview
```

## Ideas for next steps

- **Share Extension**, so you can tap *Share → Next Time* straight from Google Maps instead of copy/paste.
- Several notes per place, with ratings ("🐟 👎  🍔 👍").
- iCloud sync across devices.
- Google Places SDK for search, if you'd rather see Google's place data than Apple's (needs a Google Cloud API key).
