(blocks, selecting, translations = null, restoring = null) => {
    const marker = '[data-moread-translation]';
    const flatten = element => {
        const points = [], walker = document.createTreeWalker(element, NodeFilter.SHOW_TEXT);
        let text = '', node;
        while ((node = walker.nextNode())) {
            if (node.parentElement?.closest('script, style, ' + marker)) continue;
            for (let i = 0; i < node.data.length; i++) {
                if (/\s/u.test(node.data[i])) continue;
                text += node.data[i]; points.push({node, offset: i});
            }
        }
        return {text, points};
    };
    const compact = value => value.replace(/\s/gu, '');
    const cache = new Map(), cursors = new Map(), mapped = [];
    for (const block of blocks) {
        let elements;
        try { elements = document.querySelectorAll(block.selector); } catch { continue; }
        if (elements.length !== 1) continue;
        const element = elements[0];
        if (!cache.has(element)) cache.set(element, flatten(element));
        const flat = cache.get(element), wanted = compact(block.text);
        if (!wanted) continue;
        const start = flat.text.indexOf(wanted, cursors.get(element) ?? 0);
        if (start < 0) continue;
        const points = flat.points.slice(start, start + wanted.length);
        cursors.set(element, start + wanted.length);
        const range = document.createRange();
        range.setStart(points[0].node, points[0].offset);
        range.setEnd(points.at(-1).node, points.at(-1).offset + 1);
        mapped.push({block, points, range});
    }
    if (!mapped.length) return null;
    const visible = rect => rect.width > 0 && rect.height > 0 && rect.right > 0 && rect.bottom > 0 && rect.left < innerWidth && rect.top < innerHeight;
    const isVisible = range => Array.from(range.getClientRects()).some(visible);
    const originalText = range => {
        const fragment = range.cloneContents();
        fragment.querySelectorAll(marker).forEach(node => node.remove());
        return fragment.textContent;
    };
    const describe = range => {
        const root = range.commonAncestorContainer.nodeType === Node.ELEMENT_NODE ? range.commonAncestorContainer : range.commonAncestorContainer.parentElement;
        const path = [];
        for (let element = root; element.parentElement; element = element.parentElement) {
            path.unshift(':nth-child(' + (Array.from(element.parentElement.children).indexOf(element) + 1) + ')');
        }
        const before = range.cloneRange(), after = range.cloneRange();
        before.selectNodeContents(root); before.setEnd(range.startContainer, range.startOffset);
        after.selectNodeContents(root); after.setStart(range.endContainer, range.endOffset);
        return {selector: [':root', ...path].join(' > '), text: {
            highlight: originalText(range), before: originalText(before).slice(-200), after: originalText(after).slice(0, 200)
        }};
    };
    const visibleAnchor = row => {
        for (const point of row.points) {
            const range = document.createRange();
            range.setStart(point.node, point.offset);
            range.setEnd(point.node, point.offset + (point.node.data.codePointAt(point.offset) > 0xFFFF ? 2 : 1));
            if (isVisible(range)) return range;
        }
        return row.range;
    };
    const state = window.__moreadTranslations ??= {signature: '[]', nodes: []};
    const shownRows = () => {
        const translatedBlocks = new Set(state.nodes.filter(item => isVisible(item.element)).map(item => item.blockStart));
        return mapped.filter(row => isVisible(row.range) || translatedBlocks.has(row.block.start));
    };
    const changed = translations !== null && state.signature !== JSON.stringify(translations);
    if (changed) {
        const first = shownRows()[0];
        const anchor = first ? visibleAnchor(first) : null;
        const oldTop = anchor?.getBoundingClientRect().top;
        state.nodes.forEach(item => item.element.remove()); state.nodes = [];
        let blockIndex = 0;
        for (const translation of translations) {
            while (blockIndex < mapped.length && mapped[blockIndex].block.start + mapped[blockIndex].block.text.length < translation.end) blockIndex++;
            const row = mapped[blockIndex];
            if (!row || translation.start < row.block.start) continue;
            let parent = row.range.commonAncestorContainer;
            if (parent.nodeType !== Node.ELEMENT_NODE) parent = parent.parentElement;
            while (parent.parentElement && getComputedStyle(parent).display === 'inline') parent = parent.parentElement;
            // Appending after existing children preserves the source's nth-child locators.
            const element = document.createElement('span');
            element.setAttribute('data-moread-translation', ''); element.lang = 'zh-Hans';
            element.style.cssText = 'display:block;clear:both;font-family:system-ui;font-size:0.9em;line-height:1.6;margin-block:0.5em;white-space:pre-wrap;opacity:0.8;text-indent:0;';
            element.textContent = translation.chinese; parent.appendChild(element);
            state.nodes.push({element, start: translation.start, end: translation.end, blockStart: row.block.start, range: row.range});
        }
        state.signature = JSON.stringify(translations);
        if (restoring) {
            window.readium?.scrollToLocator(restoring);
        } else if (anchor) {
            if (document.documentElement.style.getPropertyValue('--USER__view').trim() === 'readium-scroll-on') {
                document.scrollingElement.scrollTop += anchor.getBoundingClientRect().top - oldTop;
            } else {
                const target = describe(anchor);
                window.readium?.scrollToLocator({locations: {cssSelector: target.selector}, text: target.text});
            }
        }
    }
    if (!selecting) {
        const shown = shownRows();
        if (!shown.length) return null;
        return {changed, start: shown[0].block.start, end: shown.at(-1).block.start + shown.at(-1).block.text.length, ...describe(visibleAnchor(shown[0]))};
    }
    const selection = window.getSelection();
    if (!selection || selection.isCollapsed || !selection.rangeCount) return null;
    const selected = selection.getRangeAt(0);
    const translated = state.nodes.find(item => item.element.contains(selected.startContainer) && item.element.contains(selected.endContainer));
    if (translated) return {start: translated.start, end: translated.end, translation: true, ...describe(translated.range)};
    const lower = selected.cloneRange(), upper = selected.cloneRange();
    lower.collapse(true); upper.collapse(false);
    const offsets = [];
    for (const {block, points} of mapped) {
        let index = 0;
        for (let offset = 0; offset < block.text.length; offset++) {
            if (/\s/u.test(block.text[offset])) continue;
            const point = points[index++];
            if (lower.comparePoint(point.node, point.offset + 1) > 0 && upper.comparePoint(point.node, point.offset) < 0) offsets.push(block.start + offset);
        }
    }
    if (!offsets.length) return null;
    return {start: offsets[0], end: offsets.at(-1) + 1, ...describe(selected)};
}
