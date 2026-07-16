# MyaeEditor Performance Improvement PRD

**Status:** Implemented; Instruments acceptance validation pending  
**Owner:** MyaeEditor maintainers  
**Target:** Native macOS editor and `MyaeEditorKit` Swift package  
**Last updated:** July 16, 2026

## 1. Summary

MyaeEditor is responsive for typical Markdown documents, but several operations scale with the full size of a text segment, code block, table, image, or document. Those operations can cause visible latency and elevated memory use when editing large or media-heavy files.

This project will improve large-document responsiveness without changing Markdown output, editor behavior, or the public API unless an API change is explicitly approved. The first release will focus on text-marker drawing, code editing, and duplicate Markdown encoding because these paths affect direct interaction and have the clearest avoidable work.

## 2. Problem statement

The editor already uses lazy segment rendering, debounced autosave, incremental syntax highlighting for most languages, cached math rendering, cached style data, and equatable table cells. Remaining bottlenecks are concentrated in these paths:

1. List, todo, and quote marker drawing scans every paragraph in a text segment whenever the text view draws.
2. Code editing copies the entire attributed code block into the segment model after every keystroke.
3. CSS and HTML highlighting performs whole-block regular-expression scans even when the edited range is a single line.
4. Binding-based editing encodes the complete document twice after edits settle.
5. Image blocks load full source images synchronously and do not downsample them to their displayed size.
6. Each visible Mermaid block owns a `WKWebView` and loads its own page, increasing memory and initialization work.
7. Manual saving waits synchronously for disk I/O.

These costs may be imperceptible in small documents but grow with document size. The result can be delayed keystrokes, uneven scrolling, pauses after editing settles, and excessive memory use.

## 3. Goals

- Keep typing and scrolling responsive in large text segments and code blocks.
- Make common per-keystroke work proportional to the edited or visible range, not the entire block.
- Avoid redundant full-document Markdown conversion.
- Reduce memory use and main-thread work for large images and Mermaid-heavy documents.
- Preserve document fidelity, undo behavior, caret position, selection, syntax colors, and autosave ordering.
- Establish repeatable performance fixtures and measurements so regressions are detectable.

## 4. Non-goals

- Replacing SwiftUI, AppKit, TextKit 1, WebKit, or the segment-based document architecture.
- Changing supported Markdown syntax or its normalized output.
- Adding new editor features or redesigning the interface.
- Optimizing startup, packaging, or DMG creation unless profiling identifies a regression caused by this work.
- Guaranteeing identical results across all hardware; targets are measured on a documented reference Mac and compared with the pre-change baseline.

## 5. Users and scenarios

### Primary users

- People editing long notes, specifications, technical documents, or imported Markdown files.
- Developers editing large fenced code blocks, including CSS and HTML.
- People working with documents containing high-resolution images or multiple Mermaid diagrams.
- Applications embedding `MyaeEditorKit` through a Markdown binding.

### Critical scenarios

1. Scroll through a text segment containing thousands of paragraphs and list items.
2. Type continuously near the beginning, middle, and end of a 100,000-character code block.
3. Edit a large CSS or HTML code block without whole-block highlighting on ordinary keystrokes.
4. Pause after editing a one-megabyte document while binding synchronization and autosave settle.
5. Scroll a document containing several high-resolution photographs.
6. Open and revisit a document containing multiple Mermaid blocks.

## 6. Success metrics

Before implementation, record a baseline for every fixture in Section 9. Final thresholds apply to release builds on the same reference machine with animations disabled where appropriate.

### Required metrics

| Area | Metric | Acceptance target |
| --- | --- | --- |
| Text drawing | Time spent in marker preparation while scrolling the large-list fixture | At least 70% lower than baseline; work is bounded to visible/dirty paragraphs except cached numbering updates |
| Text scrolling | Frames exceeding 16.7 ms in the large-list fixture | At least 50% fewer than baseline, with no recurring multi-frame stall caused by marker scanning |
| Code typing | Main-thread time for an ordinary single-character edit in a 100,000-character Swift block | p95 under 16 ms and no complete attributed-string model copy per keystroke |
| CSS/HTML typing | Characters inspected for an ordinary edit without a multiline delimiter change | Bounded to the affected line or invalidated region, not the full block |
| Settled edits | Full-document encodes per debounce cycle in binding mode | Exactly one |
| Settled edits | Main-thread encode and binding work for the one-megabyte fixture | At least 40% lower than baseline |
| Images | Main-thread image loading/decode stall for a 24-megapixel source | No synchronous full-image decode on the main actor; displayed image is downsampled near its presentation size |
| Memory | Resident-memory growth after displaying ten 24-megapixel images | At least 60% lower than baseline after images settle |
| Correctness | Existing and new regression tests | 100% passing |

### Guardrails

- Markdown produced before and after the optimization must be equivalent for all existing codec fixtures.
- Undo and redo must remain correct for text, code, and table edits.
- Caret and selection must not jump during typing, focus changes, highlighting, or external binding updates.
- Autosave writes must remain serialized; an older autosave must never overwrite a newer manual save.
- Cached render data must be bounded and must respond correctly to font, appearance, source, and file changes.

## 7. Requirements and priority

### P0 — Interaction-critical work

#### R1. Visible-range marker rendering

- Marker drawing must use `dirtyRect`, the visible glyph range, or an equivalent bounded range.
- Paragraph locations and numbered-list ordinals may be cached, but the cache must be invalidated or updated after edits that affect paragraph boundaries, kinds, indentation, or numbering.
- Checkbox hit testing must remain accurate for visible checkboxes.
- Numbered lists must retain correct ordinals even when the beginning of the list is outside the visible range.
- Reusable marker assets, such as configured checkbox symbols, should not be recreated for every paragraph draw.

#### R2. Shared code storage

- Editing a code block must not create a full `NSAttributedString` copy on every keystroke.
- The code segment model and live text view should share a mutable storage object or use an equivalent change-tracking design.
- Markdown encoding must always observe the latest code text.
- Syntax highlighting attribute changes must not create recursive content-edit notifications, corrupt undo history, or move the caret.
- Structural replacement of a code segment, such as paste, load, or language change, must still update the view correctly.

#### R3. Truly incremental CSS and HTML highlighting

- CSS regular expressions and HTML tag matching must accept and honor the requested scan range.
- Matches returned to the highlighter must use document-relative ranges.
- Edits that can change multiline constructs must fall back to a correctness-preserving wider or full scan.
- Initial rendering, paste, font change, and language change may perform a full scan.

#### R4. Single encode per settled edit

- `editsSettled` must make the encoded Markdown available to internal binding synchronization without invoking `controller.markdown` again.
- Public `onChange` behavior must remain source-compatible unless an intentional API revision is separately approved.
- Dirty-state comparison, callback delivery, binding write-back, and autosave must all use the same encoded snapshot for a debounce cycle.

### P1 — Media and memory work

#### R5. Asynchronous, downsampled image loading

- File reading and image decoding must occur away from the main actor.
- Images must be downsampled using Image I/O or an equivalent mechanism to a size appropriate for the editor's maximum rendered dimensions and display scale.
- Results should be cached with a bounded cost policy keyed by canonical URL and file modification state.
- Changing an image path or replacing the file must invalidate stale results.
- Missing, corrupt, and unsupported images must continue to show the placeholder without crashing.
- Cancellation must prevent an off-screen or replaced image task from publishing obsolete results.

#### R6. Mermaid render reuse

- Measure the memory and time cost of multiple inline `WKWebView` instances before choosing an implementation.
- Cache rendered output by source, theme, background, Mermaid version, and relevant scale.
- Prefer a static rendered representation for inactive inline diagrams if it preserves visual quality and click-to-edit behavior.
- Keep the zoom/pan viewer interactive.
- Bound all render caches and release work when blocks leave the document.
- Syntax errors must remain visible and must not poison the cache for later corrected input.

### P2 — Secondary scalability work

#### R7. Non-blocking manual save

- Provide a non-blocking save path for UI callers while preserving ordered writes and success/failure reporting.
- Retain a documented synchronous path only where required for termination or compatibility.
- Prevent document state from being marked saved until the write succeeds.

#### R8. Large-table validation and optimization

- Profile body recomputation, live cell count, layout, and Markdown conversion using the large-table fixture.
- If table work exceeds the frame or typing budgets, reduce parent recomputation and instantiate only visible rows and columns where practical.
- Do not sacrifice equal column widths, row-height alignment, keyboard navigation, or focus retention.

## 8. Proposed delivery phases

### Phase 0: Measurement foundation

- Add reproducible fixture generators or checked-in fixtures.
- Add `os_signpost` intervals around marker preparation, syntax highlighting, Markdown encoding, image decode, Mermaid render, and save operations.
- Record baseline traces, wall-clock measurements, allocations, and resident memory.
- Document the reference hardware, macOS version, build configuration, and test procedure.

### Phase 1: Text and code responsiveness

- Implement R1 through R4.
- Add correctness tests for numbering-cache invalidation and incremental CSS/HTML highlighting.
- Re-run the text, code, and settled-edit benchmarks.
- Ship independently if all P0 targets and guardrails pass.

### Phase 2: Media scalability

- Implement R5.
- Prototype and measure Mermaid caching options before implementing R6.
- Run memory, cancellation, appearance-change, and invalid-file tests.

### Phase 3: Save and table follow-up

- Implement R7 if manual-save profiling shows user-visible blocking.
- Implement R8 only where measurements show that current lazy/equatable behavior misses the target.
- Remove instrumentation that is too noisy for release builds while retaining useful signposts.

## 9. Performance fixtures and test method

Create deterministic fixtures representing the following workloads:

| Fixture | Contents |
| --- | --- |
| Large plain text | 10,000 paragraphs with no markers |
| Large mixed list | 10,000 paragraphs containing nested bullets, numbered lists, todos, and quotes |
| Large Swift block | One 100,000-character fenced Swift block |
| Large CSS block | One 100,000-character fenced CSS block with comments, strings, selectors, and declarations |
| Large HTML block | One 100,000-character fenced HTML block with tags and embedded-looking text |
| Large Markdown document | At least one megabyte of mixed text, inline formatting, tables, and code |
| Large table | 1,000 rows by 20 columns with representative inline Markdown |
| Image-heavy document | Ten local 24-megapixel images |
| Mermaid-heavy document | Twenty diagrams with repeated and unique sources |

### Measurement procedure

1. Build the complete app in Release configuration.
2. Launch with one fixture at a time and allow initial layout to settle.
3. Capture Time Profiler, Core Animation, Allocations, and Memory Graph data as relevant.
4. Repeat each interaction at least five times after one warm-up run.
5. Report median and p95 values where the tooling supports them.
6. Compare before and after traces on the same machine and OS version.
7. Keep trace summaries and fixture-generation instructions with the pull request.

Automated microbenchmarks should supplement Instruments traces but must not replace end-to-end UI profiling.

## 10. Testing requirements

### Unit and regression tests

- Existing `SegmentCodecTests` and `MyaeEditorControllerTests` remain green.
- Add tests for marker-numbering cache updates after insertion, deletion, kind change, and depth change.
- Add tests verifying incremental CSS/HTML output matches a full highlight pass.
- Add tests verifying one settled edit produces one encoded snapshot in binding mode.
- Add image-loader tests for downsampling, cache identity, invalidation, errors, and cancellation.
- Add Mermaid cache-key and eviction tests if render caching is implemented outside WebKit.

### Manual interaction checks

- Type, paste, undo, and redo within regular text and every code language.
- Move the caret between segments and table cells.
- Toggle light/dark mode and editor fonts.
- Edit numbered lists above and below the viewport.
- Replace and remove images while loads are in flight.
- Edit a Mermaid diagram, introduce an error, correct it, and open the zoom viewer.
- Save locally and to a deliberately slow volume if available.

## 11. Risks and mitigations

| Risk | Mitigation |
| --- | --- |
| Visible-range drawing produces wrong numbered-list ordinals | Cache document-relative numbering and invalidate from the earliest affected paragraph |
| Shared mutable code storage causes observation or undo bugs | Keep one authoritative storage object and distinguish text edits from attribute-only highlighting edits |
| Incremental highlighting misses a multiline state transition | Detect risky delimiters and expand the invalidation range or use a full scan |
| Async image tasks publish stale results | Use task cancellation plus a request identity check before updating view state |
| Image cache retains too much memory | Use `NSCache` cost limits and downsample before caching |
| Mermaid caching displays stale appearance or output | Include source, theme, background, Mermaid version, and scale in the cache key |
| Async saving changes callback ordering | Preserve the existing serial queue and publish state changes on the main actor after write completion |
| Benchmarks become hardware-dependent or flaky | Evaluate baseline-relative improvements and document the reference environment |

## 12. Observability

Use stable signpost names so performance changes can be compared across branches:

- `MarkerPreparation`
- `SyntaxHighlight`
- `MarkdownEncode`
- `ImageDecode`
- `MermaidRender`
- `DocumentWrite`

Signposts should include non-sensitive dimensions such as character count, paragraph count, scan length, image pixel dimensions, table dimensions, and whether an operation was incremental or full. Do not include document contents, paths, URLs, or LaTeX/Mermaid source.

## 13. Rollout and compatibility

- Land P0 and P1 work in focused pull requests so each optimization is independently measurable and reversible.
- Each pull request must include before/after measurements, tests run, and any public API or Markdown compatibility impact.
- Use internal implementation changes by default. Any public save or callback API addition must be additive and documented.
- No migration should be required for saved Markdown documents.

## 14. Definition of done

The project is complete when:

- All P0 requirements meet their acceptance targets.
- P1 work meets its image targets, and Mermaid work has either shipped with measured benefit or been explicitly deferred with evidence.
- Existing and added tests pass under `swift test` and the full app target builds successfully.
- Instruments traces show no new dominant main-thread bottleneck in the critical scenarios.
- Markdown round trips, undo/redo, selection, focus, autosave ordering, and error states pass manual regression testing.
- Performance fixtures, measurement instructions, and before/after results are documented for future regression checks.

## 15. Implementation record

Implemented on July 16, 2026:

- Added range-aware marker indexing with edited-suffix invalidation and visible dirty-range drawing.
- Changed code segments to share `NSTextStorage` with their live editor.
- Bounded CSS and HTML highlighting to the invalidated range, including multiline-comment expansion.
- Reused the settled Markdown snapshot for binding synchronization.
- Added off-main Image I/O downsampling with modification-aware, cost-bounded caching.
- Added bounded, theme-aware Mermaid SVG reuse across inline web views.
- Added ordered asynchronous save APIs and migrated the app commands to them, including edit-generation and superseded-save protection.
- Added Points of Interest signposts, deterministic fixture generators, profiling instructions, and regression coverage.
- Validated the 1,000×20 table codec path; the existing lazy rows and equatable cells remain in place pending UI trace evidence that a layout rewrite is necessary.

Automated correctness and build validation is complete. The baseline-relative frame,
latency, and resident-memory thresholds in Section 6 require interactive Instruments
traces on the chosen reference Mac; use `performance-profiling.md` to record them.

## 16. Open questions

- What reference Mac and minimum supported hardware should define the absolute latency targets?
- Should code segments expose shared mutable storage internally, or should the segment payload remain immutable with a separate storage owner?
- Is a source-compatible internal callback sufficient for passing settled Markdown, or should the public API eventually offer an encoded-value callback?
- Should inactive Mermaid diagrams be static images/SVG, or is per-block WebKit interactivity a product requirement?
- What cache budgets are appropriate for image and Mermaid output on the minimum supported hardware?
- Is synchronous `save(to:) -> Bool` a compatibility requirement, or can UI clients migrate to an async overload?
