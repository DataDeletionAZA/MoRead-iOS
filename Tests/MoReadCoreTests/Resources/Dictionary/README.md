# Synthetic MDX/MDD fixtures

`sample-classical.mdx` adds short synthetic Chinese headwords and a classical phrase, plus a shared English entry for multi-dictionary switching. It includes an MDD stylesheet reference and an entry link; no published dictionary text is used.

Generated with [writemdict](https://github.com/zhansliu/writemdict), independently of the application's reader. Entries contain only tiny test strings (`apple`, `book`, `books`, `hello`, `world`); `books` links to `book`. The MDD contains a CSS snippet and a minimal SVG. No third-party dictionary content is included.

Variants cover v1 uncompressed, v2 zlib, UTF-16, encrypted key-block indexes, and binary resource records. The LZO fixture uses literal-only LZO1X blocks (length prefix, payload and EOF marker), assembled independently of the application's decompressor. Corruption tests modify copies in a temporary directory.

The original seven fixtures come from MoRead commit `2cd4e1761f4b9433c42aac7ffb760dbeca7f6ded`, `app/src/test/resources/dictionary/` (GPL-3.0).

`sample-gbk.mdx`, `sample-big5.mdx`, and `sample-boundaries.mdx` were generated with writemdict commit `f0240b30cabd2f0470d3ee1a0641fc7f8c38dcf5`. The first two contain `中文` with the definitions `中文释义` and `中文釋義`. The boundary dictionary contains `word000` through `word099`, with definitions `<b>N</b> ` followed by `跨块释义。` repeated `N % 5 + 1` times, an `alias` link to `word099`, and two circular links (`loopa` and `loopb`). Its key block size is 48 bytes; its concatenated record bytes were split every 19 bytes and independently zlib-compressed. This produces 35 key blocks and 297 record blocks, including UTF-8 characters split between record blocks. All records are synthetic.

`sample-display.mdx` contains synthetic `layout` and `hidden` entries for the iOS dictionary view. It includes a local SVG, an external link to the reserved `.invalid` domain, script text, and a hidden-body style. UI checks cover local rendering, blocked content scripts and external navigation, and plain-text reading without style/script contents. It was generated with the same writemdict revision listed above.

`sample-reading.mdx` contains synthetic English sample-book words and Chinese chapter-heading words, each with a short test definition. It uses the same writemdict revision and checks selection-to-vocabulary source navigation in TXT and EPUB.

`sample-scroll.mdx` contains one synthetic `apple` entry titled `滚动词典`: a heading, 30 numbered Chinese paragraphs and an end marker. It uses the same writemdict revision. UI checks use it alongside `sample-v2.mdx` to exercise both scroll boundaries, return to a saved paragraph after changing dictionaries, and switch between formatted and plain text.
