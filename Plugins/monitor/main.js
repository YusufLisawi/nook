(() => {
  'use strict';
  const $ = id => document.getElementById(id);
  const GIB = 1024 ** 3;
  const samples = { down: [], up: [] };
  const colors = () => {
    const css = getComputedStyle(document.documentElement);
    return Object.fromEntries(['good', 'accent', 'bad'].map(name => [name, css.getPropertyValue(`--${name}`).trim()]));
  };
  const number = value => typeof value === 'number' && Number.isFinite(value) ? value : null;
  const clamp = value => Math.min(1, Math.max(0, value));
  const amount = value => number(value) === null ? '—' : (Math.max(0, value) / GIB).toLocaleString(undefined, { maximumFractionDigits: 1 });
  const pressure = ratio => ratio >= .9 ? 'bad' : ratio >= .65 ? 'accent' : 'good';
  let systemBusy = false;
  let processesBusy = false;
  let stopped = false;

  function ring(name, ratio, label, tone, description) {
    const node = $(`${name}-ring`);
    node.style.color = colors()[tone];
    node.querySelector('.ring-value').style.strokeDashoffset = String(119.38052 * (1 - clamp(ratio ?? 0)));
    $(`${name}-percent`).textContent = label;
    node.setAttribute('aria-label', description);
  }

  function speed(value) {
    if (number(value) === null) return '—';
    const safe = Math.max(0, value);
    if (safe >= 1024 ** 3) return `${(safe / 1024 ** 3).toFixed(1)} GB/s`;
    if (safe >= 1024 ** 2) return `${(safe / 1024 ** 2).toFixed(1)} MB/s`;
    if (safe >= 1024) return `${(safe / 1024).toFixed(safe < 10240 ? 1 : 0)} KB/s`;
    return `${Math.round(safe)} B/s`;
  }

  function uptime(seconds) {
    if (number(seconds) === null) return '—';
    const minutes = Math.floor(Math.max(0, seconds) / 60);
    const hours = Math.floor(minutes / 60);
    return hours >= 24 ? `${Math.floor(hours / 24)}d ${hours % 24}h` : hours ? `${hours}h ${minutes % 60}m` : `${minutes}m`;
  }

  function drawChart(id, values, tone) {
    const canvas = $(id);
    const width = canvas.clientWidth;
    const height = canvas.clientHeight;
    if (!width || !height) return;
    const scale = Math.min(window.devicePixelRatio || 1, 3);
    canvas.width = Math.round(width * scale);
    canvas.height = Math.round(height * scale);
    const context = canvas.getContext('2d');
    if (!context) return;
    context.scale(scale, scale);
    context.strokeStyle = 'rgba(255,255,255,.07)';
    context.lineWidth = 1;
    context.beginPath();
    context.moveTo(0, height - 1);
    context.lineTo(width, height - 1);
    context.stroke();
    if (!values.length) return;
    const max = Math.max(1024, ...values);
    const points = values.map((value, index) => [
      1 + ((40 - values.length + index) / 39) * (width - 2),
      height - 2 - (value / max) * (height - 5)
    ]);
    if (points.length === 1) points.unshift([Math.max(0, points[0][0] - 3), points[0][1]]);
    context.strokeStyle = colors()[tone];
    context.lineWidth = 1.4;
    context.lineJoin = 'round';
    context.lineCap = 'round';
    context.beginPath();
    points.forEach(([x, y], index) => index ? context.lineTo(x, y) : context.moveTo(x, y));
    context.stroke();
    context.lineTo(points.at(-1)[0], height);
    context.lineTo(points[0][0], height);
    context.closePath();
    context.globalAlpha = .1;
    context.fillStyle = colors()[tone];
    context.fill();
  }

  function renderSystem(data) {
    if (!data || typeof data !== 'object') throw new Error('System data unavailable');
    const cpu = number(data.cpu?.usage);
    const cpuPercent = cpu === null ? '—' : `${Math.round(clamp(cpu) * 100)}%`;
    ring('cpu', cpu, cpuPercent, pressure(cpu ?? 0), `CPU usage ${cpuPercent}`);
    $('cpu-value').textContent = cpuPercent;
    $('cpu-detail').textContent = number(data.cpu?.cores) === null ? 'CPU usage' : `${data.cpu.cores} cores`;

    const memoryUsed = number(data.memory?.used);
    const memoryTotal = number(data.memory?.total);
    const memoryRatio = memoryUsed !== null && memoryTotal > 0 ? clamp(memoryUsed / memoryTotal) : null;
    const memoryPercent = memoryRatio === null ? '—' : `${Math.round(memoryRatio * 100)}%`;
    ring('memory', memoryRatio, memoryPercent, pressure(memoryRatio ?? 0), `Memory usage ${memoryPercent}`);
    $('memory-value').textContent = `${amount(memoryUsed)} / ${amount(memoryTotal)}`;

    const diskTotal = number(data.disk?.total);
    const diskUsed = number(data.disk?.used);
    const diskFree = number(data.disk?.free);
    const diskRatio = diskTotal > 0 && diskUsed !== null ? clamp(diskUsed / diskTotal) : null;
    const diskPercent = diskRatio === null ? '—' : `${Math.round(diskRatio * 100)}%`;
    ring('disk', diskRatio, diskPercent, pressure(diskRatio ?? 0), `Disk used ${diskPercent}, ${amount(diskFree)} GB free`);
    $('disk-value').textContent = amount(diskFree);

    const hasBattery = data.battery != null && typeof data.battery === 'object';
    $('battery-tile').hidden = !hasBattery;
    $('uptime-tile').hidden = hasBattery;
    $('uptime-value').textContent = uptime(data.uptime);
    if (hasBattery) {
      const battery = data.battery;
      const percent = number(battery.percent);
      const ratio = percent === null ? null : clamp(percent / 100);
      const label = ratio === null ? '—' : `${Math.round(ratio * 100)}%`;
      const tone = battery.charging ? 'good' : ratio !== null && ratio < .2 ? 'bad' : ratio !== null && ratio < .4 ? 'accent' : 'good';
      ring('battery', ratio, label, tone, `Battery ${label}${battery.charging ? ', charging' : ''}`);
      $('battery-value').textContent = label;
      $('charging-icon').toggleAttribute('hidden', !battery.charging);
      $('battery-detail').textContent = battery.charging ? 'Charging' : battery.onAC ? 'On power' : number(battery.minutesLeft) !== null && battery.minutesLeft >= 0 ? `${uptime(battery.minutesLeft * 60)} left` : 'On battery';
    }

    for (const [key, property, element, tone] of [['down', 'downBps', 'download', 'good'], ['up', 'upBps', 'upload', 'accent']]) {
      const value = number(data.network?.[property]);
      $(`${element}-value`).textContent = speed(value);
      if (value !== null) {
        samples[key].push(Math.max(0, value));
        if (samples[key].length > 40) samples[key].shift();
      }
      drawChart(`${element}-chart`, samples[key], tone);
    }
    $('load-value').textContent = [0, 1, 2].map(index => number(data.load?.[index]) === null ? '—' : data.load[index].toFixed(2)).join(' · ');
    $('load-value').title = 'Load average over 1, 5, and 15 minutes';
    const thermal = ['nominal', 'fair', 'serious', 'critical'].includes(data.thermal) ? data.thermal : 'unknown';
    $('thermal-pill').dataset.state = thermal;
    $('thermal-value').textContent = thermal === 'nominal' ? 'Nominal' : thermal[0].toUpperCase() + thermal.slice(1);
    $('thermal-pill').title = `Thermal state: ${thermal}`;
  }

  async function pollSystem() {
    if (systemBusy || stopped) return;
    systemBusy = true;
    try {
      if (!window.nook?.system) throw new Error('Bridge unavailable');
      const data = await window.nook.system();
      renderSystem(data);
      $('system-error').hidden = true;
      $('system-error').closest('.network').classList.remove('has-error');
      $('live-label').classList.remove('stale');
      $('live-label').lastChild.textContent = ' Live';
    } catch (_) {
      $('system-error').querySelector('span').textContent = 'Can’t read system stats. Retrying…';
      $('system-error').hidden = false;
      $('system-error').closest('.network').classList.add('has-error');
      $('live-label').classList.add('stale');
      $('live-label').lastChild.textContent = ' Paused';
    } finally {
      systemBusy = false;
    }
  }

  function parseProcesses(stdout) {
    if (typeof stdout !== 'string') return [];
    return stdout.split(/\r?\n/).flatMap(line => {
      const match = line.trim().match(/^(\d+(?:[.,]\d+)?)\s+(\d+)\s+(.+)$/);
      if (!match) return [];
      const cpu = Number(match[1].replace(',', '.'));
      const rss = Number(match[2]);
      const command = match[3].trim();
      if (!Number.isFinite(cpu) || !Number.isFinite(rss) || !command) return [];
      return [{ cpu, rss, command, name: command.split('/').filter(Boolean).pop() || command }];
    }).sort((a, b) => b.cpu - a.cpu).slice(0, 5);
  }

  async function pollProcesses() {
    if (processesBusy || stopped) return;
    processesBusy = true;
    try {
      if (!window.nook?.shell) throw new Error('Bridge unavailable');
      const result = await window.nook.shell('ps -Arco pcpu,rss,comm | head -6', { timeout: 2.5 });
      if (!result || result.code !== 0) throw new Error('Process list unavailable');
      const processes = parseProcesses(result.stdout);
      const rows = processes.map(process => {
        const row = document.createElement('div');
        row.className = 'process-row';
        const name = document.createElement('span');
        name.className = 'process-name';
        name.textContent = process.name;
        name.title = process.command;
        const cpu = document.createElement('span');
        cpu.className = 'process-cpu';
        cpu.textContent = `${process.cpu.toFixed(1)}%`;
        const memory = document.createElement('span');
        memory.className = 'process-memory';
        memory.textContent = process.rss >= 1024 ** 2 ? `${(process.rss / 1024 ** 2).toFixed(1)} GB` : `${Math.round(process.rss / 1024)} MB`;
        row.append(name, cpu, memory);
        return row;
      });
      $('process-list').replaceChildren(...rows);
      $('process-list').hidden = !rows.length;
      $('process-notice').hidden = !!rows.length;
      $('process-notice').textContent = 'No process data yet. Trying again shortly…';
    } catch (_) {
      $('process-list').hidden = true;
      $('process-notice').hidden = false;
      $('process-notice').textContent = 'Can’t read processes. Trying again shortly…';
    } finally {
      processesBusy = false;
    }
  }

  void pollSystem();
  void pollProcesses();
  const systemTimer = setInterval(() => { void pollSystem(); }, 1500);
  const processTimer = setInterval(() => { void pollProcesses(); }, 3000);
  window.addEventListener('resize', () => {
    drawChart('download-chart', samples.down, 'good');
    drawChart('upload-chart', samples.up, 'accent');
  });
  window.addEventListener('pagehide', () => {
    stopped = true;
    clearInterval(systemTimer);
    clearInterval(processTimer);
  }, { once: true });
})();
