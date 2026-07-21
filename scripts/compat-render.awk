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

# Site matrix: icon mark only. Green check = Yes (fully has the capability).
function html_mark(state,    cls, glyph) {
  if (state == "Yes") { cls = "yes"; glyph = "✓" }
  else if (state == "Partial") { cls = "partial"; glyph = "∼" }
  else { cls = "no"; glyph = "✗" }
  return "<span class=\"mark mark-" cls "\" title=\"" html(state) "\">" \
         "<span class=\"mark-glyph\" aria-hidden=\"true\">" glyph "</span>" \
         "<b class=\"state " lower(state) "\">" html(state) "</b></span>"
}

# Only Clun may show a short "exceeds …" note when ledger detail claims it.
function html_clun_mark(state, detail,    result, note, low, pos) {
  result = html_mark(state)
  if (detail == "-" || detail == "") return result
  low = tolower(detail)
  pos = index(low, "exceed")
  if (pos == 0) return result
  # Start at exceed/exceeds/exceeding so the note is about the delta, not the whole detail.
  note = substr(detail, pos)
  # Drop trailing parenthetical noise like "… (exceeds Bun)" wrappers already mid-sentence.
  if (length(note) > 88) note = substr(note, 1, 85) "…"
  return result "<span class=\"exceed-note\">" html_prose(note) "</span>"
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

# Maturity channel from SemVer prerelease id (Clun train: dev → alpha → beta → rc → stable).
# Never say "pre-alpha" on a beta tag or "release candidate" on a published beta.
function maturity_channel(ver,    rest, id, dot) {
  if (ver == "" || ver == "-") return "pre-alpha"
  rest = ver
  if (substr(rest, 1, 1) == "v" || substr(rest, 1, 1) == "V") rest = substr(rest, 2)
  if (index(rest, "-") == 0) return "stable"
  rest = substr(rest, index(rest, "-") + 1)
  dot = index(rest, ".")
  id = (dot > 0) ? substr(rest, 1, dot - 1) : rest
  id = tolower(id)
  if (id == "dev") return "pre-alpha"
  if (id == "alpha") return "alpha"
  if (id == "beta") return "beta"
  if (id == "rc") return "rc"
  return "pre-alpha"
}

function maturity_label(channel) {
  if (channel == "stable") return "stable"
  if (channel == "rc") return "release candidate"
  if (channel == "beta") return "beta"
  if (channel == "alpha") return "alpha"
  return "pre-alpha"
}

function site_version_suffix(channel, published) {
  if (published) {
    if (channel == "stable") return ""
    return " / " maturity_label(channel)
  }
  if (channel == "stable") return " candidate"
  if (channel == "rc") return " release candidate"
  if (channel == "beta") return " / beta candidate"
  if (channel == "alpha") return " / alpha candidate"
  return " / pre-alpha candidate"
}

function status_headline(channel) {
  if (channel == "stable") return "stable release train"
  if (channel == "rc") return "release candidate"
  if (channel == "beta") return "beta"
  if (channel == "alpha") return "alpha"
  return "pre-alpha, under active construction"
}

function announcement_label(channel, published) {
  if (published) return "Available now"
  if (channel == "stable") return "Stable candidate"
  if (channel == "rc") return "RC candidate"
  if (channel == "beta") return "Beta candidate"
  if (channel == "alpha") return "Alpha candidate"
  return "In development"
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
  channel = maturity_channel(release_version)
  channel_label = maturity_label(channel)
  if (format == "readme-compat") {
    print "The current column describes " channel_label " behavior as tested today. A linked phase is a planned acceptance"
    print "gate, not a claim that the capability already exists. Every row below is generated from the canonical"
    print "compatibility ledger; `make docs-check` rejects hand-edited status, evidence, owner, or baseline drift."
    print ""
    print "The public comparison snapshot uses Bun " baseline_version[public_bun_id] ", Node.js " baseline_version[node_id] ", and Deno " baseline_version[deno_id] ", checked"
    print human_date(baseline_checked[public_bun_id]) ". Engineering references are separately pinned to Bun commit `" substr(baseline_revision[engineering_bun_id], 1, 10) "` (`" baseline_version[engineering_bun_id] "`)."
    print ""
    print "| Capability | Current " channel_label " state | Evidence-backed target |"
    print "|---|---|---|"
    for (i = 1; i <= 30; i++) {
      current = clun_state[i]
      if (clun_detail[i] != "-") current = current ": " clun_detail[i]
      print "| " markdown(capability[i]) " | " markdown(current) " | " markdown_phases(primary_phase[i], integration_phases[i]) " |"
    }
  } else if (format == "site-compat") {
    print "<table class=\"compat-table compat-table-icons\">"
    print "  <thead>"
    print "    <tr>"
    print "      <th scope=\"col\">Capability</th>"
    print "      <th scope=\"col\"><a href=\"https://bun.sh/\">Bun</a><span>" html(baseline_version[public_bun_id]) "</span></th>"
    print "      <th scope=\"col\"><a href=\"https://nodejs.org/\">Node.js</a><span>" html(baseline_version[node_id]) "</span></th>"
    print "      <th scope=\"col\"><a href=\"https://deno.com/\">Deno</a><span>" html(baseline_version[deno_id]) "</span></th>"
    print "      <th scope=\"col\" class=\"clun-col\"><a href=\"https://github.com/theesfeld/clun\">Clun</a><span>" html(release_version) "</span></th>"
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
      print "      <td class=\"mark-cell\">" html_mark(bun_state[i]) "</td>"
      print "      <td class=\"mark-cell\">" html_mark(node_state[i]) "</td>"
      print "      <td class=\"mark-cell\">" html_mark(deno_state[i]) "</td>"
      print "      <td class=\"clun-col mark-cell\">" html_clun_mark(clun_state[i], clun_detail[i]) "</td>"
      print "    </tr>"
    }
    print "  </tbody>"
    print "</table>"
    print "<p class=\"source-note\">"
    print "  ✓ full support · ∼ partial · ✗ none."
    print "  Snapshot checked " human_date(baseline_checked[public_bun_id]) "."
    print "  Sources:"
    print "  <a href=\"https://github.com/theesfeld/clun/blob/master/README.md\">Clun README</a>,"
    print "  <a href=\"" html(baseline_source[public_bun_id]) "\">Bun " html(baseline_version[public_bun_id]) "</a>,"
    print "  <a href=\"" html(baseline_source[engineering_bun_id]) "\">Bun source audit</a>,"
    print "  <a href=\"" html(baseline_source[node_id]) "\">Node.js " html(baseline_version[node_id]) "</a>,"
    print "  <a href=\"" html(baseline_source[deno_id]) "\">Deno " html(baseline_version[deno_id]) "</a>."
    print "  <a href=\"https://github.com/theesfeld/clun/blob/master/compat/README.md\">Ledger on GitHub</a>."
    print "  Capability, not speed."
    print "</p>"
  } else if (format == "site-compat-intro") {
    print "Same public toolkit matrix as Bun " html(baseline_version[public_bun_id]) " — Clun last."
    print "<strong>" ledger_yes " full</strong> · <strong>" ledger_partial " partial</strong> · <strong>" ledger_no " none</strong>."
    print "A green check means that runtime has the capability (evidence-backed Yes / Partial / No)."
    print "Only Clun’s column calls out where it <em>exceeds</em> the others."
  } else if (format == "readme-release") {
    tagged_candidate = publication_state == "candidate" && release_commit != "pending"
    if (publication_state == "published") {
      print "> **Status: " status_headline(channel) ".** Latest release: [`" release_tag "`](https://github.com/theesfeld/clun/releases/tag/" release_tag ")."
      print "> Installable boundary: four native archives, checksums, Pages installer, and `clun --update`."
      print "> Capability matrix: " ledger_yes " Yes / " ledger_partial " Partial / " ledger_no " No (evidence-backed)."
      print "> Implementation: pure Common Lisp. Source: [theesfeld/clun](https://github.com/theesfeld/clun)."
    } else {
      print "> **Status: " status_headline(channel) ".** Release target: `" release_version "` / `" release_tag "` (SemVer impact: `" semver_impact "`)."
      print "> Tracking: [issue #" active_issue "](https://github.com/theesfeld/clun/issues/" active_issue ")."
      if (tagged_candidate) {
        print "> The annotated tag `" release_tag "` points to candidate commit `" release_commit "`, but no GitHub Release or release assets were published."
        print "> The latest verified installable boundary remains `v" previous_version "`."
      } else {
        print "> The verified release boundary is `v" previous_version "` until this candidate publishes."
      }
      print "> Capability matrix: " ledger_yes " Yes / " ledger_partial " Partial / " ledger_no " No."
    }
  } else if (format == "site-release") {
    if (publication_state == "published") {
      print "<a href=\"https://github.com/theesfeld/clun/releases/tag/" release_tag "\">"
      print "  <span>" announcement_label(channel, 1) "</span>"
    } else if (release_commit != "pending") {
      print "<a href=\"https://github.com/theesfeld/clun/issues/" active_issue "\">"
      print "  <span>Tag only / no Release</span>"
    } else {
      print "<a href=\"https://github.com/theesfeld/clun/issues/" active_issue "\">"
      print "  <span>" announcement_label(channel, 0) "</span>"
    }
    print "  " html(release_tag)
    print "  <span aria-hidden=\"true\">-&gt;</span>"
    print "</a>"
  } else if (format == "site-version") {
    print "<p class=\"eyebrow\"><span class=\"status-dot\" aria-hidden=\"true\"></span> v" release_version site_version_suffix(channel, publication_state == "published") "</p>"
  } else if (format == "site-phase-status") {
    if (publication_state == "published")
      print ""
    else if (publication_state == "candidate" && release_commit != "pending")
      print "Candidate tag only (no GitHub Release yet)."
    else
      print "Current release work: <a href=\"https://github.com/theesfeld/clun/issues/" active_issue "\">issue #" active_issue "</a>."
  } else if (format == "readme-release-summary") {
    if (publication_state == "published") {
      print "Latest release: [`" release_version "`](https://github.com/theesfeld/clun/releases/tag/" release_tag ")."
      print "Install: `curl -fsSL https://clun.sh/install | sh` · update: `clun --update`."
      print "Capability matrix: " ledger_yes " Yes / " ledger_partial " Partial / " ledger_no " No."
      print "[Versioning](docs/versioning.md) · [compatibility matrix](compat/README.md)."
    } else if (release_commit != "pending") {
      print "Candidate `" release_version "` is tagged but not published; installable boundary remains `v" previous_version "`."
      print "Tracking: [issue #" active_issue "](https://github.com/theesfeld/clun/issues/" active_issue ")."
    } else {
      print "Candidate `" release_version "` is unpublished; installable boundary remains `v" previous_version "`."
      print "Tracking: [issue #" active_issue "](https://github.com/theesfeld/clun/issues/" active_issue ")."
    }
  } else if (format == "site-release-links") {
    if (publication_state == "published") {
      print "<div><h2>Project</h2><a href=\"https://github.com/theesfeld/clun\">Source</a><a href=\"https://github.com/theesfeld/clun/blob/master/README.md\">README</a><a href=\"https://github.com/theesfeld/clun/releases\">Releases</a></div>"
      print "<div><h2>Evidence</h2><a href=\"https://github.com/theesfeld/clun/blob/master/compat/README.md\">Capability matrix</a><a href=\"https://github.com/theesfeld/clun/actions/workflows/compat.yml\">Compatibility CI</a><a href=\"https://github.com/theesfeld/clun/blob/master/LICENSE\">License</a></div>"
      print "<div><h2>Install</h2><a href=\"install\">Shell installer</a><a href=\"https://github.com/theesfeld/clun/releases/tag/" release_tag "\">" release_tag " release</a><a href=\"https://github.com/theesfeld/clun#building-from-source\">Build from source</a></div>"
    } else {
      print "<div><h2>Project</h2><a href=\"https://github.com/theesfeld/clun\">Source</a><a href=\"https://github.com/theesfeld/clun/blob/master/README.md\">README</a><a href=\"https://github.com/theesfeld/clun/issues/" active_issue "\">Current status</a></div>"
      print "<div><h2>Evidence</h2><a href=\"https://github.com/theesfeld/clun/blob/master/compat/README.md\">Capability matrix</a><a href=\"https://github.com/theesfeld/clun/actions/workflows/compat.yml\">Compatibility CI</a><a href=\"https://github.com/theesfeld/clun/issues/" active_issue "\">Release issue</a><a href=\"https://github.com/theesfeld/clun/blob/master/LICENSE\">License</a></div>"
      print "<div><h2>Install</h2><a href=\"install\">Shell installer</a><a href=\"https://github.com/theesfeld/clun/releases/tag/v" previous_version "\">v" previous_version " release</a><a href=\"https://github.com/theesfeld/clun#building-from-source\">Build from source</a></div>"
    }
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
