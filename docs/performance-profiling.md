# Performance profiling guide

Use this guide with the requirements and acceptance targets in
[`performance-improvement-prd.md`](performance-improvement-prd.md).

## Generate deterministic fixtures

```sh
swift tools/generate-performance-fixtures.swift /tmp/MyaeEditorPerformance
```

The generator creates the large list, Swift/CSS/HTML code, one-megabyte mixed
document, 1,000×20 table, twenty-diagram Mermaid, and ten-image fixtures. Image
generation is intentionally not part of `swift test` because it creates ten
24-megapixel sources.

## Build for measurement

```sh
xcodebuild \
  -project MyaeEditor.xcodeproj \
  -scheme MyaeEditor \
  -configuration Release \
  -destination 'platform=macOS' \
  -derivedDataPath /tmp/MyaeEditorDerivedData \
  build
```

Use the same Mac, display scale, macOS version, window dimensions, and Release
configuration for before/after comparisons. Close unrelated high-load apps and
perform one warm-up pass before recording five measured passes.

## Instruments intervals

The package emits Points of Interest intervals with these stable names:

- `MarkerPreparation`
- `SyntaxHighlight`
- `MarkdownEncode`
- `ImageDecode`
- `MermaidRender`
- `DocumentWrite`

Record Time Profiler and Core Animation for typing/scrolling scenarios. Record
Allocations and Memory Graph for image and Mermaid scenarios. No signpost contains
document text, source code, paths, URLs, or diagram content.

## Scenario checklist

1. Open the fixture and wait until initial layout/rendering settles.
2. For lists, scroll from top to bottom and back at a consistent trackpad speed.
3. For code, type ten characters at the beginning, middle, and end of the block.
4. For settled-edit cost, type once in the one-megabyte document and wait through
   the configured debounce interval.
5. For images and Mermaid, record memory after initial rendering, after scrolling
   every block into view, and after returning to the first block.
6. Export trace summaries and report median and p95 measurements in the pull request.

Automated regression tests verify bounded caches, range-equivalent highlighting,
shared code storage, downsampling, single settled snapshots, and large-table codec
behavior. They complement but do not replace the UI traces above.
