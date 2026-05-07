// DNS Homelab Status Dashboard
// Lightweight, no dependencies. Renders metrics + SVG sparklines.

(function () {
    'use strict';

    function $(id) { return document.getElementById(id); }

    function fmtBytes(kb) {
        if (kb > 1024 * 1024) return (kb / 1024 / 1024).toFixed(1) + ' GB';
        if (kb > 1024) return (kb / 1024).toFixed(0) + ' MB';
        return kb + ' KB';
    }

    function fmtNum(n) {
        if (n >= 1000000) return (n / 1000000).toFixed(1) + 'M';
        if (n >= 1000) return (n / 1000).toFixed(1) + 'k';
        return String(n);
    }

    function pctColor(pct) {
        if (pct < 70) return 'var(--green)';
        if (pct < 85) return 'var(--orange)';
        return 'var(--red)';
    }

    function pctClass(pct) {
        if (pct < 70) return 'badge-ok';
        if (pct < 85) return 'badge-warn';
        return 'badge-error';
    }

    function badge(text, type) {
        return '<span class="badge ' + type + '">' + text + '</span>';
    }

    function containerBadge(status, health) {
        if (status === 'running' && (health === 'healthy' || health === 'none')) {
            return badge('running ✓', 'badge-ok');
        }
        if (status === 'running' && health === 'starting') return badge('starting…', 'badge-warn');
        if (status === 'running' && health === 'unhealthy') return badge('unhealthy', 'badge-error');
        if (status === 'not found') return badge('nicht gefunden', 'badge-error');
        return badge(status || '?', 'badge-warn');
    }

    function dnsBadge(ok) {
        return ok ? badge('OK ✓', 'badge-ok') : badge('FEHLER ✗', 'badge-error');
    }

    function relTime(iso) {
        if (!iso) return '–';
        var d = new Date(iso);
        if (isNaN(d)) return iso;
        var diffSec = (Date.now() - d) / 1000;
        if (diffSec < 60)    return 'gerade eben';
        if (diffSec < 3600)  return Math.floor(diffSec / 60) + ' min her';
        if (diffSec < 86400) return Math.floor(diffSec / 3600) + ' h her';
        return Math.floor(diffSec / 86400) + ' Tage her';
    }

    /**
     * Renders an SVG sparkline into a parent element.
     * @param {HTMLElement} parent
     * @param {Array<number>} values
     * @param {Object} opts {color, max, fill}
     */
    function sparkline(parent, values, opts) {
        opts = opts || {};
        var w = 120, h = 32, pad = 2;
        if (!values || values.length < 2) {
            parent.innerHTML = '<span style="color:var(--text-muted);font-size:0.78rem">keine Historie</span>';
            return;
        }
        var max = opts.max != null ? opts.max : Math.max.apply(null, values);
        var min = Math.min.apply(null, values);
        if (max === min) max = min + 1;
        var color = opts.color || '#5bc0eb';
        var fill = opts.fill !== false;

        var pts = values.map(function (v, i) {
            var x = pad + (i * (w - 2 * pad)) / (values.length - 1);
            var y = h - pad - ((v - min) / (max - min)) * (h - 2 * pad);
            return x.toFixed(1) + ',' + y.toFixed(1);
        });
        var poly = pts.join(' ');
        var area = '';
        if (fill) {
            area = '<polygon points="' + pad + ',' + (h - pad) + ' ' + poly + ' ' + (w - pad) + ',' + (h - pad)
                + '" fill="' + color + '" fill-opacity="0.18"/>';
        }
        parent.innerHTML =
            '<svg viewBox="0 0 ' + w + ' ' + h + '" width="100%" height="' + h + '" preserveAspectRatio="none">'
            + area
            + '<polyline points="' + poly + '" fill="none" stroke="' + color + '" stroke-width="1.5" '
            + 'stroke-linejoin="round" stroke-linecap="round"/>'
            + '</svg>';
    }

    function ensureSparkContainer(parentEl, id) {
        var existing = $(id);
        if (existing) return existing;
        var div = document.createElement('div');
        div.id = id;
        div.style.marginTop = '0.5rem';
        parentEl.appendChild(div);
        return div;
    }

    // ── Main rendering ──

    function render(d, history) {
        // VM Overview
        $('brand-host').textContent = d.hostname || '–';
        $('v-hostname').textContent = d.hostname || '–';
        $('v-ip').textContent = d.ip || '–';
        $('admin-link').href = 'http://' + (d.ip || location.hostname) + '/admin';
        $('v-os').textContent = d.os || '–';
        $('v-kernel').textContent = 'Kernel ' + (d.kernel || '–');
        $('v-uptime').textContent = d.uptime || '–';
        $('v-cores').textContent = d.cpu_cores || '–';
        $('v-load').textContent = d.load || '–';
        $('generated-at').textContent = d.generated_at || '–';

        if (d.role === 'master') {
            $('v-role').innerHTML = badge('Master (Schreib-Instanz)', 'badge-error');
        } else if (d.role === 'follower') {
            $('v-role').innerHTML = badge('Follower (Read-Only)', 'badge-ok');
        } else {
            $('v-role').textContent = '–';
        }

        // Memory
        var mem = d.memory || {};
        $('m-mem-pct').textContent = (mem.percent || 0) + '%';
        $('m-mem-pct').style.color = pctColor(mem.percent || 0);
        $('m-mem-sub').textContent = fmtBytes(mem.used_kb) + ' / ' + fmtBytes(mem.total_kb);
        var memBar = $('m-mem-bar');
        memBar.style.width = (mem.percent || 0) + '%';
        memBar.style.background = pctColor(mem.percent || 0);

        // Disk
        var disk = d.disk || {};
        $('m-disk-pct').textContent = (disk.percent || 0) + '%';
        $('m-disk-pct').style.color = pctColor(disk.percent || 0);
        $('m-disk-sub').textContent = fmtBytes(disk.used_kb) + ' / ' + fmtBytes(disk.total_kb);
        var diskBar = $('m-disk-bar');
        diskBar.style.width = (disk.percent || 0) + '%';
        diskBar.style.background = pctColor(disk.percent || 0);

        // Containers
        var c = d.containers || {};
        var ph = c.pihole || {};
        $('c-pihole-status').innerHTML = containerBadge(ph.status, ph.health);
        $('c-pihole-image').textContent = ph.image || '–';
        $('c-pihole-restarts').textContent = ph.restarts != null ? ph.restarts : '–';
        $('c-pihole-started').textContent = ph.started_at ? relTime(ph.started_at) : '–';

        var rc = c.recovery_site || {};
        $('c-recovery-status').innerHTML = containerBadge(rc.status, 'none');
        $('c-recovery-image').textContent = rc.image || '–';
        $('c-recovery-restarts').textContent = rc.restarts != null ? rc.restarts : '–';

        // DNS
        var dns = d.dns || {};
        $('dns-local').innerHTML = dnsBadge(dns.local_ok);
        $('dns-local-sub').textContent = dns.local_ms ? dns.local_ms + 'ms · @127.0.0.1' : '@127.0.0.1';
        $('dns-cf').innerHTML = dnsBadge(dns.upstream_cloudflare);
        $('dns-q9').innerHTML = dnsBadge(dns.upstream_quad9);

        // Pi-hole stats
        var p = d.pihole || {};
        $('p-queries').textContent = fmtNum(p.queries_total || 0);
        $('p-blocked').textContent = fmtNum(p.queries_blocked || 0);
        var pct = (p.block_percent || 0);
        $('p-blocked-pct').textContent = (typeof pct === 'number' ? pct.toFixed(1) : pct) + '% Blockrate';
        $('p-domains').textContent = fmtNum(p.domains_blocked || 0);
        $('p-gravity').textContent = p.gravity_last_updated || '–';

        // Sync
        var s = d.sync || {};
        $('s-last').textContent = s.last_sync ? (s.last_sync + (s.last_sync_hash ? '  (' + s.last_sync_hash + ')' : '')) : '–';
        $('s-branch').textContent = s.git_branch || '–';
        $('s-head').textContent = s.git_head || '–';

        // Recent log
        $('recent-log').textContent = (d.recent_log || '').trim() || '(keine Eintraege)';

        // ── Sparklines ──
        if (history && history.length >= 2) {
            renderSparklines(history);
        }
    }

    function renderSparklines(history) {
        var memCard  = $('m-mem-bar').parentElement;
        var diskCard = $('m-disk-bar').parentElement;
        var queriesCard = $('p-queries').parentElement;
        var blockedCard = $('p-blocked').parentElement;
        var loadCard = $('v-load').parentElement.parentElement;

        var memSpark    = ensureSparkContainer(memCard,    'spark-mem');
        var diskSpark   = ensureSparkContainer(diskCard,   'spark-disk');
        var qSpark      = ensureSparkContainer(queriesCard,'spark-queries');
        var bSpark      = ensureSparkContainer(blockedCard,'spark-blocked');
        var loadSpark   = ensureSparkContainer(loadCard,   'spark-load');

        sparkline(memSpark,  history.map(function(h){ return h.mem;     }), { color: '#5bc0eb', max: 100 });
        sparkline(diskSpark, history.map(function(h){ return h.disk;    }), { color: '#9c88ff', max: 100 });
        sparkline(qSpark,    history.map(function(h){ return h.queries; }), { color: '#4caf50' });
        sparkline(bSpark,    history.map(function(h){ return h.blocked; }), { color: '#f44336' });
        sparkline(loadSpark, history.map(function(h){ return h.load;    }), { color: '#ff9800' });
    }

    function loadStatus() {
        var statusP = fetch('/system-status.json?_=' + Date.now()).then(function (r) { return r.json(); });
        var historyP = fetch('/metrics-history.json?_=' + Date.now())
            .then(function (r) { return r.ok ? r.json() : []; })
            .catch(function () { return []; });

        Promise.all([statusP, historyP])
            .then(function (results) {
                render(results[0], results[1]);
            })
            .catch(function (e) {
                $('v-hostname').textContent = location.hostname;
                $('v-role').innerHTML = badge('system-status.json fehlt — bootstrap.sh ausfuehren', 'badge-warn');
                console.error(e);
            });
    }

    loadStatus();
    setInterval(loadStatus, 30000);
})();
