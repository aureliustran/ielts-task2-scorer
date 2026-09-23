# Rubric source

| | |
|---|---|
| Document | IELTS Writing Band Descriptors, "Updated May 2023" (Task 1 and Task 2; only Task 2 is used) |
| File | `ielts-writing-band-descriptors.pdf`, 141,876 bytes |
| SHA-256 | `e3c88943ef92d98988ce4db454fd7fa8d8435f0b25e9ec667e3720a5c1168d1b` |
| Obtained | 2026-09-23, supplied by the developer as a local download |
| URL | _not recorded; the PDF itself says "Please visit IELTS.org for updates"_ |

## How `task2_band_descriptors.md` was made

- **Text:** extracted with `pdftotext -raw` (content-stream order, one table cell at a
  time). Line breaks inside a cell were joined. Each descriptor sentence group stays on the
  line it has in the PDF.
- **Extraction artifacts fixed:** six places where the extractor dropped a space, checked
  against the `-layout` extraction: "followed effortlessly", "position is", "error-free
  sentences", "identifiable may", "inappropriate use", "predominate (except". No wording
  was changed.
- **Bold** (`**…**`) = the PDF's bold runs, found by font (`OpenSans-Bold`) in the page
  content streams. The PDF says bold marks "negative features that will limit a rating".
- **Structure:** reorganised from the PDF's band × criterion table into criterion → band.
  Band 0 applies to all criteria, so it has its own section.
- **Verified:** every descriptor line in the .md occurs verbatim in the extracted PDF text,
  and every extracted line occurs in the .md, apart from page headers, page numbers and
  band labels.
