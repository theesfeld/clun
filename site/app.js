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
    const menuLinks = [...navigation.querySelectorAll("a[href]")];

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
      if (menuButton.getAttribute("aria-expanded") !== "true") return;

      if (event.key === "Escape") {
        closeMenu();
        menuButton.focus();
        return;
      }

      if (event.key === "Tab" && menuLinks.length > 0) {
        const first = menuButton;
        const last = menuLinks[menuLinks.length - 1];
        if (event.shiftKey && document.activeElement === first) {
          event.preventDefault();
          last.focus();
        } else if (!event.shiftKey && document.activeElement === last) {
          event.preventDefault();
          first.focus();
        } else if (!first.contains(document.activeElement) &&
                   !navigation.contains(document.activeElement)) {
          event.preventDefault();
          (event.shiftKey ? last : first).focus();
        }
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

  // Scroll reveals + sticky header polish
  const revealEls = [...document.querySelectorAll(".reveal")];
  const reduceMotionEarly = window.matchMedia("(prefers-reduced-motion: reduce)").matches;
  if (reduceMotionEarly || !("IntersectionObserver" in window)) {
    revealEls.forEach((el) => el.classList.add("is-visible"));
  } else if (revealEls.length) {
    // Hero content should paint immediately; stagger the rest on scroll.
    revealEls.forEach((el) => {
      if (el.closest(".hero")) el.classList.add("is-visible");
    });
    const io = new IntersectionObserver(
      (entries) => {
        entries.forEach((entry) => {
          if (!entry.isIntersecting) return;
          entry.target.classList.add("is-visible");
          io.unobserve(entry.target);
        });
      },
      { rootMargin: "0px 0px -6% 0px", threshold: 0.08 }
    );
    revealEls.forEach((el, i) => {
      if (el.classList.contains("is-visible")) return;
      el.style.setProperty("--reveal-delay", `${Math.min(i % 6, 5) * 45}ms`);
      io.observe(el);
    });
  }

  // Matrix row spotlight — subtle interactive depth on capability table
  const tableWrap = document.querySelector(".table-wrap");
  if (tableWrap && !reduceMotionEarly) {
    tableWrap.querySelectorAll("tbody tr:not(.compare-group)").forEach((row) => {
      row.addEventListener("pointerenter", () => row.classList.add("is-hot"));
      row.addEventListener("pointerleave", () => row.classList.remove("is-hot"));
    });
  }

  if (siteHeader) {
    const onScroll = () => {
      siteHeader.classList.toggle("is-scrolled", window.scrollY > 12);
    };
    onScroll();
    window.addEventListener("scroll", onScroll, { passive: true });
  }

  // Live GitHub popularity (stars / forks / watchers / open issues)
  const formatCount = (n) => {
    if (typeof n !== "number" || Number.isNaN(n)) return "—";
    if (n >= 1000) return `${(n / 1000).toFixed(n >= 10000 ? 0 : 1)}k`;
    return String(n);
  };

  const setAll = (selector, value) => {
    document.querySelectorAll(selector).forEach((node) => {
      node.textContent = value;
    });
  };

  const fillBars = (stats) => {
    const max = Math.max(stats.stars, stats.forks, stats.watchers, stats.issues, 1);
    const map = {
      stars: stats.stars,
      forks: stats.forks,
      watchers: stats.watchers,
      issues: stats.issues,
    };
    Object.entries(map).forEach(([key, value]) => {
      document.querySelectorAll(`[data-stat-bar="${key}"]`).forEach((bar) => {
        bar.style.setProperty("--fill", `${Math.round((value / max) * 100)}%`);
      });
    });
  };

  const applyGithub = (data) => {
    const stats = {
      stars: data.stargazers_count || 0,
      forks: data.forks_count || 0,
      watchers: data.subscribers_count || 0,
      issues: data.open_issues_count || 0,
    };
    setAll("[data-github-stars]", formatCount(stats.stars));
    setAll("[data-github-forks]", formatCount(stats.forks));
    setAll("[data-github-watchers]", formatCount(stats.watchers));
    setAll("[data-github-issues]", formatCount(stats.issues));
    fillBars(stats);
  };

  // Seed zeros so layout doesn't jump if the API is rate-limited.
  applyGithub({
    stargazers_count: 0,
    forks_count: 0,
    subscribers_count: 0,
    open_issues_count: 0,
  });

  fetch("https://api.github.com/repos/theesfeld/clun", {
    headers: { Accept: "application/vnd.github+json" },
  })
    .then((res) => (res.ok ? res.json() : null))
    .then((data) => {
      if (data) applyGithub(data);
    })
    .catch(() => {
      /* keep zeros / dashes */
    });

  let progress = document.querySelector(".scroll-progress");
  if (!progress) {
    progress = document.createElement("div");
    progress.className = "scroll-progress";
    progress.setAttribute("aria-hidden", "true");
    document.body.prepend(progress);
  }
  const updateProgress = () => {
    const doc = document.documentElement;
    const max = doc.scrollHeight - doc.clientHeight;
    progress.style.width = `${max > 0 ? (doc.scrollTop / max) * 100 : 0}%`;
  };
  updateProgress();
  window.addEventListener("scroll", updateProgress, { passive: true });
  window.addEventListener("resize", updateProgress, { passive: true });

  const magnetic = document.querySelectorAll(".btn-primary, .star-btn, .copy-button");
  const reduceMotion = reduceMotionEarly;
  if (!reduceMotion) {
    magnetic.forEach((el) => {
      el.addEventListener("pointermove", (e) => {
        const r = el.getBoundingClientRect();
        const x = ((e.clientX - r.left) / r.width - 0.5) * 6;
        const y = ((e.clientY - r.top) / r.height - 0.5) * 6;
        el.style.transform = `translate(${x}px, ${y}px)`;
      });
      el.addEventListener("pointerleave", () => { el.style.transform = ""; });
    });
  }
  const glow = document.querySelector(".hero-glow");
  if (glow && !reduceMotion) {
    window.addEventListener("pointermove", (e) => {
      const x = (e.clientX / window.innerWidth - 0.5) * 24;
      const y = (e.clientY / window.innerHeight - 0.5) * 16;
      glow.style.transform = `translate3d(${x}px, ${y}px, 0)`;
    }, { passive: true });
  }
})();
