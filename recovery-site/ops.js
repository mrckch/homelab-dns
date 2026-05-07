// Operations page: wires up action buttons to the homelab-api.

(function () {
    'use strict';

    var output = document.getElementById('output');
    var outputStatus = document.getElementById('output-status');
    var clearBtn = document.getElementById('output-clear');

    function setStatus(text, cls) {
        outputStatus.textContent = text;
        outputStatus.className = '';
        if (cls) outputStatus.classList.add(cls);
    }

    function logOutput(text) {
        output.textContent = text;
        output.scrollTop = output.scrollHeight;
    }

    function appendOutput(text) {
        if (output.textContent === '— noch keine Aktion ausgefuehrt —') {
            output.textContent = '';
        }
        output.textContent += text;
        output.scrollTop = output.scrollHeight;
    }

    function fmtResult(result) {
        var lines = [];
        lines.push('▶ ' + (result.label || result.action || 'Aktion'));
        lines.push('  Exit-Code: ' + result.code);
        if (result.stdout) {
            lines.push('— stdout —');
            lines.push(result.stdout.trimEnd());
        }
        if (result.stderr) {
            lines.push('— stderr —');
            lines.push(result.stderr.trimEnd());
        }
        return lines.join('\n');
    }

    function runAction(action, button) {
        var confirmMsg = button.getAttribute('data-confirm');
        if (confirmMsg && !confirm(confirmMsg)) return;

        // Disable all buttons during execution
        var allButtons = document.querySelectorAll('button[data-action]');
        allButtons.forEach(function (b) { b.disabled = true; });
        button.classList.add('btn-running');

        var startTs = Date.now();
        setStatus('▶ Laufend: ' + action, 'status-running');
        appendOutput('\n\n[' + new Date().toLocaleTimeString() + '] Starte: ' + action + '\n');

        api.runAction(action)
            .then(function (result) {
                var elapsed = ((Date.now() - startTs) / 1000).toFixed(1) + 's';
                appendOutput(fmtResult(result) + '\n[fertig nach ' + elapsed + ']\n');
                if (result.ok) {
                    setStatus('✓ ' + action + ' erfolgreich (' + elapsed + ')', 'status-ok');
                } else {
                    setStatus('✗ ' + action + ' fehlgeschlagen (Code ' + result.code + ')', 'status-error');
                }
            })
            .catch(function (err) {
                appendOutput('FEHLER: ' + err.message + '\n');
                if (err.status === 401) {
                    setStatus('✗ Authentifizierung erforderlich', 'status-error');
                } else {
                    setStatus('✗ ' + action + ' fehlgeschlagen', 'status-error');
                }
            })
            .finally(function () {
                allButtons.forEach(function (b) { b.disabled = false; });
                button.classList.remove('btn-running');
            });
    }

    document.querySelectorAll('button[data-action]').forEach(function (btn) {
        btn.addEventListener('click', function () {
            runAction(btn.getAttribute('data-action'), btn);
        });
    });

    clearBtn.addEventListener('click', function () {
        logOutput('— Output geleert —');
        setStatus('Bereit');
    });

    // Initial: hostname for branding + sync description
    fetch('/system-status.json?_=' + Date.now())
        .then(function (r) { return r.json(); })
        .then(function (d) {
            document.getElementById('brand-host').textContent = d.hostname || '–';
            var sd = document.getElementById('sync-desc');
            if (d.role === 'master') {
                sd.textContent = 'Master: Pi-hole-Konfig exportieren und nach GitHub pushen.';
            } else if (d.role === 'follower') {
                sd.textContent = 'Follower: Letztes Backup von GitHub holen und in Pi-hole importieren.';
            }
        })
        .catch(function () {});
})();
