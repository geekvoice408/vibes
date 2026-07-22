// Redaction logic, ported from the original Rust implementation
// (argocd repo, apps-src/redact/src/main.rs). Runs entirely in the browser;
// also loadable from node for the test suite.

// Well-known domains that are safe to leave in place. Exact match or any
// subdomain of these is preserved. Deliberately does NOT include teleport.sh:
// *.teleport.sh subdomains are customer tenants and must be redacted.
const ALLOWED_DOMAINS = [
    'example.com',
    'github.com',
    'gitlab.com',
    'google.com',
    'goteleport.com',
    'docker.io',
    'ghcr.io',
    'quay.io',
    'kubernetes.io',
    'k8s.io',
    'example.teleport.sh',
];

// Source-file extensions that show up as `file.ext:line` references in logs.
// "sh" is intentionally absent — it would collide with *.teleport.sh domains.
const CODE_EXTENSIONS = [
    'go', 'rs', 'py', 'js', 'ts', 'tsx', 'jsx', 'java', 'rb', 'php', 'c', 'h', 'cc', 'cpp',
    'hpp', 'cs', 'css', 'html', 'json', 'yaml', 'yml', 'toml', 'proto', 'mod', 'sum', 'lock',
    'md', 'txt', 'log',
];

function isAllowedDomain(matched) {
    const lower = matched.toLowerCase();
    return ALLOWED_DOMAINS.some((d) => lower === d || lower.endsWith('.' + d));
}

function isCodeReference(matched) {
    // file.ext where ext is a source-file extension (cli.go, state.go, app.js)
    const ext = matched.slice(matched.lastIndexOf('.') + 1).toLowerCase();
    return CODE_EXTENSIONS.includes(ext);
}

function placeholderFor(matched) {
    return matched.toLowerCase().endsWith('.teleport.sh')
        ? 'example.teleport.sh'
        : 'example.com';
}

function redactText(input) {
    const ipRe = /\b\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}\b/g;
    // No trailing \b: it cannot land before '_' (a word character), which made
    // "heb-dev.teleport.sh_443" match as "heb-dev.teleport". Instead we match
    // greedily and reject matches that end mid-token below.
    const domainRe = /\b(?:[a-z0-9](?:[a-z0-9-]*[a-z0-9])?\.)+[a-z]{2,63}/gi;

    let ipCount = 0;
    const afterIps = input.replace(ipRe, () => {
        ipCount += 1;
        return '1.2.3.4';
    });

    let domainCount = 0;
    let redacted = '';
    let last = 0;
    for (const m of afterIps.matchAll(domainRe)) {
        const end = m.index + m[0].length;
        // ends mid-token (e.g. "foo.bar123" matching as "foo.bar")? not a domain
        const next = afterIps[end];
        const endsMidToken = next !== undefined && /[a-zA-Z0-9-]/.test(next);
        redacted += afterIps.slice(last, m.index);
        if (endsMidToken || isAllowedDomain(m[0]) || isCodeReference(m[0])) {
            redacted += m[0];
        } else {
            domainCount += 1;
            redacted += placeholderFor(m[0]);
        }
        last = end;
    }
    redacted += afterIps.slice(last);

    return { redacted, ip_count: ipCount, domain_count: domainCount };
}

if (typeof module !== 'undefined' && module.exports) {
    module.exports = { redactText };
}
