const { test, expect } = require("@playwright/test");
const { failOnPageErrors, addPlace, card, cardNames, shareLinkFor, local } = require("./helpers");

test("each category has its own example note, and dishes only show for food", async ({ page }) => {
  await page.goto("index.html");
  await page.click("#add-btn");
  const examples = {
    food: "Don't get the fish. The burger was great.",
    read: "Borrow Project Hail Mary.",
    watch: "Download the new season of Severance before the flight.",
    todo: "Architecture boat tour. Deep dish at Lou Malnati's.",
  };
  for (const [category, example] of Object.entries(examples)) {
    await page.selectOption("#f-category", category);
    await expect(page.locator("#f-note")).toHaveAttribute("placeholder", example);
    await expect(page.locator("#dish-field")).toBeVisible({ visible: category === "food" });
  }
  await page.selectOption("#f-category", "");
  await expect(page.locator("#dish-field")).toBeVisible(); // no category: dishes allowed
});

test("category icons and the category filter", async ({ page }) => {
  const checkErrors = failOnPageErrors(page);
  await page.goto("index.html");
  await addPlace(page, { name: "Chicago", category: "todo", radius: 15000, note: "Boat tour." });
  await addPlace(page, { name: "Multnomah County Library", category: "read", note: "Borrow Project Hail Mary." });
  await addPlace(page, { name: "Harbor Fish House", category: "food", rating: 2 });
  await addPlace(page, { name: "Uncategorized Spot", note: "Parking on level 2." });

  await expect(card(page, "Chicago").locator(".cat-icon")).toHaveText("🎟️");
  await expect(card(page, "Multnomah County Library").locator(".cat-icon")).toHaveText("📚");
  await expect(card(page, "Harbor Fish House").locator(".cat-icon")).toHaveText("🍴");
  await expect(card(page, "Uncategorized Spot").locator(".cat-icon")).toHaveCount(0); // keeps the pin

  await page.selectOption("#category-filter", "read");
  await expect.poll(() => cardNames(page)).toEqual(["Multnomah County Library"]);
  await page.selectOption("#category-filter", "");
  await expect.poll(async () => (await cardNames(page)).length).toBe(4);
  checkErrors();
});

test("a city says \"You're in…\", keeps its size when edited, and shares it", async ({ page, browser }) => {
  await page.goto("index.html");
  await addPlace(page, { name: "Chicago", category: "todo", radius: 15000, note: "Boat tour." });
  const chicago = card(page, "Chicago");

  await chicago.getByRole("button", { name: "Simulate arrival" }).click();
  await expect(page.locator("#banner-title")).toHaveText("You're in Chicago");

  await chicago.getByRole("button", { name: "Edit" }).click();
  await expect(page.locator("#f-category")).toHaveValue("todo");
  await expect(page.locator("#f-radius")).toHaveValue("15000");
  await page.click("#cancel-btn");

  const { link } = await shareLinkFor(page, "Chicago");
  const payload = JSON.parse(Buffer.from(link.split("#p=")[1].replace(/-/g, "+").replace(/_/g, "/"), "base64").toString());
  expect(payload).toMatchObject({ n: "Chicago", c: "todo", m: 15000 });

  const friend = await (await browser.newContext()).newPage();
  await friend.goto(local(link));
  await expect(friend.locator("#card h2")).toHaveText("🎟️ Chicago");
  await friend.goto("index.html#import=" + link.split("#p=")[1]);
  await expect(friend.locator("#f-category")).toHaveValue("todo");
  await expect(friend.locator("#f-radius")).toHaveValue("15000");
});
