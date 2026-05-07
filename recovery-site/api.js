// Lightweight API helper for the homelab-api service.
// All POST endpoints require auth (Basic) when enabled.

(function (global) {
    'use strict';

    function apiRequest(method, path, body) {
        var opts = {
            method: method,
            credentials: 'include',
            headers: {}
        };
        if (body !== undefined) {
            opts.headers['Content-Type'] = 'application/json';
            opts.body = JSON.stringify(body);
        }
        return fetch(path, opts).then(function (r) {
            return r.text().then(function (t) {
                var data;
                try { data = t ? JSON.parse(t) : null; } catch (e) { data = { raw: t }; }
                if (!r.ok) {
                    var err = new Error(
                        (data && (data.detail || data.error)) || ('HTTP ' + r.status)
                    );
                    err.status = r.status;
                    err.data = data;
                    throw err;
                }
                return data;
            });
        });
    }

    global.api = {
        get:  function (p)    { return apiRequest('GET',  p); },
        post: function (p, b) { return apiRequest('POST', p, b); },
        runAction: function (name) {
            return apiRequest('POST', '/api/actions/' + encodeURIComponent(name));
        },
        authStatus: function () { return apiRequest('GET', '/api/auth/status'); },
        setPassword: function (current, newPw) {
            return apiRequest('POST', '/api/auth/set-password',
                { current: current, new: newPw });
        },
        disableAuth: function (current) {
            return apiRequest('POST', '/api/auth/disable', { current: current });
        }
    };
})(window);
