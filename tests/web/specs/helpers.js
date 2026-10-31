const path = require("path");
const fs = require("fs");
const { expect } = require("@playwright/test");

/** Share links that the iPhone app and the web app must both read the same way. */
const sharedPlaces = JSON.parse(
  fs.readFileSync(path.join(__dirname, "../../../NextTime/NextTimeTests/Fixtures/shared-places.json"), "utf8")
);

const burgerPhoto = path.join(__dirname, "../fixtures/burger.jpg");

const FULL_MAPS_LINK =
  "Harbor Fish House\nhttps://www.google.com/maps/place/Harbor+Fish+House/@45.515,-122.67,17z/data=!3m1!4b1!8m2!3d45.5150!4d-122.6745";

/** Fails the test on any uncaught error in the page. */
function failOnPageErrors(page) {
  const errors = [];
  page.on("pageerror", (e) => errors.push(e.message));
  return () => expect(errors, "errors thrown in the page").toEqual([]);
}

/** Opens the add sheet with a Google Maps share already pasted in (the "Save to Next Time" shortcut path). */
async function openSharedFromMaps(page, text = FULL_MAPS_LINK) {
  await page.goto("index.html?share=" + encodeURIComponent(text));
  await expect(page.locator("#sheet")).toBeVisible();
}

async function save(page) {
  await page.click("#save-btn");
  await expect(page.locator("#sheet")).toBeHidden();
}

/** Adds a place by hand through the sheet. */
async function addPlace(page, { name, note = "", category, radius, rating, dishes = [] }) {
  await page.click("#add-btn");
  await page.fill("#f-name", name);
  if (category) await page.selectOption("#f-category", category);
  if (radius) await page.selectOption("#f-radius", String(radius));
  if (rating) await page.click(`#f-rating button:nth-child(${rating})`);
  for (const [dish, verdict] of dishes) {
    await page.fill("#f-dish", dish);
    await page.click(verdict === "bad" ? "#add-bad" : "#add-good");
  }
  if (note) await page.fill("#f-note", note);
  await save(page);
}

const card = (page, name) => page.locator(".stub", { has: page.locator("h2", { hasText: name }) });
const cardNames = (page) => page.locator(".stub h2").allTextContents();

/** The share link a card produces (no share sheet in tests, so it goes to the clipboard). */
async function shareLinkFor(page, name) {
  await page.evaluate(() => { navigator.share = undefined; });
  await card(page, name).getByRole("button", { name: "Share" }).click();
  await expect(page.locator("#banner-title")).toHaveText("Link copied");
  const copied = await page.evaluate(() => navigator.clipboard.readText());
  return { text: copied, link: copied.split("\n").pop() };
}

/** The values typed into a list of text boxes, e.g. the dish rows. */
const inputValues = (locator) => locator.evaluateAll((els) => els.map((e) => e.value));

/** share.html links point at GitHub Pages; tests serve the same files locally. */
const local = (link) => link.replace("https://bmjaanes.github.io/chatbot/", "");

module.exports = {
  sharedPlaces, burgerPhoto, FULL_MAPS_LINK, failOnPageErrors, openSharedFromMaps, save, addPlace,
  card, cardNames, shareLinkFor, local, inputValues,
};
