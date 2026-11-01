(() => {
  'use strict';
  const code = document.getElementById('code'), picker = document.getElementById('picker'), drop = document.getElementById('drop'), notice = document.getElementById('notice');
  const linked = new URLSearchParams(location.hash.slice(1)).get('code');
  if (/^\d{6}$/.test(linked || '')) code.value = linked;
  if (location.hash) history.replaceState(null, '', location.pathname);
  let pending = [], active = null;
  function enqueue(files) {
    notice.textContent = '';
    if (!/^\d{6}$/.test(code.value)) { notice.textContent = '请先输入手机显示的六位连接码。'; code.focus(); return; }
    for (const file of Array.from(files || [])) {
      const item = document.createElement('article'); item.className = 'item';
      item.innerHTML = '<div class="head"><div><div class="name"></div><div class="state" role="status"></div></div><div class="actions"><button type="button">取消</button></div></div><div class="bar"><span></span></div>';
      item.querySelector('.name').textContent = file.name; document.getElementById('rows').append(item); document.getElementById('queue').hidden = false;
      const entry = {file, item, cancelled: false, request: null, button: item.querySelector('button')};
      entry.button.addEventListener('click', () => {
        if (entry.button.textContent === '重试') { entry.cancelled = false; entry.button.textContent = '取消'; item.className = 'item'; pending.push(entry); state(entry, '等待中'); pump(); }
        else { entry.cancelled = true; pending = pending.filter(value => value !== entry); if (entry.request) entry.request.abort(); else finish(entry, false, '已取消'); }
      });
      if (!/\.(txt|epub)$/i.test(file.name)) { finish(entry, false, '只支持 TXT 和 EPUB'); entry.button.hidden = true; }
      else if (!file.size || file.size > 200 * 1024 * 1024) { finish(entry, false, file.size ? '文件超过 200 MB' : '文件为空'); entry.button.hidden = true; }
      else { state(entry, '等待中'); pending.push(entry); }
    }
    pump();
  }
  function state(entry, text) { entry.item.querySelector('.state').textContent = text; }
  function finish(entry, ok, message) {
    state(entry, message); entry.item.classList.add(ok ? 'done' : 'fail'); entry.button.hidden = ok; entry.button.textContent = '重试';
    if (ok) entry.item.querySelector('.bar span').style.width = '100%';
  }
  function pump() {
    if (active) return;
    while (pending.length && pending[0].cancelled) pending.shift();
    const entry = pending.shift(); if (!entry) return; active = entry;
    const request = new XMLHttpRequest(); entry.request = request; let completed = false;
    const end = (ok, message) => { if (completed) return; completed = true; finish(entry, ok, message); entry.request = null; active = null; queueMicrotask(pump); };
    if (!/^\d{6}$/.test(code.value)) { end(false, '请填写手机显示的六位连接码后重试'); return; }
    request.open('POST', '/upload'); request.timeout = 30 * 60 * 1000;
    request.setRequestHeader('X-File-Name', encodeURIComponent(entry.file.name)); request.setRequestHeader('X-MoRead-Code', code.value); request.setRequestHeader('Content-Type', 'application/octet-stream');
    request.upload.onprogress = event => { if (event.lengthComputable) { const value = Math.round(event.loaded / event.total * 100); entry.item.querySelector('.bar span').style.width = value + '%'; state(entry, value === 100 ? '正在确认接收…' : value + '%'); } };
    request.onload = () => {
      if (request.status === 200) end(true, '已送达手机');
      else { let error = '上传失败（' + request.status + '）'; try { error = JSON.parse(request.responseText).error || error; } catch (_) {} end(false, error); }
    };
    request.onerror = () => end(false, '连接中断，请确认手机传书页面仍然打开');
    request.ontimeout = () => end(false, '传输超时，可重试'); request.onabort = () => end(false, '已取消');
    state(entry, '正在连接…'); request.send(entry.file);
  }
  drop.addEventListener('click', () => picker.click());
  picker.addEventListener('change', () => { enqueue(picker.files); picker.value = ''; });
  for (const event of ['dragenter', 'dragover']) drop.addEventListener(event, e => { e.preventDefault(); drop.classList.add('over'); });
  for (const event of ['dragleave', 'drop']) drop.addEventListener(event, e => { e.preventDefault(); drop.classList.remove('over'); });
  drop.addEventListener('drop', e => enqueue(e.dataTransfer?.files));
  window.addEventListener('dragover', e => e.preventDefault()); window.addEventListener('drop', e => e.preventDefault());
})();
