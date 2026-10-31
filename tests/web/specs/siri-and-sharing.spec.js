const { test, expect } = require("@playwright/test");
const { sharedPlaces, failOnPageErrors, addPlace, card, cardNames, shareLinkFor, local, save, inputValues } = require("./helpers");

test.describe("notes from the Siri shortcut", () => {
  const note = (text, extra = "") => `index.html?note=${encodeURIComponent(text)}${extra}`;

  test("saves a note for the place, and a second note nearby adds to it", async ({ page }) => {
    const checkErrors = failOnPageErrors(page);
    await page.goto(note("Don't get the fish", "&name=Harbor%20Fish%20House&lat=45.5150&lng=-122.6745"));
    await expect(page.locator("#banner-title")).toHaveText("Saved for Harbor Fish House");
    expect(new URL(page.url()).search).toBe(""); // reloading must not save it twice

    // About 2 m away: the same place.
    await page.goto(note("Burger was great", "&name=Somewhere&lat=45.51502&lng=-122.67452"));
    await expect(page.locator("#banner-title")).toHaveText("Added to Harbor Fish House");
    await expect(card(page, "Harbor Fish House").locator(".note")).toHaveText("Don't get the fish\nBurger was great");
    await expect.poll(() => cardNames(page)).toEqual(["Harbor Fish House"]);
    checkErrors();
  });

  test("a note without a place name opens the editor to name it", async ({ page }) => {
    await page.goto(note("Ask for Dana", "&lat=45.54&lng=-122.66"));
    await expect(page.locator("#sheet")).toBeVisible();
    await expect(page.locator("#f-name")).toHaveValue("Saved spot");
    await expect(page.locator("#f-note")).toHaveValue("Ask for Dana");
  });
});

test("sharing a place from one friend's web app to another's", async ({ browser }) => {
  // Friend A saves and shares a place.
  const a = await (await browser.newContext({ permissions: ["clipboard-read", "clipboard-write"] })).newPage();
  const checkA = failOnPageErrors(a);
  await a.goto("index.html");
  await addPlace(a, {
    name: "Harbor Fish House", rating: 2, note: "Ask for a booth by the window.",
    dishes: [["Fish & chips", "bad"], ["Smash burger", "good"]],
  });
  const { text, link } = await shareLinkFor(a, "Harbor Fish House");
  expect(text.split("\n").slice(0, -1)).toEqual([
    "Harbor Fish House ★★☆☆☆", "Ask for a booth by the window.", "👎 Fish & chips · 👍 Smash burger",
  ]);
  expect(link).toMatch(/^https:\/\/bmjaanes\.github\.io\/chatbot\/share\.html#p=[A-Za-z0-9_-]+$/);
  checkA();

  // Friend B, with an empty web app, opens the link and saves it.
  const b = await (await browser.newContext()).newPage();
  const checkB = failOnPageErrors(b);
  await b.goto(local(link));
  await expect(b.locator("#card h2")).toHaveText("Harbor Fish House");
  await expect(b.locator("#card .stars")).toHaveText("★★☆☆☆");
  await b.click("#open-web");
  await expect(b.locator("#sheet-title")).toHaveText("Place from a friend");
  await expect(b.locator("#f-name")).toHaveValue("Harbor Fish House");
  await expect(b.locator("#f-note")).toHaveValue("Ask for a booth by the window.");
  await expect(b.locator("#f-rating .on")).toHaveCount(2);
  await expect.poll(() => inputValues(b.locator("#dish-rows input"))).toEqual(["Fish & chips", "Smash burger"]);
  await save(b);
  await expect.poll(() => cardNames(b)).toEqual(["Harbor Fish House"]);
  checkB();
});

test.describe("links made by the iPhone app", () => {
  for (const [key, place] of Object.entries(sharedPlaces).filter(([k]) => !k.startsWith("_"))) {
    test(`share page shows the ${key} link like the app sent it`, async ({ page }) => {
      const checkErrors = failOnPageErrors(page);
      const e = place.expected;
      await page.goto(local(place.link));
      await expect(page.locator("#card h2")).toContainText(e.name);
      if (e.rating) await expect(page.locator("#card .stars")).toHaveText("★".repeat(e.rating) + "☆".repeat(5 - e.rating));
      await expect(page.locator("#card .addr")).toHaveText(e.address);
      await expect(page.locator("#card .note")).toHaveText(e.note);
      await expect(page.locator("#card .dish")).toHaveText(e.dishes.map((d) => (d.good ? "👍 " : "👎 ") + d.name));
      await expect(page.locator("#open-app")).toHaveAttribute("href", /^nexttime:\/\/import#p=/);
      checkErrors();
    });

    test(`web app imports the ${key} link with every field`, async ({ page }) => {
      const e = place.expected;
      await page.goto("index.html#import=" + place.link.split("#p=")[1]);
      await expect(page.locator("#f-name")).toHaveValue(e.name);
      await expect(page.locator("#f-address")).toHaveValue(e.address);
      await expect(page.locator("#f-note")).toHaveValue(e.note);
      await expect(page.locator("#coords")).toContainText(`${e.latitude.toFixed(5)}, ${e.longitude.toFixed(5)}`);
      await expect(page.locator("#f-rating .on")).toHaveCount(e.rating || 0);
      await expect(page.locator("#f-category")).toHaveValue(e.category || "");
      await expect(page.locator("#f-radius")).toHaveValue(String(e.radius || 150));
      await expect.poll(() => inputValues(page.locator("#dish-rows input"))).toEqual(e.dishes.map((d) => d.name));
    });
  }
});

test("broken and empty share links explain what happened", async ({ page }) => {
  for (const hash of ["#p=abc", "", "#p=e30"]) {
    await page.goto("share.html" + hash);
    await page.reload(); // a hash-only change doesn't reload the page by itself
    await expect(page.getByRole("heading", { name: "This link is incomplete" })).toBeVisible();
    await expect(page.locator("#place")).toBeHidden();
  }
});
