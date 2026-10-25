.pragma library

/*
 * Release Monitor - source checkers.
 * Every checker calls cb(err, result) where result is:
 *   { id, version, time (ms epoch or null), link, artifacts: [{name, url, size}] }
 */

function detectType(url) {
    var u = String(url).toLowerCase();
    if (/^https?:\/\/(www\.)?github\.com\/[^\/]+\/[^\/?#]+/.test(u)) return "github";
    if (/^https?:\/\/(www\.)?f-droid\.org\/.*packages\/[^\/?#]+/.test(u)) return "fdroid";
    if (/^https?:\/\/packages\.debian\.org\//.test(u)) return "debian";
    return "directory";
}

function typeLabel(type) {
    switch (type) {
    case "github": return "GitHub";
    case "fdroid": return "F-Droid";
    case "debian": return "Debian";
    default: return "Directory";
    }
}

function defaultName(url) {
    var m;
    switch (detectType(url)) {
    case "github":
        m = /github\.com\/([^\/]+)\/([^\/?#]+)/i.exec(url);
        return m[1] + "/" + m[2];
    case "fdroid":
        m = /packages\/([^\/?#]+)/i.exec(url);
        return m[1];
    case "debian":
        m = /packages\.debian\.org\/(?:[a-z]{2}(?:-[a-z]+)?\/)?([^\/?#]+)\/([^\/?#]+)/i.exec(url);
        return m ? m[2] : url;
    default:
        m = /\/\/([^\/]+)(\/.*)?$/.exec(url);
        if (!m) return url;
        var parts = (m[2] || "").split("/").filter(function (s) { return s; });
        return parts.length ? parts[parts.length - 1] : m[1];
    }
}

function request(method, url, headers, cb) {
    var xhr = new XMLHttpRequest();
    xhr.onreadystatechange = function () {
        if (xhr.readyState !== 4) return;
        if (xhr.status >= 200 && xhr.status < 300) cb(null, xhr.responseText, xhr);
        else if (xhr.status === 0) cb("Network error", null, xhr);
        else cb("HTTP " + xhr.status, null, xhr);
    };
    xhr.open(method, url);
    xhr.timeout = 30000;
    for (var k in headers) xhr.setRequestHeader(k, headers[k]);
    xhr.send();
}

function filterArtifacts(arts, re) {
    if (!re) return arts;
    return arts.filter(function (a) { return re.test(a.name); });
}

function natCmp(a, b) {
    var ax = String(a).split(/(\d+)/), bx = String(b).split(/(\d+)/);
    for (var i = 0; i < Math.max(ax.length, bx.length); i++) {
        if (ax[i] === undefined) return -1;
        if (bx[i] === undefined) return 1;
        if (i % 2 === 1) {
            var d = parseInt(ax[i], 10) - parseInt(bx[i], 10);
            if (d) return d;
        } else if (ax[i] !== bx[i]) {
            return ax[i] < bx[i] ? -1 : 1;
        }
    }
    return 0;
}

// ---------------------------------------------------------------- GitHub
function checkGithub(item, opts, re, cb) {
    var m = /github\.com\/([^\/]+)\/([^\/?#]+)/i.exec(item.url);
    var repo = m[2].replace(/\.git$/, "");
    var api = "https://api.github.com/repos/" + m[1] + "/" + repo + "/releases?per_page=15";
    var headers = { "Accept": "application/vnd.github+json", "X-GitHub-Api-Version": "2022-11-28" };
    if (opts.githubToken) headers["Authorization"] = "Bearer " + opts.githubToken;

    request("GET", api, headers, function (err, text, xhr) {
        if (err) {
            if (xhr && (xhr.status === 403 || xhr.status === 429))
                err += " (GitHub API rate limit? Set a token in the settings)";
            cb(err);
            return;
        }
        var list;
        try { list = JSON.parse(text); } catch (e) { cb("Bad JSON from GitHub API"); return; }
        list = list.filter(function (r) { return !r.draft; });
        if (!list.length) { cb("No releases found"); return; }
        var rel = list.filter(function (r) { return !r.prerelease; })[0] || list[0];
        var arts = (rel.assets || []).map(function (a) {
            return { name: a.name, url: a.browser_download_url, size: a.size };
        });
        var t = Date.parse(rel.published_at || rel.created_at);
        cb(null, {
            id: String(rel.id),
            version: rel.tag_name || rel.name,
            time: isNaN(t) ? null : t,
            link: rel.html_url,
            artifacts: filterArtifacts(arts, re)
        });
    });
}

// ---------------------------------------------------------------- F-Droid
function checkFdroid(item, opts, re, cb) {
    var m = /packages\/([^\/?#]+)/i.exec(item.url);
    var pkg = m[1];
    request("GET", "https://f-droid.org/api/v1/packages/" + pkg, { "Accept": "application/json" }, function (err, text) {
        if (err) { cb(err); return; }
        var j;
        try { j = JSON.parse(text); } catch (e) { cb("Bad JSON from F-Droid API"); return; }
        var list = j.packages || [];
        if (!list.length) { cb("No versions found"); return; }
        var cur = list.filter(function (p) { return p.versionCode === j.suggestedVersionCode; })[0] || list[0];
        var fname = pkg + "_" + cur.versionCode + ".apk";
        var result = {
            id: String(cur.versionCode),
            version: cur.versionName + " (" + cur.versionCode + ")",
            time: null,
            link: item.url,
            artifacts: filterArtifacts([{ name: fname, url: "https://f-droid.org/repo/" + fname }], re)
        };
        // Best effort: the "Added on <date>" text on the package page
        request("GET", item.url, {}, function (err2, html) {
            if (!err2 && html) {
                var dm = new RegExp(cur.versionCode + "[\\s\\S]{0,1500}?Added on\\s*([^<\\n]+)").exec(html);
                if (dm) {
                    var t = Date.parse(dm[1].trim());
                    if (!isNaN(t)) result.time = t;
                }
            }
            cb(null, result);
        });
    });
}

// ---------------------------------------------------------------- Debian
function debUrl(href) {
    var m = /\/debian-security\/(pool\/.+\.deb)$/.exec(href);
    if (m) return "https://security.debian.org/debian-security/" + m[1];
    m = /\/debian\/(pool\/.+\.deb)$/.exec(href);
    if (m) return "https://deb.debian.org/debian/" + m[1];
    return href;
}

function fetchDebs(suite, pkg, archs, cb) {
    if (!archs.length) { cb([]); return; }
    var arch = archs[0];
    var url = "https://packages.debian.org/" + suite + "/" + arch + "/" + pkg + "/download";
    request("GET", url, {}, function (err, html) {
        if (err || !html) { fetchDebs(suite, pkg, archs.slice(1), cb); return; }
        var re = /href="([^"]+\.deb)"/g, m, seen = {}, out = [];
        while ((m = re.exec(html)) !== null) {
            var u = debUrl(m[1]);
            var name = decodeURIComponent(u.substring(u.lastIndexOf("/") + 1));
            if (seen[name]) continue;
            seen[name] = true;
            out.push({ name: name, url: u });
            break; // first mirror link is enough, they all point to the same file
        }
        if (out.length) cb(out);
        else fetchDebs(suite, pkg, archs.slice(1), cb);
    });
}

function checkDebian(item, opts, re, cb) {
    var m = /packages\.debian\.org\/(?:[a-z]{2}(?:-[a-z]+)?\/)?([^\/?#]+)\/([^\/?#]+)/i.exec(item.url);
    if (!m) { cb("Cannot parse Debian package URL (expected packages.debian.org/SUITE/PACKAGE)"); return; }
    var suite = m[1], pkg = m[2];
    request("GET", item.url, {}, function (err, html) {
        if (err) { cb(err); return; }
        var vm = /<h1>\s*Package:\s*[^\s<]+\s*\(([^\s)<]+)/i.exec(html);
        if (!vm) { cb("Could not find the version on the Debian package page"); return; }
        var version = vm[1];
        var arch = opts.debianArch || "amd64";
        fetchDebs(suite, pkg, arch === "all" ? ["all"] : [arch, "all"], function (arts) {
            arts = filterArtifacts(arts, re);
            var result = { id: version, version: version, time: null, link: item.url, artifacts: arts };
            if (!arts.length) { cb(null, result); return; }
            // Best effort: use Last-Modified of the .deb on the mirror as release time
            request("HEAD", arts[0].url, {}, function (e2, t2, xhr) {
                if (!e2 && xhr) {
                    var lm = xhr.getResponseHeader("Last-Modified");
                    var t = lm ? Date.parse(lm) : NaN;
                    if (!isNaN(t)) result.time = t;
                    var len = parseInt(xhr.getResponseHeader("Content-Length"), 10);
                    if (len > 0) arts[0].size = len;
                }
                cb(null, result);
            });
        });
    });
}

// ---------------------------------------------------------------- Directory listing
function parseDate(s) {
    var d = /(\d{4}-\d{2}-\d{2})[ T](\d{2}:\d{2})(?::(\d{2}))?/.exec(s), t;
    if (d) {
        t = Date.parse(d[1] + "T" + d[2] + ":" + (d[3] || "00") + "Z");
        return isNaN(t) ? null : t;
    }
    d = /(\d{1,2})-([A-Za-z]{3})-(\d{4})\s+(\d{2}:\d{2})/.exec(s);
    if (d) {
        t = Date.parse(d[1] + " " + d[2] + " " + d[3] + " " + d[4] + " UTC");
        return isNaN(t) ? null : t;
    }
    d = /(\d{4}-\d{2}-\d{2})/.exec(s);
    if (d) {
        t = Date.parse(d[1] + "T00:00:00Z");
        return isNaN(t) ? null : t;
    }
    return null;
}

function parseSize(s) {
    var m = /(?:^|\s)(\d+(?:\.\d+)?)\s*([KMGT])?(?=\s|$)/i.exec(s.replace(/\d{4}-\d{2}-\d{2}[ T]\d{2}:\d{2}(?::\d{2})?/, "")
                                                               .replace(/\d{1,2}-[A-Za-z]{3}-\d{4}\s+\d{2}:\d{2}/, ""));
    if (!m) return 0;
    var n = parseFloat(m[1]);
    var mult = { K: 1024, M: 1048576, G: 1073741824, T: 1099511627776 }[(m[2] || "").toUpperCase()] || 1;
    return Math.round(n * mult);
}

function parseListing(html, base) {
    var re = /<a\s+[^>]*?href\s*=\s*(["'])(.*?)\1[^>]*>([\s\S]*?)<\/a>/gi, m, out = [];
    while ((m = re.exec(html)) !== null) {
        var href = m[2];
        if (!href || href[0] === "?" || href[0] === "#" || href[0] === "/" ||
            href.indexOf("../") === 0 || href === "./" || /^(mailto|javascript):/i.test(href))
            continue;
        if (/^[a-z]+:\/\//i.test(href)) {
            if (href.indexOf(base) !== 0) continue;
            href = href.substring(base.length);
            if (!href) continue;
        }
        if (/parent directory/i.test(m[3])) continue;

        var tail = html.substr(re.lastIndex, 200);
        var na = tail.search(/<a\s/i);
        if (na >= 0) tail = tail.substr(0, na);
        tail = tail.replace(/<[^>]+>/g, " ");

        var isDir = href.charAt(href.length - 1) === "/";
        var rel = href.replace(/\/$/, "");
        var name;
        try { name = decodeURIComponent(rel); } catch (e) { name = rel; }
        out.push({ name: name, href: href, isDir: isDir, time: parseDate(tail), size: isDir ? 0 : parseSize(tail) });
    }
    return out;
}

function checkDirectory(item, opts, re, cb) {
    var base = item.url.replace(/[?#].*$/, "");
    if (base.charAt(base.length - 1) !== "/") base += "/";
    request("GET", base, {}, function (err, html) {
        if (err) { cb(err); return; }
        var entries = parseListing(html, base).filter(function (e) { return !re || re.test(e.name); });
        if (!entries.length) { cb("No matching entries found in the listing"); return; }
        entries.sort(function (a, b) {
            if (a.time && b.time && a.time !== b.time) return b.time - a.time;
            if (!!a.time !== !!b.time) return a.time ? -1 : 1;
            return natCmp(b.name, a.name);
        });
        var latest = entries[0];
        var arts = entries.filter(function (e) { return !e.isDir; }).slice(0, 30).map(function (e) {
            return { name: e.name, url: /^[a-z]+:\/\//i.test(e.href) ? e.href : base + e.href, size: e.size };
        });
        cb(null, {
            id: latest.name + "|" + (latest.time || ""),
            version: latest.name + (latest.isDir ? "/" : ""),
            time: latest.time,
            link: base,
            artifacts: arts
        });
    });
}

// ---------------------------------------------------------------- entry point
function check(item, opts, cb) {
    var re = null;
    if (item.filter) {
        try { re = new RegExp(item.filter, "i"); }
        catch (e) { cb("Invalid filter regex: " + e.message); return; }
    }
    try {
        switch (detectType(item.url)) {
        case "github": checkGithub(item, opts, re, cb); break;
        case "fdroid": checkFdroid(item, opts, re, cb); break;
        case "debian": checkDebian(item, opts, re, cb); break;
        default: checkDirectory(item, opts, re, cb);
        }
    } catch (e) {
        cb(String(e));
    }
}
