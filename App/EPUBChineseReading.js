(() => {
    if (window.__moreadChinese || !document.body) return;
    const marker = '[data-moread-translation]';
    const originals = new WeakMap();
    for (const parent of document.querySelectorAll('[data-moread-chinese]')) {
        const nodes = Array.from(parent.childNodes).filter(node => node.nodeType === Node.TEXT_NODE);
        for (const row of JSON.parse(parent.getAttribute('data-moread-chinese'))) {
            const node = nodes[row.index];
            if (!node || node.data !== row.display) throw new Error('EPUB Chinese text mapping mismatch');
            originals.set(node, row);
        }
        parent.removeAttribute('data-moread-chinese');
    }
    const textNodes = root => {
        const nodes = [], walker = document.createTreeWalker(root, NodeFilter.SHOW_TEXT);
        let node;
        while ((node = walker.nextNode())) if (!node.parentElement?.closest('script, style, ' + marker)) nodes.push(node);
        return nodes;
    };
    const runs = textNodes(document.body).map(node => ({parent:node.parentElement, source:node.data, display:node.data, stages:[], ...originals.get(node)}));
    const compact = text => text.replace(/\s/gu, '');
    const mappedOffset = (offset, stages, trailing) => stages.reduce((position, edits) => {
        let low = 0, high = edits.length;
        while (low < high) { const middle = (low + high) >> 1; if (edits[middle].sourceStart < position) low = middle + 1; else high = middle; }
        if (!low) return position;
        const edit = edits[low - 1], end = edit.sourceStart + edit.sourceLength;
        return position < end ? edit.displayStart + (trailing ? edit.displayLength : 0) : position + edit.displayStart + edit.displayLength - end;
    }, offset);
    let cache = new WeakMap();
    const raw = root => {
        if (cache.has(root)) return cache.get(root);
        const rows = runs.filter(row => root.contains(row.parent)), points = [];
        let actual = '';
        for (const node of textNodes(root)) {
            actual += node.data;
            for (let offset = 0; offset < node.data.length; offset++) points.push({node, offset});
        }
        if (rows.map(row => row.display).join('') !== actual) return null;
        let text = '', base = 0; const mapped = [];
        for (const row of rows) {
            text += row.source;
            for (let index = 0; index < row.source.length; index++) {
                const start = points[base + mappedOffset(index, row.stages, false)];
                const end = points[base + mappedOffset(index + 1, row.stages, true) - 1];
                if (!start || !end) return null;
                mapped.push({...start, endNode:end.node, endOffset:end.offset + 1});
            }
            base += row.display.length;
        }
        const result = {text, points:mapped}; cache.set(root, result); return result;
    };
    const canonical = root => {
        const value = raw(root); if (!value) return null;
        const points = []; let text = '';
        for (let i = 0; i < value.text.length; i++) if (!/\s/u.test(value.text[i])) { text += value.text[i]; points.push(value.points[i]); }
        return {text, points};
    };
    const intersects = (range, point) => {
        const lower = range.cloneRange(), upper = range.cloneRange(); lower.collapse(true); upper.collapse(false);
        return lower.comparePoint(point.endNode, point.endOffset) > 0 && upper.comparePoint(point.node, point.offset) < 0;
    };
    const originalText = range => {
        const container = range.commonAncestorContainer;
        const root = (container.nodeType === Node.ELEMENT_NODE ? container : container.parentElement).closest('[data-moread-source]') ?? document.body;
        const value = raw(root); if (!value) return null;
        let text = '';
        for (let i = 0; i < value.text.length; i++) if (intersects(range, value.points[i])) text += value.text[i];
        return text;
    };
    const actualText = range => {
        const copy = range.cloneContents(); copy.querySelectorAll(marker).forEach(node => node.remove()); return copy.textContent;
    };
    const displayLocator = locator => {
        if (!locator?.text?.highlight || locator.locations?.moreadChineseDisplay) return locator;
        const selector = locator.locations?.cssSelector;
        let root;
        try { root = selector ? (window.__moreadEnglish?.query(selector) ?? document.querySelectorAll(selector))[0] : document.body; } catch { return locator; }
        if (!root) return locator;
        const flat = canonical(root), needle = compact(locator.text.highlight);
        if (!flat || !needle) return locator;
        const before = compact(locator.text.before ?? ''), after = compact(locator.text.after ?? ''), hits = [];
        for (let start = flat.text.indexOf(needle); start >= 0; start = flat.text.indexOf(needle, start + needle.length)) {
            if (before && !flat.text.slice(0, start).endsWith(before)) continue;
            if (after && !flat.text.slice(start + needle.length).startsWith(after)) continue;
            hits.push(start);
        }
        if (hits.length !== 1) return locator;
        const first = flat.points[hits[0]], last = flat.points[hits[0] + needle.length - 1], range = document.createRange();
        range.setStart(first.node, first.offset); range.setEnd(last.endNode, last.endOffset);
        const leading = range.cloneRange(), trailing = range.cloneRange();
        leading.selectNodeContents(root); leading.setEnd(range.startContainer, range.startOffset);
        trailing.selectNodeContents(root); trailing.setStart(range.endContainer, range.endOffset);
        return {...locator, locations:{...locator.locations, moreadChineseDisplay:true}, text:{highlight:actualText(range), before:actualText(leading).slice(-200), after:actualText(trailing).slice(0,200)}};
    };
    const state = window.__moreadChinese = {begin:() => { cache = new WeakMap(); install(); }, flatten:canonical, originalText, displayLocator};
    let installed;
    function install() {
        const reader = window.readium;
        if (!reader || installed === reader) return;
        installed = reader;
        const scroll = reader.scrollToLocator;
        reader.scrollToLocator = locator => { state.begin(); return scroll(displayLocator(locator)); };
        const groups = new WeakSet(), get = reader.getDecorations;
        reader.getDecorations = name => {
            const group = get(name);
            if (!groups.has(group)) {
                groups.add(group);
                for (const key of ['add','update']) {
                    const action = group[key];
                    group[key] = value => { state.begin(); return action({...value, locator:displayLocator(value.locator)}); };
                }
            }
            return group;
        };
    }
    install();
    document.addEventListener('DOMContentLoaded', install, {once:true});
})();
