// Regenerates the PowerPoint, Excel and CSV fixtures in CheeseTests/Fixtures/Files.
//
// The generators are dev-only and never bundled with Cheese. Install them in a scratch folder
// (not the repo) and run this script from there:
//
//   mkdir /tmp/cheese-fixtures && cd /tmp/cheese-fixtures
//   npm install pptxgenjs@4.0.1 https://cdn.sheetjs.com/xlsx-0.20.3/xlsx-0.20.3.tgz
//   node ~/Cheese/Design/make-files-fixtures.mjs ~/Cheese/CheeseTests/Fixtures/Files
//
//   deck.pptx     3 slides at 16:9: a title slide, a bulleted slide, a slide with a shape and a table
//   budget.xlsx   2 sheets: "Budget" (text, numbers, a date column) and "Team" (names and roles)
//   data.csv      a small comma-separated table
//
// make-files-fixtures.swift makes the PDF, Word and HEIC fixtures.
import { createRequire } from "node:module";
import { writeFileSync, mkdirSync } from "node:fs";
import { join } from "node:path";

const require = createRequire(join(process.cwd(), "/"));
const PptxGenJS = require("pptxgenjs");
const XLSX = require("xlsx");

const out = process.argv[2];
if (!out) {
  console.error("usage: node make-files-fixtures.mjs <output folder>");
  process.exit(1);
}
mkdirSync(out, { recursive: true });

// PowerPoint
const deck = new PptxGenJS();
deck.layout = "LAYOUT_16x9";
deck.title = "Cheese fixture deck";

const title = deck.addSlide();
title.background = { color: "1F3A5F" };
title.addText("Launch Review", { x: 0.5, y: 1.8, w: 9, h: 1, fontSize: 40, bold: true, color: "FFFFFF", align: "center" });
title.addText("Files module, spring release", { x: 0.5, y: 2.9, w: 9, h: 0.6, fontSize: 20, color: "DDE6F0", align: "center" });

const bullets = deck.addSlide();
bullets.addText("What shipped", { x: 0.5, y: 0.3, w: 9, h: 0.8, fontSize: 30, bold: true, color: "1F3A5F" });
bullets.addText(
  [
    { text: "Merge, split and compress PDFs", options: { bullet: true } },
    { text: "Convert Office documents offline", options: { bullet: true } },
    { text: "Remove photo backgrounds on device", options: { bullet: true } },
  ],
  { x: 0.7, y: 1.3, w: 8.5, h: 2.5, fontSize: 22, color: "333333" },
);

const shapes = deck.addSlide();
shapes.addText("Numbers", { x: 0.5, y: 0.3, w: 9, h: 0.8, fontSize: 30, bold: true, color: "1F3A5F" });
shapes.addShape(deck.ShapeType.roundRect, { x: 0.5, y: 1.3, w: 3.5, h: 2, fill: { color: "F4B942" }, rectRadius: 0.2 });
shapes.addText("98% offline", { x: 0.5, y: 1.9, w: 3.5, h: 0.8, fontSize: 24, bold: true, align: "center", color: "1F3A5F" });
shapes.addTable(
  [
    [{ text: "Tool", options: { bold: true } }, { text: "Uses", options: { bold: true } }],
    ["Merge", "1,204"],
    ["Compress", "877"],
  ],
  { x: 4.5, y: 1.3, w: 5, fontSize: 16, border: { type: "solid", color: "999999", pt: 1 } },
);

await deck.writeFile({ fileName: join(out, "deck.pptx") });
console.log("wrote deck.pptx");

// Excel
const budget = XLSX.utils.aoa_to_sheet([
  ["Category", "Planned", "Actual", "Due"],
  ["Hardware", 12000, 11450.5, new Date(Date.UTC(2026, 0, 31))],
  ["Software", 4800, 5100, new Date(Date.UTC(2026, 1, 28))],
  ["Travel", 3000, 2210.25, new Date(Date.UTC(2026, 2, 31))],
  ["Total", { f: "SUM(B2:B4)" }, { f: "SUM(C2:C4)" }, ""],
], { cellDates: true });
const team = XLSX.utils.aoa_to_sheet([
  ["Name", "Role"],
  ["Asha", "Engineering"],
  ["Ben", "Design"],
  ["Chen", "Support"],
]);
const book = XLSX.utils.book_new();
XLSX.utils.book_append_sheet(book, budget, "Budget");
XLSX.utils.book_append_sheet(book, team, "Team");
XLSX.writeFile(book, join(out, "budget.xlsx"), { compression: true });
console.log("wrote budget.xlsx");

writeFileSync(join(out, "data.csv"), "City,Population,Founded\nMumbai,12442373,1507\nDelhi,11034555,1052\nPune,3124458,1689\n");
console.log("wrote data.csv");
