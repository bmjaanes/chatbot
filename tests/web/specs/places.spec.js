const { test, expect } = require("@playwright/test");
const { burgerPhoto, failOnPageErrors, openSharedFromMaps, save, addPlace, card, cardNames } = require("./helpers");

test.describe("Reading Google Maps links", () => {
  const cases = [
    {
      title: "a full place link uses the exact pin, not the map center",
      text: "https://www.google.com/maps/place/Joe's+Fish+Shack/@45.5231,-122.6765,17z/data=!3m1!4b1!4m6!3m5!1s0x1:0x1!8m2!3d45.5229!4d-122.6762",
      name: "Joe's Fish Shack",
      coords: "45.52290, -122.67620",
      message: /with its location/,
    },
    {
      title: "q= with a name and address fills both",
      text: "https://maps.google.com/?q=Joe%27s+Fish+Shack,+12+Main+St&ftid=0x1:0x1",
      name: "Joe's Fish Shack",
      address: "12 Main St",
      message: /no location/,
    },
    {
      title: "q= with coordinates sets the location",
      text: "Pizza Place\nhttps://maps.google.com/?q=40.7128,-74.0060",
      name: "Pizza Place",
      coords: "40.71280, -74.00600",
      message: /with its location/,
    },
    {
      title: "a short link keeps the name and address and explains the missing location",
      text: "Harbor Fish House\n1120 SW Front Ave, Portland\nhttps://maps.app.goo.gl/AbC123",
      name: "Harbor Fish House",
      address: "1120 SW Front Ave, Portland",
      message: /Short links don't include a location/,
    },
  ];

  for (const c of cases) {
    test(c.title, async ({ page }) => {
      const checkErrors = failOnPageErrors(page);
      await page.goto("index.html");
      await page.click("#add-btn");
      await page.fill("#f-paste", c.text);
      await page.dispatchEvent("#f-paste", "input");
      await expect(page.locator("#f-name")).toHaveValue(c.name);
      if (c.address) await expect(page.locator("#f-address")).toHaveValue(c.address);
      if (c.coords) await expect(page.locator("#coords")).toContainText(c.coords);
      await expect(page.locator("#parsed")).toHaveText(c.message);
      checkErrors();
    });
  }

  test("a link from another site is rejected", async ({ page }) => {
    await page.goto("index.html");
    await page.click("#add-btn");
    await page.fill("#f-paste", "https://example.com/somewhere");
    await page.dispatchEvent("#f-paste", "input");
    await expect(page.locator("#parsed")).toHaveText("That link isn't from Google Maps.");
  });
});

test("saving a place with a rating, dishes and a photo, and reading it back after a reload", async ({ page }) => {
  const checkErrors = failOnPageErrors(page);
  await openSharedFromMaps(page);
  await expect(page.locator("#f-name")).toHaveValue("Harbor Fish House");

  await page.click("#f-rating button:nth-child(2)");
  await page.fill("#f-note", "Ask for a booth by the window.");
  await page.fill("#f-dish", "Fish & chips");
  await page.click("#add-bad");
  await page.fill("#f-dish", "Smash burger");
  await page.click("#add-good");
  await page.setInputFiles("#f-photos", burgerPhoto);
  await expect(page.locator("#photo-edit img")).toHaveCount(1);
  await save(page);

  await page.reload();
  const harbor = card(page, "Harbor Fish House");
  await expect(harbor.locator(".stars")).toHaveText("★★☆☆☆");
  await expect(harbor.locator(".note")).toHaveText("Ask for a booth by the window.");
  await expect(harbor.locator(".dish")).toHaveText(["👎 Fish & chips", "👍 Smash burger"]);
  await expect(harbor.locator(".dish.bad")).toHaveCount(1);

  // The full-size photo comes from IndexedDB, not the small thumbnail kept with the place.
  await harbor.locator(".thumbs button").first().click();
  await expect(page.locator("#viewer")).toBeVisible();
  await expect(page.locator("#viewer-count")).toHaveText("1 of 1");
  await expect
    .poll(async () => (await page.getAttribute("#viewer-img", "src")).length)
    .toBeGreaterThan((await harbor.locator(".thumbs img").getAttribute("src")).length);
  await page.click("#viewer-close");
  await expect(page.locator("#viewer")).toBeHidden();
  checkErrors();
});

test("a place needs a name and something to remember", async ({ page }) => {
  await page.goto("index.html");
  await page.click("#add-btn");
  await page.fill("#f-name", "Empty Place");
  await page.click("#save-btn");
  await expect(page.locator("#parsed")).toHaveText(/Add a note, a rating, a dish or a photo/);
  await expect(page.locator("#sheet")).toBeVisible();
});

test("sorting and filtering by rating", async ({ page }) => {
  await page.goto("index.html");
  await addPlace(page, { name: "Harbor Fish House", rating: 2, note: "Skip the fish." });
  await addPlace(page, { name: "Luna Taqueria", rating: 5, dishes: [["Al pastor", "good"]] });
  await addPlace(page, { name: "Copper Kettle", rating: 4, note: "Oat latte." });

  await page.selectOption("#sort", "rating");
  await expect.poll(() => cardNames(page)).toEqual(["Luna Taqueria", "Copper Kettle", "Harbor Fish House"]);
  await page.selectOption("#sort", "name");
  await expect.poll(() => cardNames(page)).toEqual(["Copper Kettle", "Harbor Fish House", "Luna Taqueria"]);

  await page.click('[data-filter="never"]');
  await expect.poll(() => cardNames(page)).toEqual(["Harbor Fish House"]);
  await page.click('[data-filter="loved"]');
  await expect.poll(() => cardNames(page)).toEqual(["Copper Kettle", "Luna Taqueria"]);
  await page.click('[data-filter="all"]');

  // Search looks at names, notes and dishes.
  await page.fill("#q", "pastor");
  await expect.poll(() => cardNames(page)).toEqual(["Luna Taqueria"]);
});

test("editing, pausing and deleting a place", async ({ page }) => {
  await page.goto("index.html");
  await addPlace(page, { name: "Harbor Fish House", note: "Skip the fish." });
  const harbor = card(page, "Harbor Fish House");

  await harbor.getByRole("button", { name: "Edit" }).click();
  await page.fill("#f-note", "Burger was great.");
  await save(page);
  await expect(harbor.locator(".note")).toHaveText("Burger was great.");

  const pausedTag = harbor.locator(".tag", { hasText: /^Paused$/ });
  await harbor.getByRole("button", { name: "Pause", exact: true }).click();
  await expect(pausedTag).toBeVisible();
  await harbor.getByRole("button", { name: "Resume", exact: true }).click();
  await expect(pausedTag).toHaveCount(0);
  await expect(harbor.getByRole("button", { name: "Pause", exact: true })).toBeVisible();

  // Delete asks for a second tap.
  await harbor.getByRole("button", { name: "Delete" }).click();
  await expect(harbor.getByRole("button", { name: "Tap again to delete" })).toBeVisible();
  await harbor.getByRole("button", { name: "Tap again to delete" }).click();
  await expect(page.locator(".stub h2")).toHaveText(["Joe's Fish Shack"]); // only the example card is left
});

test.describe("near-me alerts", () => {
  test.use({ geolocation: { latitude: 45.5229, longitude: -122.6762 }, permissions: ["geolocation"] });

  test("arriving at a saved place shows the alert with the note, stars and dishes", async ({ page }) => {
    await openSharedFromMaps(page,
      "Harbor Fish House\nhttps://www.google.com/maps/place/Harbor+Fish+House/@45.52,-122.67,17z/data=!3d45.5229!4d-122.6762");
    await page.click("#f-rating button:nth-child(2)");
    await page.fill("#f-note", "Skip the fish.");
    await page.fill("#f-dish", "Smash burger");
    await page.click("#add-good");
    await save(page);

    await page.reload(); // location permission is already granted, so watching starts on load
    await expect(page.locator("#loc-text")).toHaveText(/Watching for places/);
    await expect(card(page, "Harbor Fish House").getByText("You're here")).toBeVisible();
    await expect(page.locator("#banner")).toHaveClass(/show/);
    await expect(page.locator("#banner-title")).toHaveText("Back at Harbor Fish House  ★★☆☆☆");
    await expect(page.locator("#banner-body")).toHaveText("Skip the fish. · 👍 Smash burger");
  });
});
