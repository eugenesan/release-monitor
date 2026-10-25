.pragma library

/*
 * Release Monitor - source checkers.
 * Every checker finishes by calling ctx.done(err, result) exactly once, where result is:
 *   { id, version, time (ms epoch or null), link, typeLabel (optional),
 *     artifacts: [{name, url, size, group?, kind?}] }
 * Any exception thrown inside an async callback is turned into an error message
 * (ctx.fail) so a check can never silently hang.
 */

var UA = "Mozilla/5.0 (X11; Linux x86_64; rv:140.0) Gecko/20100101 Firefox/140.0 ReleaseMonitor";

// File types treated as downloadable artifacts when scanning a normal web page
var ARTIFACT_RE = new RegExp("\\.(exe|msi|msix|zip|7z|rar|tar\\.(gz|xz|bz2|zst|lz)|tgz|txz|tbz2|deb|rpm|dmg|pkg|"
    + "appimage|apk|aab|iso|img|jar|whl|snap|flatpak|xpi|crx|run|bin|asc|sig|sha256|sha512|sha1|md5|sha256sum|sha512sum)$", "i");

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
    default: return "Web / directory";
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
        var parts = (m[2] || "").replace(/[?#].*$/, "").split("/").filter(function (s) { return s; });
        return parts.length ? parts[parts.length - 1] : m[1];
    }
}

// ---------------------------------------------------------------- helpers
function request(ctx, method, url, headers, cb) {
    var xhr = new XMLHttpRequest();
    xhr.onreadystatechange = function () {
        if (xhr.readyState !== 4) return;
        try {
            if (xhr.status >= 200 && xhr.status < 300) cb(null, xhr.responseText, xhr);
            else if (xhr.status === 0) cb("Network error", null, xhr);
            else cb("HTTP " + xhr.status, null, xhr);
        } catch (e) {
            ctx.fail("Internal error: " + e);
        }
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

// Date.parse() of the QML JavaScript engine is picky about non-ISO strings ("20 Oct 2026 08:34 UTC"
// may give NaN there), so non-ISO dates are computed with Date.UTC() instead.
var MONTHS = { jan: 0, feb: 1, mar: 2, apr: 3, may: 4, jun: 5, jul: 6, aug: 7, sep: 8, oct: 9, nov: 10, dec: 11 };

// "Tue, 20 Oct 2026 21:43:10 GMT", "20-Oct-2026 8:34", "20 Oct 2026 08:34" (always read as UTC)
function parseDayMonYear(str) {
    var m = /(\d{1,2})[ \-]([A-Za-z]{3})[a-z]*[ \-](\d{4})\s+(\d{1,2}):(\d{2})(?::(\d{2}))?/.exec(String(str || ""));
    if (!m || MONTHS[m[2].toLowerCase()] === undefined) return NaN;
    return Date.UTC(+m[3], MONTHS[m[2].toLowerCase()], +m[1], +m[4], +m[5], +(m[6] || 0));
}

// "Jul 24, 2025" (F-Droid "Added on")
function parseMonDayYear(str) {
    var m = /([A-Za-z]{3})[a-z]*\.?\s+(\d{1,2}),?\s+(\d{4})/.exec(String(str || ""));
    if (!m || MONTHS[m[1].toLowerCase()] === undefined) return NaN;
    return Date.UTC(+m[3], MONTHS[m[1].toLowerCase()], +m[2]);
}

function parseHttpDate(str) {
    var t = parseDayMonYear(str);
    return isNaN(t) ? Date.parse(str) : t;
}

function safeDecode(s) {
    try { return decodeURIComponent(s); } catch (e) { return s; }
}

function originOf(url) {
    var m = /^(https?:\/\/[^\/?#]+)/i.exec(url);
    return m ? m[1] : "";
}

// directory part of a URL, always ending with "/"
function dirOf(url) {
    var u = url.replace(/[?#].*$/, "");
    var origin = originOf(u);
    if (u.length <= origin.length) return origin + "/";
    return u.substring(0, u.lastIndexOf("/") + 1);
}

function normalizePath(url) {
    var m = /^(https?:\/\/[^\/?#]+)([^?#]*)(.*)$/i.exec(url);
    if (!m) return url;
    var out = [];
    m[2].split("/").forEach(function (seg, i, all) {
        if (seg === "..") { if (out.length > 1) out.pop(); }
        else if (seg !== "." && !(seg === "" && i > 0 && i < all.length - 1)) out.push(seg);
    });
    return m[1] + out.join("/") + m[3];
}

function resolveUrl(href, pageUrl) {
    href = href.replace(/&amp;/g, "&").trim();
    if (!href || href.charAt(0) === "#") return null;
    if (/^[a-z][a-z0-9+.\-]*:/i.test(href)) return /^https?:/i.test(href) ? href : null;
    if (href.indexOf("//") === 0) return pageUrl.replace(/\/\/.*$/, "") + href;
    if (href.charAt(0) === "/") return originOf(pageUrl) + href;
    return normalizePath(dirOf(pageUrl) + href);
}

function toName(url) {
    var path = url.replace(/[?#].*$/, "");
    return safeDecode(path.substring(path.lastIndexOf("/") + 1));
}

// ---------------------------------------------------------------- GitHub
// The "Source code (tar.gz / zip)" links of a release page. The URL is GitHub's archive link; the
// saved file is named <repo>-<tag>.<ext> (the name GitHub gives the download), so archives of
// different repositories or releases never collide.
function sourceArchives(owner, repo, tag) {
    if (!tag) return [];
    var path = tag.split("/").map(encodeURIComponent).join("/");
    return ["tar.gz", "zip"].map(function (ext) {
        return {
            name: repo + "-" + tag + "." + ext,
            url: "https://github.com/" + owner + "/" + repo + "/archive/refs/tags/" + path + "." + ext
        };
    });
}

function githubAtom(ctx, owner, repo, apiError) {
    var feed = "https://github.com/" + owner + "/" + repo + "/releases.atom";
    request(ctx, "GET", feed, {}, function (err, xml) {
        if (err) { ctx.done(apiError); return; }
        var em = /<entry>([\s\S]*?)<\/entry>/.exec(xml);
        if (!em) { ctx.done(apiError); return; }
        var link = /<link[^>]*href="([^"]+)"/.exec(em[1]);
        var tag = link ? safeDecode(link[1].substring(link[1].lastIndexOf("/") + 1)) : null;
        var upd = /<updated>([^<]+)<\/updated>/.exec(em[1]);
        var t = upd ? Date.parse(upd[1]) : NaN;
        if (!tag) { ctx.done(apiError); return; }
        ctx.done(null, {
            id: tag, version: tag, time: isNaN(t) ? null : t,
            link: link[1], typeLabel: "GitHub (feed)",
            artifacts: filterArtifacts(sourceArchives(owner, repo, tag), ctx.re)
        });
    });
}

function checkGithub(ctx) {
    var item = ctx.item, opts = ctx.opts;
    var m = /github\.com\/([^\/]+)\/([^\/?#]+)/i.exec(item.url);
    var owner = m[1], repo = m[2].replace(/\.git$/, "");
    var api = "https://api.github.com/repos/" + owner + "/" + repo + "/releases?per_page=15";
    var headers = { "Accept": "application/vnd.github+json", "X-GitHub-Api-Version": "2022-11-28" };
    if (opts.githubToken) headers["Authorization"] = "Bearer " + opts.githubToken;

    request(ctx, "GET", api, headers, function (err, text, xhr) {
        if (err) {
            var msg = err;
            if (xhr && (xhr.status === 403 || xhr.status === 429))
                msg += " (GitHub API rate limit? Set a token in the settings)";
            // The public Atom feed has no rate limit: at least report the newest release
            githubAtom(ctx, owner, repo, msg);
            return;
        }
        var list;
        try { list = JSON.parse(text); } catch (e) { githubAtom(ctx, owner, repo, "Bad JSON from GitHub API"); return; }
        if (!Array.isArray(list)) {
            githubAtom(ctx, owner, repo, "GitHub API: " + ((list && list.message) || "unexpected response"));
            return;
        }
        list = list.filter(function (r) { return r && !r.draft; });
        if (!list.length) { ctx.done("No releases found"); return; }
        var rel = list.filter(function (r) { return !r.prerelease; })[0] || list[0];
        var arts = (rel.assets || []).filter(function (a) { return a && a.browser_download_url; }).map(function (a) {
            return { name: a.name, url: a.browser_download_url, size: a.size };
        });
        var t = Date.parse(rel.published_at || rel.created_at);
        arts = arts.concat(sourceArchives(owner, repo, rel.tag_name));
        ctx.done(null, {
            id: String(rel.id || rel.tag_name),
            version: rel.tag_name || rel.name || String(rel.id),
            time: isNaN(t) ? null : t,
            link: rel.html_url || item.url,
            artifacts: filterArtifacts(arts, ctx.re)
        });
    });
}

// ---------------------------------------------------------------- F-Droid
function checkFdroid(ctx) {
    var item = ctx.item, re = ctx.re;
    var m = /packages\/([^\/?#]+)/i.exec(item.url);
    var pkg = m[1];
    request(ctx, "GET", "https://f-droid.org/api/v1/packages/" + pkg, { "Accept": "application/json" }, function (err, text) {
        if (err) { ctx.done(err); return; }
        var j;
        try { j = JSON.parse(text); } catch (e) { ctx.done("Bad JSON from F-Droid API"); return; }
        var list = j.packages || [];
        if (!list.length) { ctx.done("No versions found"); return; }
        var cur = list.filter(function (p) { return p.versionCode === j.suggestedVersionCode; })[0] || list[0];
        var vc = String(cur.versionCode);
        var base = "https://f-droid.org/repo/" + pkg + "_" + vc;
        var apk = { name: pkg + "_" + vc + ".apk", url: base + ".apk" };
        var result = {
            id: vc,
            version: cur.versionName + " (" + vc + ")",
            time: null,
            link: item.url,
            artifacts: []
        };

        function finish(buildArts) {
            result.artifacts = filterArtifacts([apk].concat(buildArts), re);
            ctx.done(null, result);
        }

        // The package page lists the files of a version (apk, signature, source, build log...)
        request(ctx, "GET", item.url, {}, function (err2, html) {
            var found = [], seen = {};
            seen[apk.name] = true;
            if (!err2 && html) {
                var dm = new RegExp(vc + "[\\s\\S]{0,1500}?Added on\\s*([^<\\n]+)").exec(html);
                if (dm) {
                    var t = parseMonDayYear(dm[1].trim());
                    if (isNaN(t)) t = Date.parse(dm[1].trim());
                    if (!isNaN(t)) result.time = t;
                }
                var hre = /href="([^"#][^"]*)"/g, hm;
                while ((hm = hre.exec(html)) !== null) {
                    var href = hm[1].replace(/&amp;/g, "&");
                    if (href.indexOf(vc) < 0) continue;
                    if (href.charAt(0) === "/") href = "https://f-droid.org" + href;
                    if (!/^https?:\/\/[^\/]*f-droid\.org\//i.test(href)) continue;
                    var fname = toName(href);
                    if (!fname || seen[fname]) continue;
                    seen[fname] = true;
                    found.push({ name: fname, url: href, group: "build" });
                }
            }
            if (!found.length) {
                found = [
                    { name: apk.name + ".asc", url: apk.url + ".asc", group: "build" },
                    { name: pkg + "_" + vc + "_src.tar.gz", url: base + "_src.tar.gz", group: "build" }
                ];
            }
            finish(found);
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

function fetchDebs(ctx, suite, pkg, archs, cb) {
    if (!archs.length) { cb([]); return; }
    var url = "https://packages.debian.org/" + suite + "/" + archs[0] + "/" + pkg + "/download";
    request(ctx, "GET", url, {}, function (err, html) {
        if (err || !html) { fetchDebs(ctx, suite, pkg, archs.slice(1), cb); return; }
        var m = /href="([^"]+\.deb)"/.exec(html);
        if (m) {
            var u = debUrl(m[1]);
            cb([{ name: toName(u), url: u }]);
        } else {
            fetchDebs(ctx, suite, pkg, archs.slice(1), cb);
        }
    });
}

function checkDebian(ctx) {
    var item = ctx.item, opts = ctx.opts;
    var m = /packages\.debian\.org\/(?:[a-z]{2}(?:-[a-z]+)?\/)?([^\/?#]+)\/([^\/?#]+)/i.exec(item.url);
    if (!m) { ctx.done("Cannot parse Debian package URL (expected packages.debian.org/SUITE/PACKAGE)"); return; }
    var suite = m[1], pkg = m[2];
    request(ctx, "GET", item.url, {}, function (err, html) {
        if (err) { ctx.done(err); return; }
        var vm = /<h1>\s*Package:\s*[^\s<]+\s*\(([^\s)<]+)/i.exec(html);
        if (!vm) { ctx.done("Could not find the version on the Debian package page"); return; }
        var version = vm[1];
        var arch = opts.debianArch || "amd64";
        fetchDebs(ctx, suite, pkg, arch === "all" ? ["all"] : [arch, "all"], function (arts) {
            arts = filterArtifacts(arts, ctx.re);
            var result = { id: version, version: version, time: null, link: item.url, artifacts: arts };
            if (!arts.length) { ctx.done(null, result); return; }
            lastModified(ctx, arts[0], function (t, len) {
                if (t) result.time = t;
                if (len) arts[0].size = len;
                ctx.done(null, result);
            });
        });
    });
}

// Best effort: Last-Modified / Content-Length of an artifact via HEAD
function lastModified(ctx, art, cb) {
    request(ctx, "HEAD", art.url, {}, function (err, text, xhr) {
        var t = 0, len = 0;
        if (!err && xhr) {
            var lm = xhr.getResponseHeader("Last-Modified");
            var p = lm ? parseHttpDate(lm) : NaN;
            if (!isNaN(p)) t = p;
            len = parseInt(xhr.getResponseHeader("Content-Length"), 10) || 0;
        }
        cb(t, len);
    });
}

// ---------------------------------------------------------------- Directory listings
function parseDate(s) {
    var d = /(\d{4}-\d{2}-\d{2})[ T](\d{2}:\d{2})(?::(\d{2}))?/.exec(s), t;
    if (d) {
        t = Date.parse(d[1] + "T" + d[2] + ":" + (d[3] || "00") + "Z");
        return isNaN(t) ? null : t;
    }
    d = /(\d{1,2})-([A-Za-z]{3})-(\d{4})\s+(\d{1,2}:\d{2})/.exec(s);
    if (d) {
        t = parseDayMonYear(d[1] + "-" + d[2] + "-" + d[3] + " " + d[4]);
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
                                                               .replace(/\d{1,2}-[A-Za-z]{3}-\d{4}\s+\d{1,2}:\d{2}/, ""));
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
        var name = safeDecode(href.replace(/\/$/, ""));
        out.push({ name: name, href: href, isDir: isDir, time: parseDate(tail), size: isDir ? 0 : parseSize(tail) });
    }
    return out;
}

function looksLikeListing(html, entries) {
    if (/<title>[^<]*Index of|<h1>[^<]*Index of/i.test(html)) return true;
    if (!entries.length) return false;
    var dated = entries.filter(function (e) { return e.time; }).length;
    return dated >= Math.max(1, entries.length / 2);
}

function sortNewestFirst(entries) {
    entries.sort(function (a, b) {
        if (a.time && b.time && a.time !== b.time) return b.time - a.time;
        if (!!a.time !== !!b.time) return a.time ? -1 : 1;
        return natCmp(b.name, a.name);
    });
    return entries;
}

// "7.1.4", "v2.0", "2024-05-01" ...
function isStrictVersion(name) { return /^v?\d+(?:[._-]\d+)*$/.test(name); }
function isLooseVersion(name) { return /^v?\d/.test(name); }

var MAX_DEPTH = 3;
var MAX_ARTIFACTS = 60;

// Result for a listing that is a flat list of release files
function flatResult(ctx, base, entries) {
    var isDeb = entries.some(function (e) { return !e.isDir && /\.dsc$/i.test(e.name); });
    var list = entries.filter(function (e) { return !ctx.re || ctx.re.test(e.name); });
    if (isDeb) list = list.filter(function (e) { return !e.isDir && /\.(dsc|deb)$/i.test(e.name); });
    if (!list.length) return { error: "No matching entries found in the listing" };
    sortNewestFirst(list);

    var latest = list[0], version = null;
    if (isDeb) {
        var dscs = list.filter(function (e) { return /\.dsc$/i.test(e.name); });
        if (dscs.length) {
            latest = dscs[0];
            var vm = /^(.+?)_(.+)\.dsc$/i.exec(latest.name);
            version = vm ? vm[1] + " " + vm[2] : latest.name;
        }
    }
    return { result: {
        id: latest.name + "|" + (latest.time || ""),
        version: version || (latest.name + (latest.isDir ? "/" : "")),
        time: latest.time,
        link: base,
        typeLabel: isDeb ? "Debian (dsc)" : "Directory",
        artifacts: artifactsOf(base, list)
    } };
}

function artifactsOf(base, list) {
    return list.filter(function (e) { return !e.isDir; }).slice(0, MAX_ARTIFACTS).map(function (e) {
        var a = { name: e.name, url: /^[a-z]+:\/\//i.test(e.href) ? e.href : base + e.href, size: e.size };
        if (/\.dsc$/i.test(e.name)) a.kind = "dsc";
        return a;
    });
}

// Listings print times in the server's time zone (often UTC, sometimes local) and parseDate() reads them as
// UTC. Compare the newest file's listed time with its Last-Modified header (always GMT) to find the offset.
// Returns 0 when it cannot be determined reliably.
function listingOffset(ctx, base, entries, cb) {
    var files = entries.filter(function (e) { return !e.isDir && e.time; });
    if (!files.length) { cb(0); return; }
    sortNewestFirst(files);
    var e = files[0];
    var url = /^[a-z]+:\/\//i.test(e.href) ? e.href : base + e.href;
    request(ctx, "HEAD", url, {}, function (err, text, xhr) {
        var off = 0;
        if (!err && xhr) {
            var lm = parseHttpDate(xhr.getResponseHeader("Last-Modified") || "");
            if (!isNaN(lm)) {
                var q = 15 * 60000, diff = lm - e.time;
                var r = Math.round(diff / q) * q;
                // listing times only have minute resolution: accept only a clean multiple of 15 minutes
                if (Math.abs(r) <= 14 * 3600000 && Math.abs(diff - r) < 2 * 60000) off = r;
            }
        }
        cb(off);
    });
}

// Walk a listing. If it contains version-named sub-directories (7.1.4/, v2.0/ ...), the newest one
// is entered (up to MAX_DEPTH levels) and its files are the release artifacts.
function walkListing(ctx, base, html, depth, trail, cb) {
    var entries = parseListing(html, base);
    var dirs = entries.filter(function (e) { return e.isDir; });
    var cands = dirs.filter(function (e) { return isStrictVersion(e.name); });
    if (!cands.length) cands = dirs.filter(function (e) { return isLooseVersion(e.name); });

    if (!cands.length || depth >= MAX_DEPTH) {
        var flat = flatResult(ctx, base, entries);
        if (flat.error) { cb(trail.length ? "No matching files in " + trail[trail.length - 1].name + "/" : flat.error); return; }
        var r = flat.result;
        var finishWith = function () { cb(null, r); };
        if (trail.length) {
            // release = the version directory we descended into
            var dir = trail[trail.length - 1];
            r.id = trail.map(function (d) { return d.name; }).join("/");
            r.version = dir.name;
            r.time = dir.time || r.time;
            r.typeLabel = r.typeLabel === "Debian (dsc)" ? r.typeLabel : "Directory";
        }
        if (!r.time) { finishWith(); return; }
        listingOffset(ctx, base, entries, function (off) {   // r.id is left alone: it must not depend on this
            if (off) r.time += off;
            finishWith();
        });
        return;
    }

    cands.sort(function (a, b) { return natCmp(b.name, a.name); });   // newest first
    var tries = cands.slice(0, 3), idx = 0, lastErr = "No release directory found";

    function next() {
        if (idx >= tries.length) { cb(lastErr); return; }
        var d = tries[idx++];
        var sub = base + (/^[a-z]+:\/\//i.test(d.href) ? d.href.substring(base.length) : d.href);
        if (sub.charAt(sub.length - 1) !== "/") sub += "/";
        request(ctx, "GET", sub, { "User-Agent": UA }, function (err, subHtml) {
            if (err) { lastErr = err; next(); return; }
            walkListing(ctx, sub, subHtml, depth + 1, trail.concat([d]), function (err2, res) {
                if (err2) { lastErr = err2; next(); }      // empty / filtered-out release dir: try the previous one
                else cb(null, res);
            });
        });
    }
    next();
}

// A normal web page: collect links to downloadable files
function checkPageLinks(ctx, pageUrl, html) {
    var re = /<a\s+[^>]*?href\s*=\s*(["'])(.*?)\1/gi, m, seen = {}, arts = [];
    while ((m = re.exec(html)) !== null) {
        var url = resolveUrl(m[2], pageUrl);
        if (!url) continue;
        var name = toName(url);
        if (!ARTIFACT_RE.test(name)) {
            // download.php?file=Setup_1.2.exe style links
            var q = /[?&][^=&]*=([^&#]+)/g, qm, qname = null;
            while ((qm = q.exec(url)) !== null) {
                var v = safeDecode(qm[1]);
                if (ARTIFACT_RE.test(v)) { qname = v.substring(v.lastIndexOf("/") + 1); break; }
            }
            if (!qname) continue;
            name = qname;
        }
        if (seen[url]) continue;
        seen[url] = true;
        arts.push({ name: name, url: url });
    }
    if (!arts.length) { ctx.done("No download links found on the page"); return; }

    // newest version token found in the file names
    var best = null;
    arts.forEach(function (a) {
        var vr = /\d+(?:\.\d+)+/g, vm;
        while ((vm = vr.exec(a.name)) !== null)
            if (best === null || natCmp(vm[0], best) > 0) best = vm[0];
    });
    var mine = best ? arts.filter(function (a) { return a.name.indexOf(best) >= 0; }) : arts;
    if (!mine.length) mine = arts;
    mine = filterArtifacts(mine, ctx.re);
    if (!mine.length) { ctx.done("No matching download links on the page"); return; }
    mine = mine.slice(0, MAX_ARTIFACTS);

    var names = mine.map(function (a) { return a.name; }).sort().join("|");
    var result = {
        id: best || names,
        version: best || mine[0].name,
        time: null,
        link: pageUrl,
        typeLabel: "Web page",
        artifacts: mine
    };
    lastModified(ctx, mine[0], function (t, len) {
        if (t) result.time = t;
        if (len) mine[0].size = len;
        ctx.done(null, result);
    });
}

function checkWeb(ctx) {
    var url = ctx.item.url.replace(/#.*$/, "");
    request(ctx, "GET", url, { "User-Agent": UA }, function (err, html) {
        if (err) { ctx.done(err); return; }
        var base = dirOf(url);
        var entries = parseListing(html, base);
        if (looksLikeListing(html, entries)) {
            var listBase = url.replace(/[?#].*$/, "");
            if (listBase.charAt(listBase.length - 1) !== "/") listBase += "/";
            walkListing(ctx, listBase, html, 0, [], ctx.done);
        } else {
            checkPageLinks(ctx, url, html);
        }
    });
}

// ---------------------------------------------------------------- entry point
function check(item, opts, cb) {
    var finished = false;
    var ctx = {
        item: item, opts: opts, re: null,
        done: function (err, res) { if (finished) return; finished = true; cb(err, res); },
        fail: function (msg) { ctx.done(msg); }
    };
    if (item.filter) {
        try { ctx.re = new RegExp(item.filter, "i"); }
        catch (e) { ctx.done("Invalid filter regex: " + e.message); return; }
    }
    try {
        switch (detectType(item.url)) {
        case "github": checkGithub(ctx); break;
        case "fdroid": checkFdroid(ctx); break;
        case "debian": checkDebian(ctx); break;
        default: checkWeb(ctx);
        }
    } catch (e) {
        ctx.fail(String(e));
    }
}
