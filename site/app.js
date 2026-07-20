(() => {
  const menuButton = document.querySelector(".menu-button");
  const navigation = document.querySelector(".site-nav");
  const siteHeader = document.querySelector(".site-header");
  const reduceMotion = window.matchMedia("(prefers-reduced-motion: reduce)").matches;

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

  /* ── Scroll engine: progress, parallax, pinned stage, rail, matrix ── */
  const progressEl = document.querySelector(".scroll-progress");
  const heroContent = document.querySelector("[data-hero-content]");
  const parallaxEls = [...document.querySelectorAll("[data-parallax]")];
  const fadeEls = [...document.querySelectorAll("[data-scroll-fade]")];
  const railLinks = [...document.querySelectorAll("[data-rail-link]")];
  const sections = [...document.querySelectorAll("[data-section]")];
  const navLinks = siteHeader
    ? [...siteHeader.querySelectorAll('.site-nav a[href^="#"]')]
    : [];

  const stage = document.querySelector("[data-stage]");
  const stageTrack = stage && stage.querySelector("[data-stage-track]");
  const stagePanels = stage ? [...stage.querySelectorAll("[data-stage-panel]")] : [];
  const stageDotsHost = stage && stage.querySelector("[data-stage-dots]");
  let stageIndex = 0;
  let stageDots = [];

  if (stageDotsHost && stagePanels.length && !reduceMotion && window.innerWidth > 900) {
    stageDots = stagePanels.map((_, i) => {
      const btn = document.createElement("button");
      btn.type = "button";
      btn.setAttribute("aria-label", `Toolkit panel ${i + 1}`);
      if (i === 0) btn.classList.add("is-active");
      btn.addEventListener("click", () => {
        if (!stageTrack) return;
        const rect = stageTrack.getBoundingClientRect();
        const top = window.scrollY + rect.top;
        const range = Math.max(1, stageTrack.offsetHeight - window.innerHeight);
        const target = top + (i / Math.max(1, stagePanels.length - 1)) * range * 0.92;
        window.scrollTo({ top: target, behavior: "smooth" });
      });
      stageDotsHost.appendChild(btn);
      return btn;
    });
  }

  const setStageIndex = (next) => {
    if (next === stageIndex || !stagePanels.length) return;
    const prev = stageIndex;
    stageIndex = next;
    stagePanels.forEach((panel, i) => {
      panel.classList.toggle("is-active", i === next);
      panel.classList.toggle("is-exit", i === prev && i !== next);
    });
    stageDots.forEach((dot, i) => dot.classList.toggle("is-active", i === next));
  };

  if (reduceMotion || window.innerWidth <= 900) {
    stagePanels.forEach((panel) => {
      panel.classList.add("is-active");
      panel.classList.remove("is-exit");
    });
  }

  // Scroll reveals
  const revealEls = [...document.querySelectorAll(".reveal")];
  if (reduceMotion || !("IntersectionObserver" in window)) {
    revealEls.forEach((el) => el.classList.add("is-visible"));
  } else if (revealEls.length) {
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
      { rootMargin: "0px 0px -8% 0px", threshold: 0.06 }
    );
    revealEls.forEach((el, i) => {
      if (el.classList.contains("is-visible")) return;
      el.style.setProperty("--reveal-delay", `${Math.min(i % 6, 5) * 40}ms`);
      io.observe(el);
    });
  }

  // Matrix: fluid page-scroll row reveals + focus + progress rail
  const matrixFlow = document.querySelector(".matrix-flow");
  const matrixTable = matrixFlow && matrixFlow.querySelector(".compat-table");
  const matrixRail = document.querySelector("[data-matrix-rail]");
  let featureRows = [];
  if (matrixFlow && matrixTable) {
    featureRows = [...matrixTable.querySelectorAll("tbody tr:not(.compare-group)")];
    featureRows.forEach((row, i) => {
      row.classList.add("matrix-row");
      row.style.setProperty("--row-delay", `${Math.min(i % 8, 7) * 24}ms`);
    });

    if (reduceMotion || !("IntersectionObserver" in window)) {
      featureRows.forEach((row) => row.classList.add("is-in"));
    } else {
      const rowIo = new IntersectionObserver(
        (entries) => {
          entries.forEach((entry) => {
            if (!entry.isIntersecting) return;
            entry.target.classList.add("is-in");
            rowIo.unobserve(entry.target);
          });
        },
        { root: null, rootMargin: "0px 0px -10% 0px", threshold: 0.1 }
      );
      featureRows.forEach((row) => rowIo.observe(row));
    }

    if (!reduceMotion) {
      featureRows.forEach((row) => {
        row.addEventListener("pointerenter", () => row.classList.add("is-hot"));
        row.addEventListener("pointerleave", () => row.classList.remove("is-hot"));
      });
    }
  }

  let ticking = false;
  const clamp = (n, a, b) => Math.max(a, Math.min(b, n));

  const updateScroll = () => {
    ticking = false;
    const doc = document.documentElement;
    const max = Math.max(1, doc.scrollHeight - doc.clientHeight);
    const y = window.scrollY || doc.scrollTop || 0;
    const p = clamp(y / max, 0, 1);

    document.body.style.setProperty("--scroll", p.toFixed(4));
    document.body.style.setProperty("--scroll-px", `${y.toFixed(1)}px`);

    if (progressEl) {
      progressEl.style.width = `${(p * 100).toFixed(2)}%`;
    }

    if (siteHeader) {
      siteHeader.classList.toggle("is-scrolled", y > 12);
    }

    // Hero drifts / fades as you leave the top
    if (heroContent && !reduceMotion) {
      const fade = clamp(1 - y / (window.innerHeight * 0.85), 0, 1);
      const lift = y * 0.22;
      heroContent.style.opacity = fade.toFixed(3);
      heroContent.style.transform = `translate3d(0, ${lift.toFixed(1)}px, 0) scale(${(0.96 + fade * 0.04).toFixed(3)})`;
    }

    // Parallax layers (depth)
    if (!reduceMotion) {
      parallaxEls.forEach((el) => {
        const depth = parseFloat(el.dataset.parallax || "0.2") || 0.2;
        const shift = y * depth;
        el.style.transform = `translate3d(0, ${shift.toFixed(1)}px, 0)`;
      });
    }

    // Section-based fade intensity while in view
    if (!reduceMotion) {
      fadeEls.forEach((el) => {
        const r = el.getBoundingClientRect();
        const vh = window.innerHeight || 1;
        const mid = r.top + r.height * 0.35;
        const dist = Math.abs(mid - vh * 0.42) / (vh * 0.7);
        const fade = clamp(1 - dist, 0.35, 1);
        el.style.setProperty("--fade", fade.toFixed(3));
      });
    }

    // Pinned toolkit stage scrub
    if (stage && stageTrack && stagePanels.length && !reduceMotion && window.innerWidth > 900) {
      const rect = stageTrack.getBoundingClientRect();
      const trackH = stageTrack.offsetHeight;
      const vh = window.innerHeight || 1;
      const start = -rect.top;
      const range = Math.max(1, trackH - vh);
      const sp = clamp(start / range, 0, 1);
      document.body.style.setProperty("--stage-p", sp.toFixed(4));
      const idx = Math.min(
        stagePanels.length - 1,
        Math.floor(sp * stagePanels.length * 0.999)
      );
      setStageIndex(idx);
    }

    // Matrix progress rail + focus row nearest viewport center
    if (matrixFlow && matrixRail && !reduceMotion) {
      const rect = matrixFlow.getBoundingClientRect();
      const vh = window.innerHeight || 1;
      const start = vh * 0.15;
      const end = rect.height + vh * 0.3;
      const traveled = start - rect.top;
      const pct = clamp((traveled / end) * 100, 0, 100);
      matrixRail.style.height = `${pct}%`;
    }

    if (featureRows.length && !reduceMotion) {
      const mid = window.innerHeight * 0.45;
      let best = null;
      let bestDist = Infinity;
      featureRows.forEach((row) => {
        if (!row.classList.contains("is-in")) return;
        const r = row.getBoundingClientRect();
        if (r.bottom < 0 || r.top > window.innerHeight) return;
        const d = Math.abs(r.top + r.height / 2 - mid);
        if (d < bestDist) {
          bestDist = d;
          best = row;
        }
      });
      featureRows.forEach((row) => row.classList.toggle("is-focus", row === best));
    }

    // Active section for rail + primary nav
    if (sections.length) {
      const probe = window.innerHeight * 0.28;
      let activeId = sections[0].id || sections[0].dataset.section;
      sections.forEach((sec) => {
        const r = sec.getBoundingClientRect();
        if (r.top <= probe) {
          activeId = sec.id || sec.dataset.section;
        }
      });
      railLinks.forEach((link) => {
        link.classList.toggle("is-active", link.dataset.railLink === activeId);
      });
      navLinks.forEach((link) => {
        const href = link.getAttribute("href") || "";
        const id = href.startsWith("#") ? href.slice(1) : "";
        link.classList.toggle("is-active", id === activeId);
      });
    }
  };

  const requestScrollUpdate = () => {
    if (ticking) return;
    ticking = true;
    window.requestAnimationFrame(updateScroll);
  };

  updateScroll();
  window.addEventListener("scroll", requestScrollUpdate, { passive: true });
  window.addEventListener("resize", requestScrollUpdate, { passive: true });

  // Magnetic buttons
  const magnetic = document.querySelectorAll(".btn-primary, .star-btn, .copy-button");
  if (!reduceMotion) {
    magnetic.forEach((el) => {
      el.addEventListener("pointermove", (e) => {
        const r = el.getBoundingClientRect();
        const x = ((e.clientX - r.left) / r.width - 0.5) * 6;
        const y = ((e.clientY - r.top) / r.height - 0.5) * 6;
        el.style.transform = `translate(${x}px, ${y}px)`;
      });
      el.addEventListener("pointerleave", () => {
        el.style.transform = "";
      });
    });
  }

  // 3D tilt cards
  if (!reduceMotion) {
    document.querySelectorAll("[data-tilt]").forEach((el) => {
      el.addEventListener("pointermove", (e) => {
        const r = el.getBoundingClientRect();
        const px = (e.clientX - r.left) / r.width - 0.5;
        const py = (e.clientY - r.top) / r.height - 0.5;
        el.classList.add("is-tilting");
        el.style.transform = `perspective(900px) rotateX(${(-py * 6).toFixed(2)}deg) rotateY(${(px * 8).toFixed(2)}deg) translateY(-2px)`;
      });
      el.addEventListener("pointerleave", () => {
        el.classList.remove("is-tilting");
        el.style.transform = "";
      });
    });
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
})();
