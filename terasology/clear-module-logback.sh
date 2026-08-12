#!/usr/bin/env bash
# Remove the build-harness logback-test.xml copies the module build drops into
# every Terasology module working tree.
#
# The engine's build-harness zip packages templates/module.logback-test.xml as
# src/test/resources/logback-test.xml (see build.gradle.kts), so every module a
# harness build touches gains an untracked file that most modules do not
# gitignore. The result is dozens of modules reading as dirty, which trains
# everyone to ignore module dirt — and that is how a real uncommitted change goes
# unnoticed.
#
# This is a noise sweep, not the fix. The fix is for the module build to stop
# writing into the source tree (or for the harness to gitignore what it writes);
# a couple of modules already carry the .gitignore entry and this script leaves
# those alone.
#
# Refuses to touch anything it has not proven safe. A file is only removed when
# it is untracked in its own repo, not gitignored there, and byte-identical to
# the engine's template. Everything else is classified and reported.
#
# Usage:
#   clear-module-logback.sh            dry run (default)
#   clear-module-logback.sh --apply    actually remove
#
# Override the engine location with TERASOLOGY_DIR when the workspace layout
# differs from the standard components/terasology.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# realms/<realm>/terasology/ -> workspace root is three levels up.
WORKSPACE_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
TERA="${TERASOLOGY_DIR:-$WORKSPACE_ROOT/components/terasology}"
TEMPLATE="$TERA/templates/module.logback-test.xml"
REL="src/test/resources/logback-test.xml"

APPLY=""
case "${1:-}" in
    --apply) APPLY="yes" ;;
    "") ;;
    *)
        echo "ERROR: unknown argument '$1'. Expected --apply or nothing." >&2
        exit 1
        ;;
esac

if [[ ! -d "$TERA/modules" ]]; then
    echo "ERROR: no modules directory at $TERA/modules" >&2
    echo "  Set TERASOLOGY_DIR if the engine lives elsewhere." >&2
    exit 1
fi

if [[ ! -f "$TEMPLATE" ]]; then
    echo "ERROR: template not found: $TEMPLATE" >&2
    echo "  Without it there is nothing to compare against, so nothing is safe to remove." >&2
    exit 1
fi

removed=0 tracked=0 ignored=0 differs=0 other=0

for module_dir in "$TERA"/modules/*/; do
    module_dir="${module_dir%/}"
    name="${module_dir##*/}"
    [[ -e "$module_dir/.git" ]] || continue

    target="$module_dir/$REL"
    if [[ -f "$target" ]]; then
        if git -C "$module_dir" ls-files --error-unmatch "$REL" >/dev/null 2>&1; then
            # Committed by accident at some point. Removing it here would show as a
            # deletion needing a PR to that module — out of scope for a noise sweep.
            echo "TRACKED  $name — the generated file is committed to this repo"
            tracked=$((tracked + 1))
        elif git -C "$module_dir" check-ignore -q "$REL" 2>/dev/null; then
            # Already solved properly in this module: it causes no noise, so leave
            # the working copy where the build put it.
            echo "IGNORED  $name — already gitignored, nothing to clean"
            ignored=$((ignored + 1))
        elif ! cmp -s "$TEMPLATE" "$target"; then
            echo "DIFFERS  $name — not the template's content, leaving it alone"
            differs=$((differs + 1))
        else
            if [[ -n "$APPLY" ]]; then
                rm -f "$target"
                # Prune only what became empty; rmdir refuses non-empty dirs.
                rmdir "$module_dir/src/test/resources" 2>/dev/null
                rmdir "$module_dir/src/test" 2>/dev/null
                rmdir "$module_dir/src" 2>/dev/null
            fi
            echo "CLEAR    $name"
            removed=$((removed + 1))
        fi
    fi

    # Report anything still dirty, so a real change is never mistaken for noise —
    # which is the whole point of clearing the noise in the first place.
    if [[ -n "$APPLY" ]]; then
        residue="$(git -C "$module_dir" status --porcelain 2>/dev/null)"
        if [[ -n "$residue" ]]; then
            echo "  DIRTY $name still has:"
            printf '%s\n' "$residue" | sed 's/^/    /'
            other=$((other + 1))
        fi
    fi
done

echo ""
echo "already gitignored (the fix, applied): $ignored"
echo "committed by accident (needs a PR):    $tracked"
echo "content differs from template:         $differs"
if [[ -n "$APPLY" ]]; then
    echo "removed:                               $removed"
    echo "still dirty for other reasons:         $other"
else
    echo "would remove:                          $removed"
    echo ""
    echo "DRY RUN — re-run with --apply."
fi
