#!/bin/bash
# Mechanical documentation drift checks for README.md / ARCHITECTURE.md.
#   1. Every tracked file appears (by name) in the README "Project Structure" tree, and every
#      file named in that tree exists.
#   2. README / ARCHITECTURE don't hard-code a release version (it lives in version.env).
#   3. Documented sizes are within 10% of the built dist/TrinityBar.app (skipped with a notice
#      if dist/ hasn't been built; run ./scripts/build_app.sh first).
# Prose accuracy is not checked here; see the docs review in RELEASING.md.
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$PROJECT_DIR"

failures=0
fail() {
    echo "error: $*" >&2
    failures=$((failures + 1))
}

# --- 1. README project tree ------------------------------------------------------------------
tree="$(awk '
    /^## Project Structure/ { in_section = 1; next }
    in_section && /^```text/ { in_block = 1; next }
    in_block && /^```/ { exit }
    in_block { print }
' README.md)"

if [[ -z "$tree" ]]; then
    fail "README.md: could not find the \`\`\`text block under '## Project Structure'"
else
    # Names listed in the tree: the token after the box-drawing prefix, before any comment.
    tree_names="$(printf '%s\n' "$tree" \
        | sed -E 's/#.*$//; s/^[│├└─ ]+//; s/[[:space:]]+$//' \
        | grep -v '/$' | grep -v '^$' | grep -v '^TrinityBar$' || true)"

    while IFS= read -r path; do
        name="$(basename "$path")"
        [[ "$name" == ".gitignore" ]] && continue
        if ! printf '%s\n' "$tree_names" | grep -qxF "$name"; then
            fail "README.md project tree is missing '$path'"
        fi
    done < <(git ls-files)

    tracked_names="$(git ls-files | xargs -n1 basename)"
    while IFS= read -r name; do
        [[ -z "$name" ]] && continue
        if ! printf '%s\n' "$tracked_names" | grep -qxF "$name"; then
            fail "README.md project tree lists '$name', which is not a tracked file"
        fi
    done <<< "$tree_names"
fi

# --- 2. No hard-coded release version --------------------------------------------------------
source "$PROJECT_DIR/version.env"
escaped_version="${MARKETING_VERSION//./\\.}"
for doc in README.md ARCHITECTURE.md; do
    if hits="$(grep -nE "v[0-9]+\.[0-9]+\.[0-9]+|(^|[^0-9.])${escaped_version}([^0-9.]|$)" "$doc")"; then
        while IFS= read -r hit; do
            fail "$doc:${hit%%:*}: hard-coded version (versions live in version.env)"
        done <<< "$hits"
    fi
done

# --- 3. Documented sizes ---------------------------------------------------------------------
check_size() { # <doc> <label> <documented KB> <actual KB>
    local doc="$1" label="$2" documented="$3" actual="$4"
    local diff=$(( documented > actual ? documented - actual : actual - documented ))
    if (( diff * 10 > actual )); then
        fail "$doc documents $label as ~${documented} KB, but the build is ${actual} KB (>10% off)"
    else
        echo "ok: $doc $label ~${documented} KB (actual ${actual} KB)"
    fi
}

extract_kb() { # <file> <regex with the number as the only digits run before ' KB'>
    grep -oE "$2" "$1" | head -n1 | grep -oE '[0-9]+' | head -n1
}

APP="$PROJECT_DIR/dist/TrinityBar.app"
if [[ -d "$APP" ]]; then
    app_kb="$(du -sk "$APP" | awk '{print $1}')"
    exe_kb="$(( $(stat -f%z "$APP/Contents/MacOS/TrinityBar") / 1024 ))"

    readme_app="$(extract_kb README.md 'lightweight \(`~[0-9]+ KB`\)')"
    arch_app="$(extract_kb ARCHITECTURE.md 'TrinityBar\.app` at \*\*`~[0-9]+ KB`')"
    arch_exe="$(extract_kb ARCHITECTURE.md '`~[0-9]+ KB`\*\* arm64 executable')"

    [[ -n "$readme_app" ]] && check_size README.md "app bundle" "$readme_app" "$app_kb" \
        || fail "README.md: could not find the 'lightweight (\`~N KB\`)' app size"
    [[ -n "$arch_app" ]] && check_size ARCHITECTURE.md "app bundle" "$arch_app" "$app_kb" \
        || fail "ARCHITECTURE.md: could not find the packaged app size"
    [[ -n "$arch_exe" ]] && check_size ARCHITECTURE.md "executable" "$arch_exe" "$exe_kb" \
        || fail "ARCHITECTURE.md: could not find the executable size"
else
    echo "notice: dist/TrinityBar.app not found; skipping size checks (run ./scripts/build_app.sh first)"
fi

if (( failures > 0 )); then
    echo "check_docs: $failures problem(s) found" >&2
    exit 1
fi
echo "check_docs: all documentation checks passed"
