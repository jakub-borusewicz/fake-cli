set positional-arguments := true

# List available commands
default:
    @just --list

# Run the full check suite (matches CI)
check:
    nix flake check

# Cut a release: verify a clean, checked-out, up-to-date main, then tag and
# push. See CONTRIBUTING.md for the full procedure this encodes.
# Usage: just release 1.2.0 "Summary of the release, calling out breaking changes"
release version message:
    #!/usr/bin/env bash
    set -euo pipefail
    version="$1"
    message="$2"

    if [[ ! "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        echo "error: version must be MAJOR.MINOR.PATCH with no 'v' prefix (got: $version)" >&2
        exit 1
    fi
    tag="v$version"

    if [[ -n "$(git status --porcelain)" ]]; then
        echo "error: working tree is not clean; commit or stash before releasing" >&2
        exit 1
    fi

    branch="$(git rev-parse --abbrev-ref HEAD)"
    if [[ "$branch" != "main" ]]; then
        echo "error: release from 'main', not '$branch'" >&2
        exit 1
    fi

    git fetch origin main --quiet
    if [[ "$(git rev-parse HEAD)" != "$(git rev-parse origin/main)" ]]; then
        echo "error: local main is not up to date with origin/main; pull or push first" >&2
        exit 1
    fi

    if git rev-parse "$tag" >/dev/null 2>&1; then
        echo "error: tag $tag already exists" >&2
        exit 1
    fi

    echo "Running nix flake check..."
    nix flake check

    echo "Tagging $tag..."
    git tag -a "$tag" -m "$message"

    echo "Pushing $tag to origin..."
    git push origin "$tag"

    echo
    echo "Released $tag."
    echo "CI will run 'nix flake check -L' against the tagged commit."
    echo "Downstream consumers can now pin to it:"
    echo "  flake input:  github:jakub-borusewicz/fake-cli/$tag"
    echo "  classic Nix:  fetchFromGitHub { rev = \"$tag\"; hash = \"...\"; ... }"
