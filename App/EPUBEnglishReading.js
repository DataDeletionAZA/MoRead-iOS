(() => {
    if (window.__moreadEnglish || !document.body) return;
    const nodes = [document.body, ...document.body.querySelectorAll('*')];
    nodes.forEach((node, index) => node.setAttribute('data-moread-source', String(index)));
    const state = window.__moreadEnglish = {signature: '', styles: [], snapshot: null, lastTap: null};
    state.query = selector => {
        if (!state.snapshot || selector.includes('data-moread-source')) return document.querySelectorAll(selector);
        return Array.from(state.snapshot.querySelectorAll(selector)).filter(node => node.hasAttribute('data-moread-source')).map(node => nodes[Number(node.getAttribute('data-moread-source'))]).filter(Boolean);
    };
    state.selector = node => {
        const original = (node.nodeType === Node.ELEMENT_NODE ? node : node.parentElement)?.closest('[data-moread-source]');
        return original ? '[data-moread-source="' + original.getAttribute('data-moread-source') + '"]' : null;
    };
    state.restore = locator => {
        const selector = locator?.locations?.cssSelector ?? locator?.selector;
        let original;
        try { original = selector ? state.query(selector)[0] : null; } catch {}
        const target = original ? {...locator, locations: {...locator.locations, cssSelector: state.selector(original)}} : locator;
        window.readium?.scrollToLocator(target);
    };
    const style = document.createElement('style');
    style.textContent = `
        [data-moread-english] { text-indent:0; }
        span[data-moread-english] { position:relative; }
        [data-moread-popup] { text-decoration:underline; text-decoration-color:teal; cursor:pointer; }
        [data-moread-gloss]::after { content:attr(data-moread-gloss); position:absolute; top:100%; left:var(--moread-gloss-center,50%); transform:translateX(-50%); width:var(--moread-gloss-width,100%); font:normal 0.46em/1.15 system-ui; white-space:pre; text-align:center; overflow:hidden; text-overflow:ellipsis; pointer-events:none; opacity:0.75; }
    `;
    document.head.appendChild(style);
    state.layout = () => {
        const groups = new Map();
        document.querySelectorAll('[data-moread-group]').forEach(node => {
            const key = node.getAttribute('data-moread-group');
            if (!groups.has(key)) groups.set(key, []);
            groups.get(key).push(...node.getClientRects());
        });
        const labels = Array.from(document.querySelectorAll('[data-moread-gloss]')).map(node => {
            const first = node.getBoundingClientRect();
            const parts = (groups.get(node.getAttribute('data-moread-group')) ?? []).filter(rect => Math.abs(rect.top - first.top) < 3);
            const left = Math.min(first.left, ...parts.map(rect => rect.left)), right = Math.max(first.right, ...parts.map(rect => rect.right));
            node.style.setProperty('--moread-gloss-center', ((left + right) / 2 - first.left) + 'px');
            return {node, rect:{left, right, top:first.top, width:right-left}};
        });
        for (let i = 0; i < labels.length; i++) {
            const {node, rect} = labels[i], center = (rect.left + rect.right) / 2;
            const previous = labels[i - 1], next = labels[i + 1];
            const sameLine = item => item && Math.abs(item.rect.top - rect.top) < 3;
            const page = Math.floor(center / innerWidth) * innerWidth;
            const left = sameLine(previous) ? (previous.rect.right + rect.left) / 2 + 2 : page + 16;
            const right = sameLine(next) ? (rect.right + next.rect.left) / 2 - 2 : page + innerWidth - 16;
            node.style.setProperty('--moread-gloss-width', Math.max(rect.width, 2 * Math.min(center - left, right - center)) + 'px');
        }
    };
    state.apply = (config, mapped) => {
        if (!state.snapshot) {
            const snapshot = document.implementation.createHTMLDocument('');
            const copy = node => {
                const result = snapshot.importNode(node, false);
                for (const child of node.children) result.appendChild(copy(child));
                return result;
            };
            snapshot.replaceChild(copy(document.documentElement), snapshot.documentElement); state.snapshot = snapshot;
        }
        const decorations = ['annotations', 'speech'].flatMap(name => {
            const group = window.readium?.getDecorations(name);
            return (group?.items ?? []).map(item => {
                const selector = state.selector(item.range.commonAncestorContainer);
                return {group, value:{...item.decoration, locator:{...item.decoration.locator, locations:{...item.decoration.locator.locations, cssSelector:selector}}}};
            });
        });
        document.querySelectorAll('[data-moread-english]').forEach(node => node.replaceWith(...node.childNodes));
        state.styles.forEach(({node, value, priority}) => value ? node.style.setProperty('line-height', value, priority) : node.style.removeProperty('line-height'));
        state.styles = []; state.lastTap = null;
        const edits = new Map(), spaced = new Set();
        for (const row of mapped) {
            const points = new Map(); let cursor = 0;
            for (let i = 0; i < row.block.text.length; i++) if (!/\s/u.test(row.block.text[i])) points.set(i, row.points[cursor++]);
            for (const match of row.block.text.matchAll(/[A-Za-z]+(?:['’\-][A-Za-z]+)*/g)) {
                if (match[0].length > 80) continue;
                const word = match[0].replaceAll('’', "'").toLowerCase(), gloss = config.words[word];
                const marked = config.mode !== 'off' && Object.hasOwn(config.words, word);
                if (!config.bionic && !marked) continue;
                const start = row.block.start + match.index, end = start + match[0].length;
                let i = 0, first = true;
                while (i < match[0].length) {
                    const point = points.get(match.index + i); if (!point) break;
                    const lower = i; i++;
                    while (i < match[0].length) {
                        const next = points.get(match.index + i);
                        if (!next || next.node !== point.node || next.offset !== point.offset + i - lower) break;
                        i++;
                    }
                    const span = document.createElement('span'); span.setAttribute('data-moread-english', '');
                    const text = point.node.data.slice(point.offset, point.offset + i - lower);
                    const prefix = config.bionic ? Math.max(0, Math.min(text.length, Math.ceil(match[0].length / 2) - lower)) : 0;
                    if (prefix) {
                        const bold = document.createElement('strong'); bold.setAttribute('data-moread-english', ''); bold.style.fontWeight = 'bold';
                        bold.textContent = text.slice(0, prefix); span.append(bold, text.slice(prefix));
                    } else span.textContent = text;
                    if (marked && config.mode === 'popup') {
                        span.setAttribute('data-moread-popup', ''); span.dataset.word = word; span.dataset.start = start; span.dataset.end = end;
                    }
                    if (marked && config.mode === 'inline') span.setAttribute('data-moread-group', String(start));
                    if (first && marked && config.mode === 'inline' && gloss[0]) {
                        span.setAttribute('data-moread-gloss', gloss[0] + (gloss[1] ? '\n' + gloss[1] : ''));
                        let parent = point.node.parentElement;
                        while (parent && (parent.hasAttribute('data-moread-english') || getComputedStyle(parent).display === 'inline')) parent = parent.parentElement;
                        if (parent && !spaced.has(parent)) {
                            const computed = getComputedStyle(parent), size = parseFloat(computed.fontSize);
                            state.styles.push({node:parent, value:parent.style.getPropertyValue('line-height'), priority:parent.style.getPropertyPriority('line-height')});
                            parent.style.setProperty('line-height', ((parseFloat(computed.lineHeight) || size * 1.2) + size * 1.2) + 'px', 'important'); spaced.add(parent);
                        }
                    }
                    if (!edits.has(point.node)) edits.set(point.node, []);
                    edits.get(point.node).push({start:point.offset, end:point.offset + text.length, span}); first = false;
                }
            }
        }
        for (const [node, ranges] of edits) {
            const fragment = document.createDocumentFragment(); let offset = 0;
            for (const edit of ranges.sort((a,b) => a.start - b.start)) {
                if (edit.start < offset) continue;
                fragment.append(node.data.slice(offset, edit.start), edit.span); offset = edit.end;
            }
            fragment.append(node.data.slice(offset)); node.replaceWith(fragment);
        }
        document.body.normalize();
        state.signature = JSON.stringify(config); state.layout();
        decorations.forEach(({group, value}) => group.update(value));
    };
    document.addEventListener('pointerup', event => {
        const word = event.target.closest?.('[data-moread-popup]');
        state.lastTap = word && window.getSelection()?.isCollapsed ? {word:word.dataset.word, start:Number(word.dataset.start), end:Number(word.dataset.end), time:Date.now()} : null;
    }, true);
    window.addEventListener('resize', state.layout);
})();
