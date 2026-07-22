// SPDX-License-Identifier: AGPL-3.0-or-later
//
//  CeremonyJS.swift
//  iotest
//
//  The injected JavaScript for the 1.7 ceremony. Two scripts:
//
//    loginJS      — step 1+2: mfaLoginBegin → navigator.credentials.get
//                   (Face ID) → mfaLoginFinishSession. Stores the result in
//                   window.__iotestLoginResult + flips window.__iotestLoginDone.
//
//    privilegeJS  — step 3+4: mfa/authenticatechallenge (admin-action scope)
//                   → navigator.credentials.get (Face ID #2) → privilege/token.
//                   Stores the result in window.__iotestPrivilegeResult +
//                   flips window.__iotestPrivilegeDone.
//
//  Endpoint + field names mirror the Teleport web UI exactly:
//    - POST /v1/webapi/mfa/login/begin  {"passwordless": true}
//    - POST /v1/webapi/mfa/login/finishsession  {"webauthnAssertionResponse": {...}}
//    - POST /v1/webapi/mfa/authenticatechallenge  {"challenge_scope": "ADMIN_ACTION", ...}
//    - POST /v1/webapi/users/privilege/token  {"existingMfaResponse": {"webauthn_response": {...}}}
//
//  The assertion response is built with the same field names as the Teleport
//  web UI's makeWebauthnAssertionResponse() (see makeMfa.ts):
//    {id, type, rawId, response: {authenticatorData, clientDataJSON, signature,
//     userHandle}, extensions: {appid}}
//
//  All fetches are same-origin (the webview is on https://teleport.pcad.it),
//  so the __Host-session cookie is sent automatically once login succeeds.
//

import Foundation

/// The login ceremony JS. Does:
///   1. POST /v1/webapi/mfa/login/begin {"passwordless": true}
///   2. navigator.credentials.get({publicKey: challenge.webauthn_challenge.publicKey})
///      — this triggers the Face ID prompt (the webview's WebAuthn stack
///      invokes the platform authenticator).
///   3. Build the assertion response (makeWebauthnAssertionResponse shape).
///   4. POST /v1/webapi/mfa/login/finishsession {"webauthnAssertionResponse": ...}
///   5. Store {challengeLength, loginStatus, sessionToken, loginBody,
///      faceIDRejected} in window.__iotestLoginResult.
let loginJS: String = """
(function() {
    window.__iotestLoginResult = null;
    window.__iotestLoginDone = false;
    var result = {
        challengeLength: 0,
        loginStatus: 0,
        sessionToken: "",
        loginBody: "",
        faceIDRejected: ""
    };

    function base64url(buf) {
        var bytes = new Uint8Array(buf);
        var s = "";
        for (var i = 0; i < bytes.length; i++) s += String.fromCharCode(bytes[i]);
        return btoa(s).replace(/\\+/g, "-").replace(/\\//g, "_").replace(/=+$/, "");
    }

    function buildAssertionResponse(cred) {
        var pk = cred;
        var resp = pk.response;
        return {
            id: cred.id,
            type: cred.type,
            rawId: base64url(pk.rawId),
            response: {
                authenticatorData: base64url(resp.authenticatorData),
                clientDataJSON: base64url(resp.clientDataJSON),
                signature: base64url(resp.signature),
                userHandle: base64url(resp.userHandle)
            },
            extensions: { appid: false }
        };
    }

    function finish(err) {
        if (err) result.faceIDRejected = String(err);
        window.__iotestLoginResult = result;
        window.__iotestLoginDone = true;
    }

    fetch("/v1/webapi/mfa/login/begin", {
        method: "POST",
        headers: {"Content-Type": "application/json"},
        body: JSON.stringify({passwordless: true})
    }).then(function(r) {
        return r.json().then(function(j) { return {status: r.status, json: j}; });
    }).then(function(res) {
        var chal = res.json && res.json.webauthn_challenge;
        if (!chal || !chal.publicKey) {
            result.loginStatus = res.status;
            result.loginBody = JSON.stringify(res.json);
            finish("no webauthn_challenge in login/begin response");
            return;
        }
        // Convert base64url challenge → ArrayBuffer for navigator.credentials.get.
        var b64 = chal.publicKey.challenge.replace(/-/g, "+").replace(/_/g, "/");
        var pad = b64.length % 4;
        if (pad) b64 += "=" + "=".repeat(4 - pad);
        var bin = atob(b64);
        var bytes = new Uint8Array(bin.length);
        for (var i = 0; i < bin.length; i++) bytes[i] = bin.charCodeAt(i);
        chal.publicKey.challenge = bytes.buffer;
        // allowCredentials ids (if any) — also base64url → ArrayBuffer.
        if (chal.publicKey.allowCredentials) {
            chal.publicKey.allowCredentials = chal.publicKey.allowCredentials.map(function(c) {
                var b64c = c.id.replace(/-/g, "+").replace(/_/g, "/");
                var padc = b64c.length % 4;
                if (padc) b64c += "=" + "=".repeat(4 - padc);
                var binc = atob(b64c);
                var bytesc = new Uint8Array(binc.length);
                for (var j = 0; j < binc.length; j++) bytesc[j] = binc.charCodeAt(j);
                return {type: c.type, id: bytesc.buffer, transports: c.transports};
            });
        }
        result.challengeLength = bytes.length;
        // ── This is the Face ID prompt. navigator.credentials.get invokes
        //    the platform authenticator (iCloud-Keychain passkey). If the
        //    webview's WebAuthn stack is wired up, a Face ID sheet appears.
        return navigator.credentials.get({publicKey: chal.publicKey});
    }).then(function(cred) {
        if (!cred) {
            finish("credentials.get returned null");
            return;
        }
        var assertion = buildAssertionResponse(cred);
        return fetch("/v1/webapi/mfa/login/finishsession", {
            method: "POST",
            headers: {"Content-Type": "application/json"},
            body: JSON.stringify({webauthnAssertionResponse: assertion})
        }).then(function(r) {
            return r.text().then(function(t) { return {status: r.status, text: t}; });
        });
    }).then(function(res) {
        if (!res) return;  // finish() already called
        result.loginStatus = res.status;
        result.loginBody = res.text;
        try {
            var j = JSON.parse(res.text);
            result.sessionToken = j.token || (j.session && j.session.token) || "";
        } catch (e) {
            result.sessionToken = "";
        }
        finish();
    }).catch(function(e) {
        finish(e && e.message ? e.message : String(e));
    });
})();
"""

/// The privilege-token ceremony JS. Does:
///   1. POST /v1/webapi/mfa/authenticatechallenge {"challenge_scope":"ADMIN_ACTION"}
///      — gets a fresh WebAuthn challenge (the web UI calls this before
///      privilege/token to get the MFA challenge).
///   2. navigator.credentials.get (Face ID #2).
///   3. POST /v1/webapi/users/privilege/token {"existingMfaResponse":{"webauthn_response":...}}
///   4. Store {challengeLength, privilegeStatus, privilegeToken, privilegeBody,
///      faceIDRejected} in window.__iotestPrivilegeResult.
let privilegeJS: String = """
(function() {
    window.__iotestPrivilegeResult = null;
    window.__iotestPrivilegeDone = false;
    var result = {
        challengeLength: 0,
        privilegeStatus: 0,
        privilegeToken: "",
        privilegeBody: "",
        faceIDRejected: ""
    };

    function base64url(buf) {
        var bytes = new Uint8Array(buf);
        var s = "";
        for (var i = 0; i < bytes.length; i++) s += String.fromCharCode(bytes[i]);
        return btoa(s).replace(/\\+/g, "-").replace(/\\//g, "_").replace(/=+$/, "");
    }

    function buildAssertionResponse(cred) {
        var pk = cred;
        var resp = pk.response;
        return {
            id: cred.id,
            type: cred.type,
            rawId: base64url(pk.rawId),
            response: {
                authenticatorData: base64url(resp.authenticatorData),
                clientDataJSON: base64url(resp.clientDataJSON),
                signature: base64url(resp.signature),
                userHandle: base64url(resp.userHandle)
            },
            extensions: { appid: false }
        };
    }

    function finish(err) {
        if (err) result.faceIDRejected = String(err);
        window.__iotestPrivilegeResult = result;
        window.__iotestPrivilegeDone = true;
    }

    fetch("/v1/webapi/mfa/authenticatechallenge", {
        method: "POST",
        headers: {"Content-Type": "application/json"},
        body: JSON.stringify({
            challenge_scope: "ADMIN_ACTION",
            challenge_allow_reuse: false
        })
    }).then(function(r) {
        return r.json().then(function(j) { return {status: r.status, json: j}; });
    }).then(function(res) {
        var chal = res.json && res.json.webauthn_challenge;
        if (!chal || !chal.publicKey) {
            result.privilegeStatus = res.status;
            result.privilegeBody = JSON.stringify(res.json);
            finish("no webauthn_challenge in authenticatechallenge response");
            return;
        }
        var b64 = chal.publicKey.challenge.replace(/-/g, "+").replace(/_/g, "/");
        var pad = b64.length % 4;
        if (pad) b64 += "=" + "=".repeat(4 - pad);
        var bin = atob(b64);
        var bytes = new Uint8Array(bin.length);
        for (var i = 0; i < bin.length; i++) bytes[i] = bin.charCodeAt(i);
        chal.publicKey.challenge = bytes.buffer;
        if (chal.publicKey.allowCredentials) {
            chal.publicKey.allowCredentials = chal.publicKey.allowCredentials.map(function(c) {
                var b64c = c.id.replace(/-/g, "+").replace(/_/g, "/");
                var padc = b64c.length % 4;
                if (padc) b64c += "=" + "=".repeat(4 - padc);
                var binc = atob(b64c);
                var bytesc = new Uint8Array(binc.length);
                for (var j = 0; j < binc.length; j++) bytesc[j] = binc.charCodeAt(j);
                return {type: c.type, id: bytesc.buffer, transports: c.transports};
            });
        }
        result.challengeLength = bytes.length;
        // ── Face ID prompt #2.
        return navigator.credentials.get({publicKey: chal.publicKey});
    }).then(function(cred) {
        if (!cred) {
            finish("credentials.get returned null");
            return;
        }
        var assertion = buildAssertionResponse(cred);
        return fetch("/v1/webapi/users/privilege/token", {
            method: "POST",
            headers: {"Content-Type": "application/json"},
            body: JSON.stringify({
                existingMfaResponse: { webauthn_response: assertion }
            })
        }).then(function(r) {
            return r.text().then(function(t) { return {status: r.status, text: t}; });
        });
    }).then(function(res) {
        if (!res) return;
        result.privilegeStatus = res.status;
        result.privilegeBody = res.text;
        // The privilege token is returned as a JSON string (not an object).
        // Teleport's createPrivilegeTokenHandle returns token.GetName() directly.
        try {
            var parsed = JSON.parse(res.text);
            if (typeof parsed === "string") {
                result.privilegeToken = parsed;
            } else if (parsed && typeof parsed.token === "string") {
                result.privilegeToken = parsed.token;
            } else {
                result.privilegeToken = "";
            }
        } catch (e) {
            // The response might be a bare JSON string (e.g. "abc123").
            if (res.status === 200 && res.text.length > 0 && res.text.length < 200) {
                result.privilegeToken = res.text.replace(/^"|"$/g, "");
            } else {
                result.privilegeToken = "";
            }
        }
        finish();
    }).catch(function(e) {
        finish(e && e.message ? e.message : String(e));
    });
})();
"""
