(() => {
  const menuButton = document.querySelector(".menu-button");
  const navigation = document.querySelector(".site-nav");
  const siteHeader = document.querySelector(".site-header");

  const syncMobileMenuTop = () => {
    if (!navigation || !siteHeader || window.innerWidth > 760) return;
    const top = Math.max(0, Math.round(siteHeader.getBoundingClientRect().bottom));
    navigation.style.setProperty("--mobile-nav-top", `${top}px`);
  };

  const closeMenu = () => {
    if (!menuButton || !navigation) return;
    menuButton.setAttribute("aria-expanded", "false");
    menuButton.querySelector(".sr-only").textContent = "Open navigation";
    navigation.classList.remove("open");
    document.body.classList.remove("nav-open");
  };

  if (menuButton && navigation) {
    menuButton.addEventListener("click", () => {
      const opening = menuButton.getAttribute("aria-expanded") !== "true";
      if (opening) syncMobileMenuTop();
      menuButton.setAttribute("aria-expanded", String(opening));
      menuButton.querySelector(".sr-only").textContent = opening
        ? "Close navigation"
        : "Open navigation";
      navigation.classList.toggle("open", opening);
      document.body.classList.toggle("nav-open", opening);
    });

    navigation.addEventListener("click", (event) => {
      if (event.target.closest("a")) closeMenu();
    });

    window.addEventListener("resize", () => {
      if (window.innerWidth > 760) {
        closeMenu();
      } else if (menuButton.getAttribute("aria-expanded") === "true") {
        syncMobileMenuTop();
      }
    });

    window.addEventListener("scroll", () => {
      if (menuButton.getAttribute("aria-expanded") === "true") syncMobileMenuTop();
    }, { passive: true });

    document.addEventListener("keydown", (event) => {
      if (event.key === "Escape" && menuButton.getAttribute("aria-expanded") === "true") {
        closeMenu();
        menuButton.focus();
      }
    });
  }

  const writeClipboard = async (text) => {
    if (navigator.clipboard && window.isSecureContext) {
      try {
        await navigator.clipboard.writeText(text);
        return;
      } catch {
        // Fall through for browsers that expose the API but deny permission.
      }
    }

    const textarea = document.createElement("textarea");
    textarea.value = text;
    textarea.setAttribute("readonly", "");
    textarea.style.position = "fixed";
    textarea.style.opacity = "0";
    document.body.appendChild(textarea);
    textarea.select();
    const copied = document.execCommand("copy");
    textarea.remove();
    if (!copied) throw new Error("Copy command was rejected");
  };

  const showCopied = (button) => {
    const label = button.querySelector("[data-copy-label]") || button;
    const original = label.textContent;
    const originalAriaLabel = button.getAttribute("aria-label");
    const feedback = document.querySelector("[data-copy-feedback]");
    label.textContent = "Copied";
    button.setAttribute("aria-label", "Copied");
    button.classList.add("copied");
    if (feedback) feedback.textContent = "Copied to clipboard.";
    window.setTimeout(() => {
      label.textContent = original;
      if (originalAriaLabel) button.setAttribute("aria-label", originalAriaLabel);
      else button.removeAttribute("aria-label");
      button.classList.remove("copied");
      if (feedback) feedback.textContent = "";
    }, 1800);
  };

  document.querySelectorAll("[data-copy-target]").forEach((button) => {
    button.addEventListener("click", async () => {
      const target = document.querySelector(button.dataset.copyTarget);
      if (!target) return;
      try {
        await writeClipboard(target.textContent.trim());
        showCopied(button);
      } catch {
        const status = document.querySelector("[data-copy-status]");
        if (status) status.textContent = "Copy failed. Select the command and copy it manually.";
      }
    });
  });

  const codeTabs = [...document.querySelectorAll("[data-code-tab]")];
  const codePanels = [...document.querySelectorAll("[data-code-panel]")];
  const codeFilename = document.querySelector("[data-code-filename]");
  const filenames = {
    runtime: "hello.ts",
    server: "server.ts",
    test: "math.test.ts",
    file: "files.ts",
  };

  const selectCodeTab = (tab, moveFocus = false) => {
    const key = tab.dataset.codeTab;
    codeTabs.forEach((candidate) => {
      const active = candidate === tab;
      candidate.setAttribute("aria-selected", String(active));
      candidate.tabIndex = active ? 0 : -1;
    });
    codePanels.forEach((panel) => {
      panel.hidden = panel.dataset.codePanel !== key;
    });
    if (codeFilename) codeFilename.textContent = filenames[key];
    if (moveFocus) tab.focus();
  };

  codeTabs.forEach((tab, index) => {
    tab.addEventListener("click", () => selectCodeTab(tab));
    tab.addEventListener("keydown", (event) => {
      let nextIndex = null;
      if (event.key === "ArrowDown" || event.key === "ArrowRight") {
        nextIndex = (index + 1) % codeTabs.length;
      } else if (event.key === "ArrowUp" || event.key === "ArrowLeft") {
        nextIndex = (index - 1 + codeTabs.length) % codeTabs.length;
      } else if (event.key === "Home") {
        nextIndex = 0;
      } else if (event.key === "End") {
        nextIndex = codeTabs.length - 1;
      }

      if (nextIndex !== null) {
        event.preventDefault();
        selectCodeTab(codeTabs[nextIndex], true);
      }
    });
  });

  const codeCopyButton = document.querySelector("[data-copy-code]");
  if (codeCopyButton) {
    codeCopyButton.addEventListener("click", async () => {
      const panel = codePanels.find((candidate) => !candidate.hidden);
      if (!panel) return;
      try {
        await writeClipboard(panel.textContent.trim());
        showCopied(codeCopyButton);
      } catch {
        codeCopyButton.textContent = "Failed";
        window.setTimeout(() => {
          codeCopyButton.textContent = "Copy";
        }, 1800);
      }
    });
  }
})();
