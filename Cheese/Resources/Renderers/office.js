// Glue between Cheese and the vendored renderers. Swift calls Cheese.render(kind, base64, paper);
// when the pages are laid out, the result is posted to the "cheese" message handler as
// { ok, pages: [{ width, height }] } or { ok: false, error }.
"use strict";

window.Cheese = {
    pages: [],

    post(result) {
        window.webkit.messageHandlers.cheese.postMessage(result);
    },

    bytes(base64) {
        const binary = atob(base64);
        const bytes = new Uint8Array(binary.length);
        for (let i = 0; i < binary.length; i++) {
            bytes[i] = binary.charCodeAt(i);
        }
        return bytes.buffer;
    },

    escape(text) {
        return String(text).replace(/[&<>"]/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", "\"": "&quot;" })[c]);
    },

    // Waits for images and fonts so nothing is captured half-loaded.
    async settle(root) {
        const images = Array.from(root.querySelectorAll("img"));
        await Promise.all(images.map((img) => img.complete ? null : new Promise((done) => {
            img.onload = done;
            img.onerror = done;
        })));
        if (document.fonts) {
            await document.fonts.ready;
        }
    },

    sizes() {
        return this.pages.map((page) => {
            const rect = page.getBoundingClientRect();
            return { width: rect.width, height: rect.height };
        });
    },

    async renderWord(data, paper) {
        const container = document.getElementById("pages");
        await docx.renderAsync(this.bytes(data), container, document.getElementById("styles"), {
            inWrapper: true,
            breakPages: true,
            experimental: true,
            useBase64URL: true,
            renderHeaders: true,
            renderFooters: true,
            renderFootnotes: true,
            renderEndnotes: true,
        });
        this.pages = Array.from(container.querySelectorAll("section.docx"));
        // Documents without section properties get no page size; give them the default paper.
        for (const page of this.pages) {
            if (!page.style.width) {
                page.style.width = `${paper.width}pt`;
                page.style.minHeight = `${paper.height}pt`;
                page.style.padding = "72pt";
                page.style.boxSizing = "border-box";
            }
        }
        await this.settle(container);
        return this.sizes();
    },

    async renderPowerPoint(data) {
        if (typeof window.pptxToHtml !== "function") {
            throw new Error("The PowerPoint renderer didn't load.");
        }
        const container = document.getElementById("pages");
        const slides = await window.pptxToHtml(this.bytes(data), {});
        container.innerHTML = slides.map((html) => `<section class="slide">${html}</section>`).join("");
        this.pages = Array.from(container.querySelectorAll("section.slide"));
        await this.settle(container);
        // Each slide's own root element has its size; the section just wraps it.
        return this.pages.map((page) => {
            const root = page.firstElementChild || page;
            const rect = root.getBoundingClientRect();
            return { width: rect.width, height: rect.height };
        });
    },

    // Values, not styling: SheetJS Community Edition reads cell values and number formats only.
    async renderExcel(data) {
        const book = XLSX.read(data, { type: "base64", cellDates: true });
        const container = document.getElementById("pages");
        container.innerHTML = book.SheetNames.map((name) => {
            const table = XLSX.utils.sheet_to_html(book.Sheets[name], { header: "", footer: "" });
            return `<section class="sheet"><h2>${this.escape(name)}</h2>${table}</section>`;
        }).join("");
        this.pages = Array.from(container.querySelectorAll("section.sheet"));
        return this.sizes();
    },

    async render(kind, data, paper) {
        try {
            let pages;
            switch (kind) {
            case "word": pages = await this.renderWord(data, paper); break;
            case "powerPoint": pages = await this.renderPowerPoint(data); break;
            case "excel": pages = await this.renderExcel(data); break;
            default: throw new Error(`Unknown document kind ${kind}`);
            }
            this.post({ ok: true, pages });
        } catch (error) {
            this.post({ ok: false, error: String((error && error.message) || error) });
        }
    },

    // Shows page `index` alone at the top left and returns its rect in CSS pixels, plus the page
    // height a Word section was meant to have (docx-preview lets long sections grow past it).
    showOnly(index) {
        this.pages.forEach((page, i) => { page.style.display = i === index ? "" : "none"; });
        window.scrollTo(0, 0);
        const page = this.pages[index];
        const target = page.classList.contains("slide") ? (page.firstElementChild || page) : page;
        const rect = target.getBoundingClientRect();
        const minHeight = parseFloat(getComputedStyle(page).minHeight) || 0;
        return { x: rect.left + window.scrollX, y: rect.top + window.scrollY, width: rect.width, height: rect.height, pageHeight: minHeight };
    },
};
