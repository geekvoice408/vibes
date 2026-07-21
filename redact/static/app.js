const input = document.getElementById('input');
const output = document.getElementById('output');
const stats = document.getElementById('stats');
const btnRedact = document.getElementById('btn-redact');
const btnClear = document.getElementById('btn-clear');
const btnCopy = document.getElementById('btn-copy');

btnRedact.addEventListener('click', async () => {
    const text = input.value.trim();
    if (!text) return;

    btnRedact.disabled = true;
    btnRedact.textContent = 'Redacting...';

    try {
        const res = await fetch('/api/redact', {
            method: 'POST',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify({ text }),
        });
        const data = await res.json();
        output.value = data.redacted;

        const total = data.ip_count + data.domain_count;
        if (total > 0) {
            stats.innerHTML = `<span class="count">${total}</span> redaction${total !== 1 ? 's' : ''} (${data.ip_count} IP, ${data.domain_count} domain)`;
        } else {
            stats.textContent = 'Nothing to redact';
        }
    } catch (e) {
        stats.textContent = 'Error processing text';
    }

    btnRedact.disabled = false;
    btnRedact.textContent = 'Redact';
});

btnClear.addEventListener('click', () => {
    input.value = '';
    output.value = '';
    stats.textContent = '';
    input.focus();
});

btnCopy.addEventListener('click', () => {
    if (!output.value) return;
    navigator.clipboard.writeText(output.value);
    btnCopy.textContent = 'Copied!';
    btnCopy.classList.add('copied');
    setTimeout(() => {
        btnCopy.textContent = 'Copy';
        btnCopy.classList.remove('copied');
    }, 1500);
});

input.addEventListener('keydown', (e) => {
    if ((e.ctrlKey || e.metaKey) && e.key === 'Enter') {
        btnRedact.click();
    }
});
