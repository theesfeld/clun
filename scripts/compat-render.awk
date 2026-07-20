# Deterministic compatibility public-document renderer. The caller selects FORMAT
# and passes roadmap.tsv, baselines.tsv, release.tsv, and features.tsv in that order.

BEGIN { OFS = FS }

function html(value,    result, i, char) {
  result = ""
  for (i = 1; i <= length(value); i++) {
    char = substr(value, i, 1)
    if (char == "&") result = result "&amp;"
    else if (char == "<") result = result "&lt;"
    else if (char == ">") result = result "&gt;"
    else if (char == "\"") result = result "&quot;"
    else result = result char
  }
  return result
}

function markdown(value,    result, i, char) {
  result = ""
  for (i = 1; i <= length(value); i++) {
    char = substr(value, i, 1)
    if (char == "|" || char == "\\") result = result "\\" char
    else result = result char
  }
  return result
}

function html_prose(value,    parts, count, result, i) {
  count = split(value, parts, "`")
  result = ""
  for (i = 1; i <= count; i++) {
    if (i % 2 == 0) result = result "<code>" html(parts[i]) "</code>"
    else result = result html(parts[i])
  }
  return result
}

function human_date(value,    month) {
  month = substr(value, 6, 2)
  if (month == "01") month = "January"
  else if (month == "02") month = "February"
  else if (month == "03") month = "March"
  else if (month == "04") month = "April"
  else if (month == "05") month = "May"
  else if (month == "06") month = "June"
  else if (month == "07") month = "July"
  else if (month == "08") month = "August"
  else if (month == "09") month = "September"
  else if (month == "10") month = "October"
  else if (month == "11") month = "November"
  else if (month == "12") month = "December"
  else return value
  return month " " (substr(value, 9, 2) + 0) ", " substr(value, 1, 4)
}

function lower(value) {
  return tolower(value)
}

function phase_present(primary, integrations, phase,    values, count, i) {
  if ((primary + 0) == phase) return 1
  if (integrations == "-") return 0
  count = split(integrations, values, ",")
  for (i = 1; i <= count; i++) if ((values[i] + 0) == phase) return 1
  return 0
}

function phase_count(primary, integrations,    count, phase) {
  count = 0
  for (phase = 27; phase <= 82; phase++) if (phase_present(primary, integrations, phase)) count++
  return count
}

function issue_query(phase) {
  return "https://github.com/theesfeld/clun/issues?q=is%3Aissue%20label%3Aphase-" phase
}

function markdown_phases(primary, integrations,    count, phase, result, first) {
  count = phase_count(primary, integrations)
  result = (count == 1 ? "" : "Phases ")
  first = 1
  for (phase = 27; phase <= 82; phase++) {
    if (!phase_present(primary, integrations, phase)) continue
    if (!first) result = result ", "
    if (count == 1) result = result "[Phase " phase "]("
    else result = result "[" phase "]("
    result = result issue_query(phase) ")"
    first = 0
  }
  return result
}

function html_phases(primary, integrations) {
  # Public site: capability state only. Phase numbers stay on GitHub Issues, not in the matrix UI.
  return ""
}

function html_state(state, detail,    result) {
  result = "<b class=\"state " lower(state) "\">" html(state) "</b>"
  if (detail != "-") result = result " " html_prose(detail)
  return result
}

function group_title(group) {
  if (group == "core") return "Built-in core features"
  if (group == "apis") return "Built-in APIs"
  if (group == "tooling") return "Built-in tooling"
  return "Built-in utilities"
}

function group_summary(group) {
  if (group == "core") return "Essential runtime capabilities"
  if (group == "apis") return "Performance and native APIs intended for application code"
  if (group == "tooling") return "Developer workflow available from the primary command"
  return "Convenience APIs exposed without installing another package"
}

FNR == 1 { next }

FILENAME ~ /docs\/roadmap\.tsv$/ {
  roadmap_title[$1] = $3
  next
}

FILENAME ~ /compat\/baselines\.tsv$/ {
  baseline_version[$1] = $3
  baseline_revision[$1] = $5
  baseline_tag[$1] = $6
  baseline_checked[$1] = $7
  baseline_source[$1] = $9
  if ($2 == "Bun" && $4 == "stable-executable") public_bun_id = $1
  else if ($2 == "Bun" && $4 == "engineering-source") engineering_bun_id = $1
  else if ($2 == "Node.js" && $4 == "comparison-release") node_id = $1
  else if ($2 == "Deno" && $4 == "comparison-release") deno_id = $1
  next
}

FILENAME ~ /compat\/release\.tsv$/ {
  release_id = $1
  release_version = $2
  release_core = $3
  release_tag = $5
  publication_state = $6
  release_license = $7
  active_phase = $8
  active_issue = $9
  semver_impact = $10
  previous_version = $11
  release_commit = $15
  next
}

FILENAME ~ /compat\/features\.tsv$/ {
  order = $2 + 0
  feature_id[order] = $1
  display_group[order] = $3
  capability[order] = $4
  summary[order] = $5
  clun_state[order] = $6
  clun_detail[order] = $7
  gap[order] = $8
  bun_state[order] = $9
  bun_detail[order] = $10
  node_state[order] = $11
  node_detail[order] = $12
  deno_state[order] = $13
  deno_detail[order] = $14
  primary_phase[order] = $15
  integration_phases[order] = $16
  row_count++
  next
}

END {
  ledger_yes = ledger_partial = ledger_no = 0
  for (i = 1; i <= 30; i++) {
    if (clun_state[i] == "Yes") ledger_yes++
    else if (clun_state[i] == "Partial") ledger_partial++
    else ledger_no++
  }
  ledger_total = 30
  if (format == "readme-compat") {
    print "The current column describes pre-alpha behavior as tested today. A linked phase is a planned acceptance"
    print "gate, not a claim that the capability already exists. Every row below is generated from the canonical"
    print "compatibility ledger; `make docs-check` rejects hand-edited status, evidence, owner, or baseline drift."
    print ""
    print "The public comparison snapshot uses Bun " baseline_version[public_bun_id] ", Node.js " baseline_version[node_id] ", and Deno " baseline_version[deno_id] ", checked"
    print human_date(baseline_checked[public_bun_id]) ". Engineering references are separately pinned to Bun commit `" substr(baseline_revision[engineering_bun_id], 1, 10) "` (`" baseline_version[engineering_bun_id] "`)."
    print ""
    print "| Capability | Current pre-alpha state | Evidence-backed target |"
    print "|---|---|---|"
    for (i = 1; i <= 30; i++) {
      current = clun_state[i]
      if (clun_detail[i] != "-") current = current ": " clun_detail[i]
      print "| " markdown(capability[i]) " | " markdown(current) " | " markdown_phases(primary_phase[i], integration_phases[i]) " |"
    }
  } else if (format == "site-compat") {
    print "<table class=\"compat-table\">"
    print "  <thead>"
    print "    <tr>"
    print "      <th scope=\"col\">Capability</th>"
    print "      <th scope=\"col\" class=\"clun-col\"><a href=\"https://github.com/theesfeld/clun\">Clun</a><span>" html(release_version) (publication_state == "published" ? " / pre-alpha" : " candidate / pre-alpha") "</span></th>"
    print "      <th scope=\"col\"><a href=\"https://bun.sh/\">Bun</a><span>" html(baseline_version[public_bun_id]) " / toolkit</span></th>"
    print "      <th scope=\"col\"><a href=\"https://nodejs.org/\">Node.js</a><span>" html(baseline_version[node_id]) " / current</span></th>"
    print "      <th scope=\"col\"><a href=\"https://deno.com/\">Deno</a><span>" html(baseline_version[deno_id]) " / runtime</span></th>"
    print "    </tr>"
    print "  </thead>"
    last_group = ""
    for (i = 1; i <= 30; i++) {
      if (display_group[i] != last_group) {
        if (last_group != "") print "  </tbody>"
        print "  <tbody>"
        print "    <tr class=\"compare-group\">"
        print "      <th scope=\"rowgroup\" colspan=\"5\"><strong>" html(group_title(display_group[i])) "</strong><span>" html(group_summary(display_group[i])) "</span></th>"
        print "    </tr>"
        last_group = display_group[i]
      }
      print "    <tr data-compat-feature=\"" html(feature_id[i]) "\">"
      print "      <th scope=\"row\"><strong>" html(capability[i]) "</strong><span>" html_prose(summary[i]) "</span></th>"
      print "      <td class=\"clun-col\">" html_state(clun_state[i], clun_detail[i]) html_phases(primary_phase[i], integration_phases[i]) "</td>"
      print "      <td>" html_state(bun_state[i], bun_detail[i]) "</td>"
      print "      <td>" html_state(node_state[i], node_detail[i]) "</td>"
      print "      <td>" html_state(deno_state[i], deno_detail[i]) "</td>"
      print "    </tr>"
    }
    print "  </tbody>"
    print "</table>"
    print "<p class=\"source-note\">"
    print "  Snapshot checked " human_date(baseline_checked[public_bun_id]) ". Sources:"
    print "  <a href=\"https://github.com/theesfeld/clun/blob/master/README.md\">Clun README</a>,"
    print "  <a href=\"" html(baseline_source[public_bun_id]) "\">Bun " html(baseline_version[public_bun_id]) "</a>,"
    print "  the separate"
    print "  <a href=\"" html(baseline_source[engineering_bun_id]) "\">Bun source audit</a>,"
    print "  <a href=\"" html(baseline_source[node_id]) "\">Node.js " html(baseline_version[node_id]) "</a>, and"
    print "  <a href=\"" html(baseline_source[deno_id]) "\">Deno " html(baseline_version[deno_id]) "</a>."
    print "  npm appears as tooling, not as a runtime column. Clun has no same-host speed"
    print "  comparison against these projects."
    print "</p>"
  } else if (format == "site-compat-intro") {
    print "This follows the stable Bun " html(baseline_version[public_bun_id]) " runtime feature matrix and adds Clun."
    print "<strong>" ledger_yes " Yes</strong> / <strong>" ledger_partial " Partial</strong> / <strong>" ledger_no " No</strong>"
    print "on the " ledger_total " capability rows below — evidence-backed Bun-shaped (or better) behavior in pure Common Lisp,"
    print "not a finished drop-in for every Node or Bun program. Several rows already <em>exceed</em> Bun"
    print "(TypeScript typecheck, fmt/lint, offline Redis, SQLite module surface, and more)."
    print "The engineering roadmap separately audits Bun source commit"
    print "<code>" html(substr(baseline_revision[engineering_bun_id], 1, 10)) "</code> (<code>" html(baseline_version[engineering_bun_id]) "</code>) for newer upstream work."
    print "This is capability, not speed."
  } else if (format == "readme-release") {
    tagged_candidate = publication_state == "candidate" && release_commit != "pending"
    if (publication_state == "published") {
      print "> **Status: pre-alpha, under active construction.** [Phase " active_phase "](https://github.com/theesfeld/clun/issues/" active_issue ") tracks the published prerelease and remaining phase work."
      print "> Published release: `" release_version "` / `" release_tag "` (SemVer impact: `" semver_impact "`)."
    } else {
      print "> **Status: pre-alpha, under active construction.** [Phase " active_phase "](https://github.com/theesfeld/clun/issues/" active_issue ") is in progress."
      print "> Its release-bearing target is `" release_version "` / `" release_tag "` (SemVer impact: `" semver_impact "`)."
    }
    if (publication_state == "published") {
      print "> The verified release boundary is `" release_tag "`, with four native archives and checksums."
      print "> Release-gated Pages and hosted-installer results are recorded in the canonical issue."
    } else if (tagged_candidate) {
      print "> The annotated tag `" release_tag "` points to candidate commit `" release_commit "`, but no GitHub Release or release assets were published."
      print "> The latest verified installable boundary remains `v" previous_version "`, with four native archives, checksums, Pages, and hosted-installer evidence."
      print "> Tag-only recovery remains tracked in [Phase " active_phase " issue #" active_issue "](https://github.com/theesfeld/clun/issues/" active_issue "); the failed tag is immutable and recovery must use a new prerelease slot."
    } else {
      print "> The verified release boundary is `v" previous_version "`, with four native archives, checksums, Pages,"
      print "> and hosted-installer evidence."
    }
    print "> Phase 26 remains deferred until after Phase 82 and will"
    print "> be rewritten for the repository state that exists then."
    print "> Clun's full-port target requires every ledger Yes to survive executable and public-claim audit. The current snapshot is " ledger_yes " Yes / " ledger_partial " Partial / " ledger_no " No; qualified evidence is not treated as complete."
    print "> The canonical issue is the live source of truth; `PLAN.md` is the technical contract and `STATE.md` is"
    print "> the local resume checklist."
  } else if (format == "site-release") {
    if (publication_state == "published") {
      print "<a href=\"https://github.com/theesfeld/clun/releases/tag/" release_tag "\">"
      print "  <span>Available now</span>"
    } else if (release_commit != "pending") {
      print "<a href=\"https://github.com/theesfeld/clun/issues/" active_issue "\">"
      print "  <span>Tag only / no Release</span>"
    } else {
      print "<a href=\"https://github.com/theesfeld/clun/issues/" active_issue "\">"
      print "  <span>In development</span>"
    }
    print "  " html(release_tag)
    print "  <span aria-hidden=\"true\">-&gt;</span>"
    print "</a>"
  } else if (format == "site-version") {
    print "<p class=\"eyebrow\"><span class=\"status-dot\" aria-hidden=\"true\"></span> v" release_version (publication_state == "published" ? " / pre-alpha" : " release candidate / pre-alpha") "</p>"
  } else if (format == "site-phase-status") {
    if (publication_state == "published")
      print "Release tracking: <a href=\"https://github.com/theesfeld/clun/issues/" active_issue "\">issue #" active_issue "</a>."
    else if (publication_state == "candidate" && release_commit != "pending")
      print "Candidate tag only (no GitHub Release yet). Tracking: <a href=\"https://github.com/theesfeld/clun/issues/" active_issue "\">issue #" active_issue "</a>."
    else
      print "Current release work: <a href=\"https://github.com/theesfeld/clun/issues/" active_issue "\">issue #" active_issue "</a>."
  } else if (format == "readme-release-summary") {
    print "Release versions follow the actual SemVer impact recorded in the canonical issue, not the number of pushes."
    if (publication_state == "published") {
      print "The current source version and latest published prerelease are [`" release_version "`](https://github.com/theesfeld/clun/releases/tag/" release_tag ")."
    } else if (release_commit != "pending") {
      print "The current source is the `" release_version "` release candidate. Its annotated [`" release_tag "`](https://github.com/theesfeld/clun/tree/" release_tag ") points to commit `" release_commit "`, but no GitHub Release or release assets were published."
      print "The last published prerelease remains [`v" previous_version "`](https://github.com/theesfeld/clun/releases/tag/v" previous_version ")."
    } else {
      print "The current source is the `" release_version "` release candidate; the immutable tag and assets are not published yet."
      print "The last published prerelease remains [`v" previous_version "`](https://github.com/theesfeld/clun/releases/tag/v" previous_version ")."
    }
    print "[The versioning contract](docs/versioning.md) defines prerelease sequencing, synchronized surfaces, immutable tags, assets, and installer evidence."
    print "[Phase " active_phase " issue #" active_issue "](https://github.com/theesfeld/clun/issues/" active_issue ") is the canonical live release record."
    if (publication_state == "candidate" && release_commit != "pending")
      print "Tag-only recovery remains tracked in [Phase " active_phase " issue #" active_issue "](https://github.com/theesfeld/clun/issues/" active_issue "); the failed tag is immutable and recovery must use a new prerelease slot."
  } else if (format == "site-release-links") {
    print "<div><h2>Project</h2><a href=\"https://github.com/theesfeld/clun\">Source</a><a href=\"https://github.com/theesfeld/clun/blob/master/README.md\">README</a><a href=\"https://github.com/theesfeld/clun/issues/" active_issue "\">" (publication_state == "published" ? "Release record" : "Current status") "</a></div>"
    print "<div><h2>Evidence</h2><a href=\"https://github.com/theesfeld/clun/blob/master/compat/README.md\">Compatibility ledger</a><a href=\"https://github.com/theesfeld/clun/actions/workflows/compat.yml\">Compatibility CI</a><a href=\"https://github.com/theesfeld/clun/issues/" active_issue "\">Release issue</a><a href=\"https://github.com/theesfeld/clun/blob/master/LICENSE\">License</a></div>"
    if (publication_state == "published")
      print "<div><h2>Install</h2><a href=\"install\">Shell installer</a><a href=\"https://github.com/theesfeld/clun/releases/tag/" release_tag "\">" release_tag " release</a><a href=\"https://github.com/theesfeld/clun#building-from-source\">Build from source</a></div>"
    else
      print "<div><h2>Install</h2><a href=\"install\">Shell installer</a><a href=\"https://github.com/theesfeld/clun/releases/tag/v" previous_version "\">v" previous_version " release</a><a href=\"https://github.com/theesfeld/clun#building-from-source\">Build from source</a></div>"
  } else if (format == "release-notes") {
    print "# Clun " release_version
    print ""
    print "Phase " active_phase ": " roadmap_title[active_phase] "."
    print ""
    print "- SemVer impact: `" semver_impact "` within the selected `" release_core "` prerelease train."
    print "- Compatibility snapshot: " ledger_yes " Yes / " ledger_partial " Partial / " ledger_no " No across 30 generated rows."
    print "- Public baseline: Bun " baseline_version[public_bun_id] "; engineering baseline: Bun `" substr(baseline_revision[engineering_bun_id], 1, 10) "`."
    print "- Target release platforms: Linux and macOS, x64 and arm64."
    print "- License: `" release_license "`."
    print ""
    print "The canonical evidence and current limitations are in `compat/`; `make compat-validate` and `make docs-check` reject claim drift."
  } else if (format == "canonical") {
    print "feature_id" FS "display_order" FS "display_group" FS "capability" FS "summary" FS "clun_state" FS "clun_detail" FS "bun_state" FS "bun_detail" FS "node_state" FS "node_detail" FS "deno_state" FS "deno_detail" FS "primary_phase" FS "integration_phases"
    for (i = 1; i <= 30; i++)
      print feature_id[i], i, display_group[i], capability[i], summary[i], clun_state[i], clun_detail[i], bun_state[i], bun_detail[i], node_state[i], node_detail[i], deno_state[i], deno_detail[i], primary_phase[i], integration_phases[i]
  } else {
    print "compat-render: unknown format " format > "/dev/stderr"
    exit 2
  }
}
