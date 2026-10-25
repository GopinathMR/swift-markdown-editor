# The only place these commands are written. The workflows call these targets,
# so a contributor's local run is byte-identical to the CI gate.
SWIFT_FORMAT_PATHS := Package.swift Sources Tests demo/Package.swift demo/Sources demo/Tests
# The prebuilt grammar xcframework ships without its object files; the linker's
# "unable to open object file" lines are noise, not errors.
QUIET := 2>&1 | grep -v "unable to open object file"

.PHONY: format-check format build test demo demo-test

## Report violations as file:line:col: error: [Rule]. Non-zero exit if any.
format-check:
	swift format lint --strict --recursive $(SWIFT_FORMAT_PATHS)

## Rewrite the same paths in place to match swift format's defaults.
format:
	swift format --in-place --recursive $(SWIFT_FORMAT_PATHS)

build:
	set -o pipefail; swift build $(QUIET)

test:
	set -o pipefail; swift test $(QUIET)

## Build and launch the demo. `make demo FILE=README.md` opens that file.
demo:
	swift run --package-path demo MarkdownEditorDemo $(if $(FILE),-file $(abspath $(FILE)))

## Build and test the demo without launching it (the CI gate).
demo-test:
	set -o pipefail; swift build --package-path demo $(QUIET)
	set -o pipefail; swift test --package-path demo $(QUIET)
