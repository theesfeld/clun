/* Clun site — nav, copy, code tabs, GitHub stats. No cinematic scroll. */
(() => {
  "use strict";

  const $ = (sel, root = document) => root.querySelector(sel);
  const $$ = (sel, root = document) => [...root.querySelectorAll(sel)];

  /* Mobile nav */
  const menuBtn = $(".menu-button");
  const siteNav = $("#site-nav");
  if (menuBtn && siteNav) {
    menuBtn.addEventListener("click", () => {
      const open = siteNav.classList.toggle("is-open");
      menuBtn.setAttribute("aria-expanded", open ? "true" : "false");
    });
    siteNav.querySelectorAll("a").forEach((a) => {
      a.addEventListener("click", () => {
        siteNav.classList.remove("is-open");
        menuBtn.setAttribute("aria-expanded", "false");
      });
    });
  }

  /* Copy buttons */
  const setCopyLabel = (btn, text) => {
    const label = btn.querySelector("[data-copy-label]");
    if (label) label.textContent = text;
    else btn.textContent = text;
  };

  const copyText = async (text, btn) => {
    try {
      await navigator.clipboard.writeText(text);
      setCopyLabel(btn, "Copied");
      const status = $("[data-copy-status]");
      if (status) status.textContent = "Copied to clipboard.";
      const feedback = $("[data-copy-feedback]");
      if (feedback) feedback.textContent = "Copied to clipboard.";
      setTimeout(() => setCopyLabel(btn, "Copy"), 1600);
    } catch {
      setCopyLabel(btn, "Failed");
      setTimeout(() => setCopyLabel(btn, "Copy"), 1600);
    }
  };

  $$("[data-copy-target]").forEach((btn) => {
    btn.addEventListener("click", () => {
      const target = $(btn.getAttribute("data-copy-target"));
      if (!target) return;
      copyText(target.textContent.trim(), btn);
    });
  });

  /* Code tabs */
  const tabs = $$("[data-code-tab]");
  const panels = $$("[data-code-panel]");
  const filename = $("[data-code-filename]");
  const names = {
    runtime: "hello.ts",
    server: "server.ts",
    test: "example.test.ts",
    file: "write.ts",
  };

  const selectTab = (id) => {
    tabs.forEach((tab) => {
      const on = tab.dataset.codeTab === id;
      tab.setAttribute("aria-selected", on ? "true" : "false");
      tab.tabIndex = on ? 0 : -1;
    });
    panels.forEach((panel) => {
      panel.hidden = panel.dataset.codePanel !== id;
    });
    if (filename && names[id]) filename.textContent = names[id];
  };

  tabs.forEach((tab) => {
    tab.addEventListener("click", () => selectTab(tab.dataset.codeTab));
  });

  const copyCodeBtn = $("[data-copy-code]");
  if (copyCodeBtn) {
    copyCodeBtn.addEventListener("click", () => {
      const active = panels.find((p) => !p.hidden) || panels[0];
      if (!active) return;
      copyText(active.innerText.trim(), copyCodeBtn);
    });
  }

  /* Version from Cloudflare R2 current channel (no GitHub API) */
  const setAll = (sel, value) => {
    $$(sel).forEach((el) => {
      el.textContent = value;
    });
  };

  fetch("https://dist.f00.sh/clun/current/VERSION", { cache: "no-cache" })
    .then((r) => (r.ok ? r.text() : null))
    .then((text) => {
      if (!text) return;
      const ver = String(text).trim().replace(/^v/i, "");
      if (ver) setAll("[data-version]", `v${ver}`);
    })
    .catch(() => {});
})();
