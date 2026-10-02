(blocks, selecting) => {
    const flatten = element => {
        const points = [], walker = document.createTreeWalker(element, NodeFilter.SHOW_TEXT);
        let text = '', node;
        while ((node = walker.nextNode())) {
            if (node.parentElement?.closest('script, style')) continue;
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
    const visible = rect => rect.width > 0 && rect.height > 0 && rect.right > 0 && rect.bottom > 0 && rect.left < innerWidth && rect.top < innerHeight;
    if (!selecting) {
        const shown = mapped.filter(row => Array.from(row.range.getClientRects()).some(visible));
        if (!shown.length) return null;
        return {start: shown[0].block.start, end: shown.at(-1).block.start + shown.at(-1).block.text.length};
    }
    const selection = window.getSelection();
    if (!selection || selection.isCollapsed || !selection.rangeCount) return null;
    const selected = selection.getRangeAt(0), lower = selected.cloneRange(), upper = selected.cloneRange();
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
    const root = selected.commonAncestorContainer.nodeType === Node.ELEMENT_NODE ? selected.commonAncestorContainer : selected.commonAncestorContainer.parentElement;
    const path = [];
    for (let element = root; element.parentElement; element = element.parentElement) {
        path.unshift(':nth-child(' + (Array.from(element.parentElement.children).indexOf(element) + 1) + ')');
    }
    const before = selected.cloneRange(), after = selected.cloneRange();
    before.selectNodeContents(root); before.setEnd(selected.startContainer, selected.startOffset);
    after.selectNodeContents(root); after.setStart(selected.endContainer, selected.endOffset);
    return {start: offsets[0], end: offsets.at(-1) + 1, selector: [':root', ...path].join(' > '),
        text: {highlight: selected.toString(), before: before.toString().slice(-200), after: after.toString().slice(0, 200)}};
}
