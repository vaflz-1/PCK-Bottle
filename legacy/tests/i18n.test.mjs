import test from "node:test";
import assert from "node:assert/strict";

import { LOCALES, normalizeLocale, translate } from "../src/i18n.js";

test("i18n exposes Russian, English, and Chinese locales", () => {
  assert.deepEqual(LOCALES, ["ru", "en", "zh"]);
});

test("normalizeLocale accepts region-specific language tags", () => {
  assert.equal(normalizeLocale("ru-RU"), "ru");
  assert.equal(normalizeLocale("en-US"), "en");
  assert.equal(normalizeLocale("zh-CN"), "zh");
  assert.equal(normalizeLocale("fr-FR"), "en");
});

test("translate returns localized UI labels with English fallback", () => {
  assert.equal(translate("ru", "filesTitle"), "Файлы для переноса");
  assert.equal(translate("en", "filesTitle"), "Files to place");
  assert.equal(translate("zh", "filesTitle"), "待放入文件");
  assert.equal(translate("zh", "missingKey"), "missingKey");
});
